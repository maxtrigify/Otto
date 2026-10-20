import Foundation
import Hummingbird
import OttoControl
import OttoHooks
import OttoModels
import OttoSecurity
import OttoTools

private actor RouteRegistry {
  private let routes: [String: WebhookRoute]
  private let secrets: any SecretStore
  init(routes: [WebhookRoute], secrets: any SecretStore) {
    self.routes = Dictionary(uniqueKeysWithValues: routes.map { ($0.slug, $0) })
    self.secrets = secrets
  }
  func resolve(_ slug: String) async throws -> (WebhookRoute, String) {
    guard let route = routes[slug], route.enabled else { throw WebhookRejection.notFound }
    let key = "routine.webhook.\(route.routineID.uuidString).secret"
    guard let secret = try await secrets.value(for: key), !secret.isEmpty else {
      throw WebhookRejection.missingSecret
    }
    return (route, secret)
  }
}

private actor NDJSONEmitter {
  func emit(_ envelope: WebhookEnvelope) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(envelope)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}

@main
private struct OttoHookDaemon {
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = OttoEnvironment.value("HOOK_HOST", in: environment) ?? "127.0.0.1"
    try WebhookConfiguration.validateLoopbackHost(host)
    let port = Int(OttoEnvironment.value("HOOK_PORT", in: environment) ?? "8787") ?? 8787
    guard (1...65_535).contains(port) else { throw WebhookRejection.notFound }
    guard let configPath = OttoEnvironment.value("HOOK_ROUTES", in: environment) else {
      throw WebhookRejection.notFound
    }
    let decoder = JSONDecoder()
    let routes = try decoder.decode(
      [WebhookRoute].self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    let secretService =
      OttoEnvironment.value("HOOK_SECRET_SERVICE", in: environment) ?? OttoSecretService.credentials
    let registry = RouteRegistry(
      routes: routes, secrets: makeDefaultSecretStore(service: secretService))
    let admission = WebhookAdmission()
    let emitter = NDJSONEmitter()
    let control = OttoEnvironment.value("CONTROL_SOCKET", in: environment).flatMap { socket in
      OttoEnvironment.value("CONTROL_TOKEN", in: environment).map {
        ControlClient(socketPath: socket, token: $0)
      }
    }
    let router = Router()
    router.get("/healthz") { _, _ in ["status": "ok"] }
    router.post("/hooks/:slug") { request, context -> HTTPResponse.Status in
      guard let slug = context.parameters.get("slug", as: String.self) else { return .notFound }
      do {
        // Defense order: resolve route/secret, cap body, verify HMAC, rate/idempotency, ack.
        let (_, secret) = try await registry.resolve(slug)
        let buffer = try await request.body.collect(upTo: WebhookSignatureVerifier.maximumBodyBytes)
        let body = Data(buffer.readableBytesView)
        var headers: [String: String] = [:]
        for header in request.headers {
          headers[header.name.canonicalName.lowercased()] = header.value
        }
        try WebhookSignatureVerifier.verify(
          body: body, secret: secret,
          // X-Muse-* is the documented webhook header (legacy wire name); X-Otto-* is accepted
          // as an alias for senders configured after the rename.
          signatureHeader: headers["x-otto-signature"]
            ?? headers[OttoLegacyWire.signatureHeader.lowercased()]
            ?? headers["x-hub-signature-256"],
          timestampHeader: headers["x-otto-timestamp"]
            ?? headers[OttoLegacyWire.timestampHeader.lowercased()]
            ?? headers["webhook-timestamp"])
        let key = WebhookConfiguration.idempotencyKey(slug: slug, headers: headers, body: body)
        try await admission.admit(route: slug, idempotencyKey: key)
        let envelope = WebhookEnvelope(
          slug: slug,
          headers: headers.filter {
            ["x-github-event", "x-github-delivery", "svix-id"].contains($0.key)
          }, body: String(decoding: body, as: UTF8.self), receivedAt: .now,
          idempotencyKey: key)
        Task {
          try? await emitter.emit(envelope)
          if let control {
            _ = try? await control.callAsync(
              "routine.webhook_receive",
              arguments: .object([
                "slug": .string(slug), "body": .string(envelope.body),
                "idempotencyKey": .string(key),
              ]))
          }
        }
        return .accepted
      } catch WebhookRejection.notFound, WebhookRejection.missingSecret {
        return .notFound
      } catch WebhookRejection.oversized { return .contentTooLarge } catch WebhookRejection
        .rateLimited
      { return .tooManyRequests } catch WebhookRejection.duplicate { return .accepted } catch {
        return .unauthorized
      }
    }
    let app = Application(
      router: router,
      configuration: .init(address: .hostname(host, port: port), serverName: "Otto Hook Listener"))
    try await app.run()
  }
}

import CryptoKit
import Foundation
import OttoModels
import OttoRPCContracts
import OttoSecurity

/// Outbound private-input connection. Neither URLs nor decrypted input reach general RPC.
@MainActor
final class PrivatePhoneConnection {
  enum Failure: Error, LocalizedError {
    case unavailable, interrupted
    var errorDescription: String? {
      switch self {
      case .unavailable: "Private phone sign-in is unavailable. No action was approved."
      case .interrupted:
        "Private sign-in ended. Ask for a fresh link; nothing will be repeated automatically."
      }
    }
  }
  struct Identity {
    let key: P256.Signing.PrivateKey
    var id: UUID {
      let bytes = Array(SHA256.hash(data: key.publicKey.x963Representation).prefix(16))
      return UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
  }
  private let secrets: any SecretStore
  private var identity: Identity?
  private var loading = false
  private let ledger = PrivatePhoneSessionLedger()
  private var sockets: [UUID: URLSessionWebSocketTask] = [:]
  init(secrets: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.privatePhone))
  {
    self.secrets = secrets
  }
  static var endpoint: URL? {
    #if DEBUG
      if let value = OttoEnvironment.value("PRIVATE_PHONE_URL"),
        let url = URL(string: value), validEndpoint(url, development: true)
      {
        return url
      }
    #endif
    guard let value = Bundle.main.object(forInfoDictionaryKey: "OttoPrivatePhoneURL") as? String,
      let url = URL(string: value), validEndpoint(url, development: false)
    else { return nil }
    return url
  }
  private static func validEndpoint(_ url: URL, development: Bool) -> Bool {
    url.host != nil && url.user == nil && url.password == nil && url.query == nil
      && url.fragment == nil && (url.path.isEmpty || url.path == "/")
      && (url.scheme == "https" || (development && url.scheme == "http" && url.host == "127.0.0.1"))
  }
  func installationIdentity() async throws -> Identity {
    if let identity { return identity }
    guard !loading else { throw Failure.unavailable }
    loading = true
    defer { loading = false }
    let key: P256.Signing.PrivateKey
    if let encoded = try await secrets.value(for: "installation-key") {
      guard let raw = Data(base64Encoded: encoded) else { throw Failure.unavailable }
      key = try P256.Signing.PrivateKey(rawRepresentation: raw)
    } else {
      key = P256.Signing.PrivateKey()
      try await secrets.set(key.rawRepresentation.base64EncodedString(), for: "installation-key")
    }
    let identity = Identity(key: key)
    self.identity = identity
    return identity
  }
  func stop() {
    for socket in sockets.values { socket.cancel(with: .goingAway, reason: nil) }
    sockets.removeAll()
  }

  func run(
    scope: PrivatePhoneSessionLedger.Scope,
    sendLink: @escaping @MainActor (URL) async throws -> Void,
    isValid: @escaping @MainActor () -> Bool,
    handle: @escaping @MainActor (PrivatePhoneCommand) async throws -> PrivatePhoneView
  ) async throws {
    guard let endpoint = Self.endpoint, isValid() else { throw Failure.unavailable }
    let identity = try await installationIdentity()
    guard identity.id == scope.installationID, isValid() else { throw Failure.unavailable }
    let issued = try await ledger.issue(scope: scope)
    let host = P256.KeyAgreement.PrivateKey()
    let expiry = Int64(issued.expiresAt.timeIntervalSince1970)
    let path =
      "/v1/host/\(identity.id.uuidString.lowercased())/\(issued.id.uuidString.lowercased())/\(expiry)"
    var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    parts.path = path
    let origin = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let time = String(Int64(Date.now.timeIntervalSince1970))
    let nonce = UUID().uuidString.lowercased()
    let proof = Data(
      [OttoLegacyWire.phoneHostSignatureLabel, origin, path, time, nonce].joined(separator: "\n")
        .utf8)
    parts.scheme = endpoint.scheme == "https" ? "wss" : "ws"
    var request = URLRequest(url: parts.url!)
    request.setValue(time, forHTTPHeaderField: OttoLegacyWire.timeHeader)
    request.setValue(nonce, forHTTPHeaderField: OttoLegacyWire.nonceHeader)
    request.setValue(
      identity.key.publicKey.x963Representation.base64EncodedString(),
      forHTTPHeaderField: OttoLegacyWire.keyHeader)
    request.setValue(
      try identity.key.signature(for: proof).rawRepresentation.base64EncodedString(),
      forHTTPHeaderField: OttoLegacyWire.signatureHeader)
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: config)
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 100_000
    sockets[issued.id] = socket
    let expiryTask = Task {
      try? await Task.sleep(for: .seconds(300))
      if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
    }
    defer {
      expiryTask.cancel()
      sockets.removeValue(forKey: issued.id)
      socket.cancel(with: .normalClosure, reason: nil)
      session.invalidateAndCancel()
      Task { await ledger.close(id: issued.id) }
    }
    do {
      try await withTaskCancellationHandler {
        socket.resume()
        let connectTimeout = Task {
          try? await Task.sleep(for: .seconds(15))
          if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) }
        }
        let ready = try await socket.receive()
        connectTimeout.cancel()
        guard case .string("ready") = ready, isValid() else { throw Failure.unavailable }
        var page = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        page.path = "/"
        page.fragment = PrivatePhoneLink.fragment(
          installationID: scope.installationID, sessionID: issued.id, expiresAt: expiry,
          hostPublicKey: host.publicKey.x963Representation, capability: issued.capability)
        try await sendLink(page.url!)
        var claimedPeer: String?
        var claimedKey: Data?
        while true {
          try Task.checkCancellation()
          guard isValid(), Date.now < issued.expiresAt else { throw Failure.interrupted }
          let message = try await socket.receive()
          guard case .string(let text) = message, let data = text.data(using: .utf8),
            data.count <= 100_000
          else { continue }
          struct Payload: Decodable {
            var publicKey: Data
            var envelope: PrivatePhoneEnvelope.Wire
          }
          struct Inbound: Decodable {
            var peerID: String
            var payload: Payload
          }
          guard let incoming = try? JSONDecoder().decode(Inbound.self, from: data),
            claimedPeer == nil || claimedPeer == incoming.peerID,
            incoming.payload.publicKey.count == 65,
            let peer = try? P256.KeyAgreement.PublicKey(
              x963Representation: incoming.payload.publicKey)
          else { continue }
          let c = PrivatePhoneEnvelope.Context(
            installationID: scope.installationID,
            sessionID: issued.id, operationID: incoming.payload.envelope.context.operationID,
            direction: .phoneToHost, expiresAt: expiry)
          guard
            let plaintext = try? PrivatePhoneEnvelope.open(
              incoming.payload.envelope,
              expected: c, recipient: host, sender: peer),
            let command = try? JSONDecoder().decode(PrivatePhoneCommand.self, from: plaintext)
          else { continue }
          if claimedPeer == nil {
            guard command.action == "claim", let capability = command.capability else { continue }
            do {
              try await ledger.claim(
                id: issued.id, capability: capability,
                browserPublicKey: incoming.payload.publicKey, scope: scope)
            } catch { continue }
            claimedPeer = incoming.peerID
            claimedKey = incoming.payload.publicKey
          } else if command.action == "claim" || claimedKey != incoming.payload.publicKey {
            continue
          }
          guard isValid() else { throw Failure.interrupted }
          try await ledger.accept(
            id: issued.id, operationID: c.operationID,
            browserPublicKey: incoming.payload.publicKey, scope: scope)
          let view: PrivatePhoneView
          // No automatic resubmission after an uncertain action.
          do { view = try await handle(command) } catch { throw Failure.interrupted }
          guard isValid() else { throw Failure.interrupted }
          let response = PrivatePhoneEnvelope.Context(
            installationID: c.installationID,
            sessionID: c.sessionID, operationID: c.operationID, direction: .hostToPhone,
            expiresAt: expiry)
          let encrypted = try PrivatePhoneEnvelope.seal(
            JSONEncoder().encode(view), context: response,
            recipient: peer, sender: host)
          struct Outbound: Encodable {
            var peerID: String
            var payload: PrivatePhoneEnvelope.Wire
          }
          let bytes = try JSONEncoder().encode(
            Outbound(peerID: incoming.peerID, payload: encrypted))
          try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
          try await ledger.completedOperation(id: issued.id, operationID: c.operationID)
          if view.mode == "complete" { return }
        }
      } onCancel: {
        socket.cancel(with: .goingAway, reason: nil)
      }
    } catch { throw (error as? Failure) ?? Failure.interrupted }
  }
}

// A compact fragment avoids Messages truncating a long, uninterrupted JSON token.
// Separators also keep Apple's link detector from treating the token as a hostname.
enum PrivatePhoneLink {
  static func fragment(
    installationID: UUID, sessionID: UUID, expiresAt: Int64,
    hostPublicKey: Data, capability: Data
  ) -> String {
    var bytes = withUnsafeBytes(of: installationID.uuid) { Data($0) }
    bytes.append(withUnsafeBytes(of: sessionID.uuid) { Data($0) })
    var expiry = UInt64(expiresAt).bigEndian
    bytes.append(withUnsafeBytes(of: &expiry) { Data($0) })
    bytes.append(hostPublicKey)
    bytes.append(capability)
    let token = Array(
      bytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: ""))
    return "v1."
      + stride(from: 0, to: token.count, by: 64).map {
        String(token[$0..<min($0 + 64, token.count)])
      }.joined(separator: ".")
  }
}

import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import HummingbirdWebSocket
import OttoHostRuntime
import OttoModels
import OttoRPCContracts

public struct OttoHostTransportConfiguration: Sendable {
  public var hostname: String
  public var port: Int
  public var allowLAN: Bool
  public var token: String
  public var scopes: Set<OttoRPCScope>
  public var tls: TLSConfiguration?

  public init(
    hostname: String = "127.0.0.1",
    port: Int = 7338,
    allowLAN: Bool = false,
    token: String,
    scopes: Set<OttoRPCScope> = Set(OttoRPCScope.allCases),
    tls: TLSConfiguration? = nil
  ) throws {
    guard (1...65_535).contains(port) else { throw OttoHostTransportError.invalidPort }
    guard token.utf8.count >= 32 else { throw OttoHostTransportError.weakToken }
    let isLoopback = Self.isLoopback(hostname)
    guard isLoopback || allowLAN else { throw OttoHostTransportError.lanDisabled }
    guard isLoopback || tls != nil else { throw OttoHostTransportError.tlsRequiredForLAN }
    self.hostname = hostname
    self.port = port
    self.allowLAN = allowLAN
    self.token = token
    self.scopes = scopes
    self.tls = tls
  }

  public init(
    hostname: String = "127.0.0.1",
    port: Int = 7338,
    allowLAN: Bool = false,
    token: String,
    scopes: Set<OttoRPCScope> = Set(OttoRPCScope.allCases),
    certificateChainFile: String?,
    privateKeyFile: String?
  ) throws {
    let tls: TLSConfiguration?
    if certificateChainFile == nil, privateKeyFile == nil {
      tls = nil
    } else if let certificateChainFile, let privateKeyFile {
      tls = try OttoHostTLS.configuration(
        certificateChainFile: certificateChainFile,
        privateKeyFile: privateKeyFile
      )
    } else {
      throw OttoHostTransportError.tlsRequiredForLAN
    }
    try self.init(
      hostname: hostname,
      port: port,
      allowLAN: allowLAN,
      token: token,
      scopes: scopes,
      tls: tls
    )
  }

  public var scheme: String { tls == nil ? "http" : "https" }
  public var webSocketScheme: String { tls == nil ? "ws" : "wss" }

  /// Resolves the URL embedded in pairing offers. A secure reverse proxy such as Tailscale Serve
  /// may advertise HTTPS while the host itself remains bound to loopback. Plain HTTP is accepted
  /// only for a loopback development endpoint and wildcard bind addresses are never advertised.
  public func advertisedBaseURL(override rawValue: String? = nil) throws -> URL {
    if let rawValue, !rawValue.isEmpty {
      guard let url = URL(string: rawValue), Self.isSafeAdvertisedURL(url) else {
        throw OttoHostTransportError.insecureAdvertisedURL
      }
      return rawValue.hasSuffix("/") ? url : url.appending(path: "")
    }
    guard hostname != "0.0.0.0", hostname != "::" else {
      throw OttoHostTransportError.missingAdvertisedURL
    }
    guard let url = URL(string: "\(scheme)://\(hostname):\(port)/"),
      Self.isSafeAdvertisedURL(url)
    else { throw OttoHostTransportError.insecureAdvertisedURL }
    return url
  }

  public static func isLoopback(_ hostname: String) -> Bool {
    hostname == "127.0.0.1" || hostname == "::1" || hostname == "localhost"
  }

  public static func isSafeAdvertisedURL(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let hostname = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return false }
    return scheme == "https" || (scheme == "http" && isLoopback(hostname))
  }
}

public enum OttoHostTransportError: Error, LocalizedError, Equatable, Sendable {
  case invalidPort
  case weakToken
  case lanDisabled
  case tlsRequiredForLAN
  case insecureAdvertisedURL
  case missingAdvertisedURL
  case invalidDeviceID
  case invalidThreadID
  case invalidCursor

  public var errorDescription: String? {
    switch self {
    case .invalidPort: "The mobile host port must be between 1 and 65535."
    case .weakToken: "The mobile host token must contain at least 32 UTF-8 bytes."
    case .lanDisabled: "Non-loopback mobile hosting requires explicit LAN opt-in."
    case .tlsRequiredForLAN: "LAN mobile hosting requires TLS."
    case .insecureAdvertisedURL:
      "The advertised mobile host URL must use HTTPS, except for loopback development."
    case .missingAdvertisedURL:
      "A wildcard mobile host bind requires an explicit advertised HTTPS URL."
    case .invalidDeviceID: "A valid paired device identifier is required."
    case .invalidThreadID: "A valid thread identifier is required."
    case .invalidCursor: "The event cursor must be a non-negative integer."
    }
  }
}

public enum OttoHostTLS {
  public static func configuration(
    certificateChainFile: String,
    privateKeyFile: String
  ) throws -> TLSConfiguration {
    let certificates = try NIOSSLCertificate.fromPEMFile(certificateChainFile)
    let privateKey = try NIOSSLPrivateKey(file: privateKeyFile, format: .pem)
    return TLSConfiguration.makeServerConfiguration(
      certificateChain: certificates.map { .certificate($0) },
      privateKey: .privateKey(privateKey)
    )
  }
}

/// Device-pairing boundary supplied by the Mac application. The transport never reads pairing
/// persistence directly and receives only the scoped client context needed for one request.
public protocol OttoHostPairingHandling: Sendable {
  func exchange(
    _ input: OttoMobilePairingExchangeInput
  ) async throws -> OttoMobilePairingExchangeOutput

  func authenticate(
    deviceID: UUID,
    credential: String,
    requiredScope: OttoRPCScope
  ) async throws -> OttoHostClientContext
}

public enum OttoHostHTTPApplication {
  public static func make(
    host: OttoHostRuntime,
    configuration: OttoHostTransportConfiguration,
    pairing: (any OttoHostPairingHandling)? = nil,
    applicationConfiguration: ApplicationConfiguration? = nil,
    onServerRunning: @escaping @Sendable () async -> Void = {}
  ) throws -> some ApplicationProtocol {
    let router = Router(context: BasicWebSocketRequestContext.self)
    let authenticator = OttoHostTokenAuthenticator(
      token: configuration.token,
      scopes: configuration.scopes
    )

    router.get("/health") { _, _ in
      ["status": "ok", "protocol": String(OttoRPCProtocol.currentVersion)]
    }

    if let pairing {
      router.post("/v1/pairing/exchange") { request, _ in
        let input: OttoMobilePairingExchangeInput
        do {
          let body = try await request.body.collect(upTo: 65_536)
          input = try OttoRPCCodec.decoder.decode(
            OttoMobilePairingExchangeInput.self,
            from: Data(body.readableBytesView)
          )
        } catch {
          throw HTTPError(.badRequest, message: "The pairing request is invalid.")
        }
        do {
          return OttoHostJSONResponse(try await pairing.exchange(input))
        } catch {
          throw HTTPError(.unauthorized, message: "Pairing failed or expired.")
        }
      }
    }

    // Paired-device-only secret intake. No legacy token, query payload, journal, or retry cache.
    if let pairing {
      router.post("/v1/secure-login") { request, _ in
        guard let rawID = request.headers[.init(OttoLegacyWire.deviceIDHeader)!],
          let deviceID = UUID(uuidString: rawID),
          let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer ")
        else { throw HTTPError(.unauthorized, message: "Paired device required.") }
        guard
          let client = try? await pairing.authenticate(
            deviceID: deviceID,
            credential: String(authorization.dropFirst(7)), requiredScope: .secureLogin)
        else { throw HTTPError(.unauthorized, message: "Paired device required.") }
        do {
          let body = try await request.body.collect(upTo: 65_536)
          let input = try OttoRPCCodec.decoder.decode(
            SecureLoginInput.self, from: Data(body.readableBytesView))
          return OttoHostJSONResponse(try await host.secureLogin(input, client: client))
        } catch {
          throw HTTPError(
            .badRequest,
            message: "Secure sign-in request expired or was refused. Refresh on your device.")
        }
      }
    }

    router.post("/v1/rpc") { request, _ in
      let input: OttoRPCRequest
      do {
        let body = try await request.body.collect(upTo: 1_048_576)
        input = try OttoRPCCodec.decoder.decode(
          OttoRPCRequest.self,
          from: Data(body.readableBytesView)
        )
      } catch {
        throw HTTPError(.badRequest, message: "The RPC request is invalid.")
      }
      let client = try await authenticate(
        request,
        requiredScope: input.method.requiredScope,
        legacy: authenticator,
        pairing: pairing
      )
      return OttoHostJSONResponse(await host.handle(input, client: client))
    }

    router.ws("/v1/events") { request, _ in
      guard
        (try? await authenticate(
          request,
          requiredScope: .threadRead,
          legacy: authenticator,
          pairing: pairing
        )) != nil,
        parseThreadID(request) != nil,
        parseCursor(request) != nil
      else { return .dontUpgrade }
      return .upgrade()
    } onUpgrade: { inbound, outbound, context in
      guard let threadID = parseThreadID(context.request),
        let cursor = parseCursor(context.request)
      else { return }
      let stream = try await host.subscribe(threadID: threadID, afterSequence: cursor)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await _ in inbound {}
        }
        group.addTask {
          for await event in stream {
            let data = try OttoRPCCodec.encoder.encode(event)
            try await outbound.write(.text(String(decoding: data, as: UTF8.self)))
          }
        }
        _ = try await group.next()
        group.cancelAll()
      }
    }

    let webSocketConfiguration = HTTP1WebSocketUpgradeChannel.Configuration(
      ws: .init(autoPing: .enabled(timePeriod: .seconds(20)))
    )
    let baseServer = HTTPServerBuilder.http1WebSocketUpgrade(
      webSocketRouter: router,
      configuration: webSocketConfiguration
    )
    let server =
      if let tls = configuration.tls {
        try HTTPServerBuilder.tls(baseServer, tlsConfiguration: tls)
      } else {
        baseServer
      }
    return Application(
      router: router,
      server: server,
      configuration: applicationConfiguration
        ?? .init(
          address: .hostname(configuration.hostname, port: configuration.port),
          serverName: "Otto Mobile Host"
        ),
      onServerRunning: { _ in await onServerRunning() }
    )
  }

  private static func parseThreadID(_ request: Request) -> UUID? {
    request.uri.queryParameters["thread_id"].flatMap { UUID(uuidString: String($0)) }
  }

  private static func parseCursor(_ request: Request) -> Int64? {
    guard let raw = request.uri.queryParameters["after"], let value = Int64(raw), value >= 0
    else { return nil }
    return value
  }

  private static func authenticate(
    _ request: Request,
    requiredScope: OttoRPCScope,
    legacy: OttoHostTokenAuthenticator,
    pairing: (any OttoHostPairingHandling)?
  ) async throws -> OttoHostClientContext {
    guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer "),
      let rawDeviceID = request.headers[.init(OttoLegacyWire.deviceIDHeader)!],
      let deviceID = UUID(uuidString: rawDeviceID)
    else { throw HTTPError(.unauthorized, message: "Authentication failed.") }
    let credential = String(authorization.dropFirst("Bearer ".count))
    if let pairing,
      let client = try? await pairing.authenticate(
        deviceID: deviceID,
        credential: credential,
        requiredScope: requiredScope
      )
    {
      return client
    }
    return try legacy.client(for: request)
  }
}

private struct OttoHostTokenAuthenticator: Sendable {
  let token: [UInt8]
  let scopes: Set<OttoRPCScope>

  init(token: String, scopes: Set<OttoRPCScope>) {
    self.token = Array(token.utf8)
    self.scopes = scopes
  }

  func client(for request: Request) throws -> OttoHostClientContext {
    guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer ")
    else { throw HTTPError(.unauthorized, message: "Authentication failed.") }
    let candidate = Array(authorization.dropFirst("Bearer ".count).utf8)
    guard constantTimeEqual(candidate, token) else {
      throw HTTPError(.unauthorized, message: "Authentication failed.")
    }
    guard let rawDeviceID = request.headers[.init(OttoLegacyWire.deviceIDHeader)!],
      let deviceID = UUID(uuidString: rawDeviceID)
    else { throw HTTPError(.unauthorized, message: "Authentication failed.") }
    return OttoHostClientContext(deviceID: deviceID, scopes: scopes)
  }

  private func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    let count = max(lhs.count, rhs.count)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in 0..<count {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= left ^ right
    }
    return difference == 0
  }
}

private struct OttoHostJSONResponse<Value: Encodable & Sendable>: ResponseEncodable, Sendable {
  let value: Value

  init(_ value: Value) { self.value = value }

  func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

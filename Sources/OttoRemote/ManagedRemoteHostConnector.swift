import Foundation
import OttoCommercial
import OttoRPCContracts

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum ManagedRemoteHostConnectorError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case heartbeatRejected(Int)
  case invalidMessage
  case invalidTicket
  case ticketExpired
  case insufficientScope
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The managed remote connector configuration is invalid."
    case .heartbeatRejected(let status):
      "The control plane rejected the heartbeat (HTTP \(status))."
    case .invalidMessage: "The control plane sent an invalid connector message."
    case .invalidTicket: "The forwarded managed remote ticket is invalid."
    case .ticketExpired: "The forwarded managed remote ticket has expired."
    case .insufficientScope: "The forwarded managed remote ticket does not allow this operation."
    case .invalidResponse: "The local host returned an invalid RPC response."
    }
  }
}

public struct ManagedRemoteHostConnectorConfiguration: Sendable {
  public var controlPlaneURL: URL
  public var environmentID: UUID
  public var connectorCredential: String
  public var trustedTicketKeys: [String: Data]
  public var hostVersion: String
  public var protocolVersion: Int
  public var capabilities: [String]
  /// Interval used to renew the registry's 90-second presence lease while the socket is open.
  public var heartbeatInterval: Duration

  public init(
    controlPlaneURL: URL,
    environmentID: UUID,
    connectorCredential: String,
    trustedTicketKeys: [String: Data],
    hostVersion: String,
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    capabilities: [String],
    heartbeatInterval: Duration = .seconds(30)
  ) throws {
    guard let scheme = controlPlaneURL.scheme?.lowercased(),
      let host = controlPlaneURL.host,
      controlPlaneURL.user == nil,
      controlPlaneURL.password == nil,
      controlPlaneURL.query == nil,
      controlPlaneURL.fragment == nil,
      !connectorCredential.isEmpty,
      connectorCredential.utf8.count <= 1_024,
      !trustedTicketKeys.isEmpty,
      protocolVersion > 0,
      heartbeatInterval > .zero,
      scheme == "https" || (scheme == "http" && Self.isLoopback(host))
    else { throw ManagedRemoteHostConnectorError.invalidConfiguration }
    self.controlPlaneURL = controlPlaneURL
    self.environmentID = environmentID
    self.connectorCredential = connectorCredential
    self.trustedTicketKeys = trustedTicketKeys
    self.hostVersion = String(hostVersion.prefix(80))
    self.protocolVersion = protocolVersion
    self.capabilities = Array(Set(capabilities)).sorted()
    self.heartbeatInterval = heartbeatInterval
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "127.0.0.1" || host == "::1" || host == "localhost"
  }
}

public actor ManagedRemoteHostConnector {
  public typealias RequestHandler =
    @Sendable (
      OttoRPCRequest,
      ManagedConnectionTicketClaims
    ) async -> OttoRPCResponse

  private let configuration: ManagedRemoteHostConnectorConfiguration
  private let session: URLSession
  private let verifier: SignedDocumentVerifier
  private let now: @Sendable () -> Date
  private let handler: RequestHandler
  private var activeTask: URLSessionWebSocketTask?
  public private(set) var lastErrorDescription: String?

  public init(
    configuration: ManagedRemoteHostConnectorConfiguration,
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = Date.init,
    handler: @escaping RequestHandler
  ) {
    self.configuration = configuration
    self.session = session
    verifier = SignedDocumentVerifier(publicKeys: configuration.trustedTicketKeys)
    self.now = now
    self.handler = handler
  }

  public func run() async {
    var retrySeconds = 1
    while !Task.isCancelled {
      do {
        try await connectOnce()
        retrySeconds = 1
      } catch is CancellationError {
        break
      } catch {
        lastErrorDescription = error.localizedDescription
        try? await Task.sleep(for: .seconds(retrySeconds))
        retrySeconds = min(retrySeconds * 2, 30)
      }
    }
  }

  public func connectOnce() async throws {
    try Task.checkCancellation()
    try await sendHeartbeat()
    var request = URLRequest(url: try webSocketURL())
    request.setValue(
      "Bearer \(configuration.connectorCredential)", forHTTPHeaderField: "Authorization")
    let task = session.webSocketTask(with: request)
    activeTask = task
    task.resume()
    defer {
      task.cancel(with: .goingAway, reason: nil)
      if activeTask === task { activeTask = nil }
    }
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.receiveMessages(on: task) }
        group.addTask { try await self.sendHeartbeats() }
        do {
          _ = try await group.next()
          task.cancel(with: .goingAway, reason: nil)
          group.cancelAll()
          try await group.waitForAll()
        } catch {
          task.cancel(with: .goingAway, reason: nil)
          group.cancelAll()
          throw error
        }
      }
    } onCancel: {
      task.cancel(with: .goingAway, reason: nil)
    }
  }

  public func stop() {
    activeTask?.cancel(with: .goingAway, reason: nil)
    activeTask = nil
  }

  private func sendHeartbeat() async throws {
    let input = ManagedEnvironmentHeartbeatRequest(
      environmentID: configuration.environmentID,
      hostVersion: configuration.hostVersion,
      protocolVersion: configuration.protocolVersion,
      capabilities: configuration.capabilities
    )
    var request = URLRequest(
      url: endpointURL(path: "v1/managed/environments/heartbeat")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Bearer \(configuration.connectorCredential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder.commercial.encode(input)
    let (_, response) = try await session.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw ManagedRemoteHostConnectorError.heartbeatRejected(response.statusCode)
    }
  }

  private func sendHeartbeats() async throws {
    while !Task.isCancelled {
      try await Task.sleep(for: configuration.heartbeatInterval)
      try await sendHeartbeat()
    }
  }

  private func receiveMessages(on task: URLSessionWebSocketTask) async throws {
    while !Task.isCancelled {
      let message = try await task.receive()
      try await process(message, on: task)
    }
  }

  private func process(
    _ message: URLSessionWebSocketTask.Message,
    on task: URLSessionWebSocketTask
  ) async throws {
    let data: Data
    switch message {
    case .data(let value): data = value
    case .string(let value): data = Data(value.utf8)
    @unknown default: throw ManagedRemoteHostConnectorError.invalidMessage
    }
    guard
      let envelope = try? JSONDecoder.commercial.decode(
        ManagedRelayWireRequest.self,
        from: data
      )
    else { throw ManagedRemoteHostConnectorError.invalidMessage }
    let claims: ManagedConnectionTicketClaims
    do {
      claims = try verifier.verify(envelope.ticket, as: ManagedConnectionTicketClaims.self)
    } catch {
      throw ManagedRemoteHostConnectorError.invalidTicket
    }
    let date = now()
    guard claims.environmentID == configuration.environmentID,
      claims.endpoint.scheme?.lowercased() == "https",
      claims.issuedAt <= date.addingTimeInterval(30),
      claims.expiresAt.timeIntervalSince(claims.issuedAt) <= 300
    else { throw ManagedRemoteHostConnectorError.invalidTicket }
    guard claims.expiresAt > date else { throw ManagedRemoteHostConnectorError.ticketExpired }
    guard claims.scopes.contains(envelope.request.method.requiredScope.rawValue) else {
      throw ManagedRemoteHostConnectorError.insufficientScope
    }
    let response = await handler(envelope.request, claims)
    guard response.id == envelope.request.id,
      response.protocolVersion == envelope.request.protocolVersion
    else { throw ManagedRemoteHostConnectorError.invalidResponse }
    let output = ManagedRelayWireResponse(id: envelope.id, response: response)
    try await task.send(
      .string(
        String(
          decoding: try JSONEncoder.commercial.encode(output),
          as: UTF8.self
        )))
  }

  private func endpointURL(path: String) -> URL {
    configuration.controlPlaneURL.appending(path: path)
  }

  private func webSocketURL() throws -> URL {
    guard
      var components = URLComponents(
        url: endpointURL(path: "v1/managed/connectors"),
        resolvingAgainstBaseURL: false
      )
    else { throw ManagedRemoteHostConnectorError.invalidConfiguration }
    components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
    components.queryItems = [
      URLQueryItem(name: "environment_id", value: configuration.environmentID.uuidString)
    ]
    guard let url = components.url else {
      throw ManagedRemoteHostConnectorError.invalidConfiguration
    }
    return url
  }
}

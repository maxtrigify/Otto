import Foundation
import OttoCommercial
import OttoModels
import OttoRPCContracts

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct OttoManagedRelayForwardInput: Encodable, Sendable {
  var ticket: SignedDocument
  var request: OttoRPCRequest
}

public enum OttoManagedMobileError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case invalidResponse
  case subscriptionRequired
  case httpStatus(Int)
  case environmentUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The managed Otto connection is invalid."
    case .invalidResponse: "The Otto control plane returned an invalid response."
    case .subscriptionRequired:
      "Otto Remote needs an active subscription. Local and Tailscale connections are unaffected."
    case .httpStatus(let status): "The Otto control plane returned HTTP \(status)."
    case .environmentUnavailable: "That Mac is not available through the managed relay."
    }
  }
}

public struct OttoManagedMobileDeviceRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { deviceID }
  public var controlPlaneURL: URL
  public var accountID: UUID
  public var deviceID: UUID
  public var credential: String
  public var devicePrivateKey: Data
  public var registeredAt: Date

  public init(
    controlPlaneURL: URL,
    accountID: UUID,
    deviceID: UUID,
    credential: String,
    devicePrivateKey: Data,
    registeredAt: Date = .now
  ) throws {
    guard Self.isSafeControlPlane(controlPlaneURL),
      !credential.isEmpty,
      credential.utf8.count <= 1_024,
      devicePrivateKey.count == 32
    else { throw OttoManagedMobileError.invalidConfiguration }
    self.controlPlaneURL = controlPlaneURL
    self.accountID = accountID
    self.deviceID = deviceID
    self.credential = credential
    self.devicePrivateKey = devicePrivateKey
    self.registeredAt = registeredAt
  }

  public func connectionConfiguration(
    environmentID: UUID
  ) -> OttoManagedMobileConnectionConfiguration {
    OttoManagedMobileConnectionConfiguration(
      controlPlaneURL: controlPlaneURL,
      deviceID: deviceID,
      credential: credential,
      environmentID: environmentID
    )
  }

  static func isSafeControlPlane(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return false }
    let loopback = host == "127.0.0.1" || host == "::1" || host == "localhost"
    return scheme == "https" || (scheme == "http" && loopback)
  }
}

public struct OttoManagedMobileConnectionConfiguration: Equatable, Sendable {
  public var controlPlaneURL: URL
  public var deviceID: UUID
  public var credential: String
  public var environmentID: UUID

  public init(
    controlPlaneURL: URL,
    deviceID: UUID,
    credential: String,
    environmentID: UUID
  ) {
    self.controlPlaneURL = controlPlaneURL
    self.deviceID = deviceID
    self.credential = credential
    self.environmentID = environmentID
  }
}

public actor OttoManagedMobileControlPlaneClient {
  private let record: OttoManagedMobileDeviceRecord
  private let session: URLSession

  public init(
    record: OttoManagedMobileDeviceRecord,
    session: URLSession = .shared
  ) {
    self.record = record
    self.session = session
  }

  public func environments() async throws -> [ManagedEnvironmentPresence] {
    guard
      var components = URLComponents(
        url: record.controlPlaneURL.appending(path: "v1/managed/environments"),
        resolvingAgainstBaseURL: false
      )
    else { throw OttoManagedMobileError.invalidConfiguration }
    components.queryItems = [URLQueryItem(name: "device_id", value: record.deviceID.uuidString)]
    guard let url = components.url else { throw OttoManagedMobileError.invalidConfiguration }
    var request = URLRequest(url: url)
    addAuthentication(to: &request)
    return try await send(request, decoding: [ManagedEnvironmentPresence].self)
  }

  public func connection(environmentID: UUID) -> OttoManagedMobileConnection {
    OttoManagedMobileConnection(
      configuration: record.connectionConfiguration(environmentID: environmentID),
      session: session
    )
  }

  private func send<Value: Decodable>(
    _ request: URLRequest,
    decoding _: Value.Type
  ) async throws -> Value {
    let (data, response) = try await session.data(for: request)
    if response.statusCode == 402 { throw OttoManagedMobileError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw OttoManagedMobileError.httpStatus(response.statusCode)
    }
    guard let value = try? JSONDecoder.commercial.decode(Value.self, from: data) else {
      throw OttoManagedMobileError.invalidResponse
    }
    return value
  }

  private func addAuthentication(to request: inout URLRequest) {
    request.setValue("Bearer \(record.credential)", forHTTPHeaderField: "Authorization")
  }
}

public actor OttoManagedMobileConnection: OttoMobileConnecting {
  private let configuration: OttoManagedMobileConnectionConfiguration
  private let session: URLSession

  public init(
    configuration: OttoManagedMobileConnectionConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func capabilities() async throws -> EnvironmentCapabilitiesOutput {
    try await call(.environmentGetCapabilities, parameters: EmptyParameters())
  }

  public func listBots() async throws -> MobileRosterOutput {
    try await call(.botList, parameters: EmptyParameters())
  }

  public func listThreads() async throws -> ThreadListOutput {
    try await call(.threadList, parameters: EmptyParameters())
  }

  public func startThread(
    botProfileID: UUID,
    initialMessage: String?
  ) async throws -> ThreadStartOutput {
    try await call(
      .threadStart,
      parameters: ThreadStartInput(botProfileID: botProfileID, initialMessage: initialMessage)
    )
  }

  public func registerPush(
    token: String,
    environment: OttoPushEnvironment
  ) async throws -> AcceptedOutput {
    try await call(
      .deviceRegisterPush,
      parameters: DeviceRegisterPushInput(token: token, environment: environment)
    )
  }

  public func snapshot(threadID: UUID) async throws -> ThreadSnapshot {
    try await call(.threadGetSnapshot, parameters: ThreadReferenceInput(threadID: threadID))
  }

  public func events(threadID: UUID, afterSequence: Int64) async throws -> ThreadEventPage {
    try await call(
      .threadEvents,
      parameters: ThreadEventCursorInput(threadID: threadID, afterSequence: afterSequence)
    )
  }

  public func send(
    threadID: UUID,
    clientMessageID: UUID,
    body: String
  ) async throws -> MessageSendOutput {
    try await call(
      .messageSend,
      parameters: MessageSendInput(
        threadID: threadID,
        clientMessageID: clientMessageID,
        body: body
      )
    )
  }

  public func interrupt(threadID: UUID, runID: UUID) async throws -> AcceptedOutput {
    try await call(.runInterrupt, parameters: RunControlInput(threadID: threadID, runID: runID))
  }

  public func stop(threadID: UUID, runID: UUID) async throws -> AcceptedOutput {
    try await call(.runStop, parameters: RunControlInput(threadID: threadID, runID: runID))
  }

  public func pendingApproval(threadID: UUID) async throws -> ApprovalGetOutput {
    try await call(.approvalGet, parameters: ApprovalGetInput(threadID: threadID))
  }

  public func respondToApproval(
    _ input: ApprovalRespondInput
  ) async throws -> ApprovalRespondOutput {
    try await call(.approvalRespond, parameters: input)
  }

  public func listAttachments(threadID: UUID) async throws -> AttachmentListOutput {
    try await call(.attachmentList, parameters: AttachmentListInput(threadID: threadID))
  }

  public func prepareAttachmentUpload(
    _ input: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    try await call(.attachmentPrepareUpload, parameters: input)
  }

  public func uploadAttachmentChunk(
    _ input: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    try await call(.attachmentUploadChunk, parameters: input)
  }

  public func downloadAttachmentChunk(
    _ input: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    try await call(.attachmentDownloadChunk, parameters: input)
  }

  public func diagnostics() async throws -> MobileDiagnosticsOutput {
    try await call(.diagnosticsGet, parameters: EmptyParameters())
  }

  public func eventStream(
    threadID: UUID,
    afterSequence: Int64
  ) async throws -> AsyncThrowingStream<RunEvent, Error> {
    AsyncThrowingStream { continuation in
      let polling = Task {
        var cursor = afterSequence
        do {
          while !Task.isCancelled {
            let page = try await self.events(threadID: threadID, afterSequence: cursor)
            for event in page.events where event.sequence > cursor {
              continuation.yield(event)
              cursor = event.sequence
            }
            if page.hasMore { continue }
            try await Task.sleep(for: .seconds(1))
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in polling.cancel() }
    }
  }

  private func call<Parameters: Encodable & Sendable, Output: Decodable>(
    _ method: OttoRPCMethod,
    parameters: Parameters
  ) async throws -> Output {
    let ticket = try await issueTicket(scope: method.requiredScope)
    let rpc = try OttoRPCRequest(method: method, parameters: parameters)
    let input = OttoManagedRelayForwardInput(ticket: ticket, request: rpc)
    var request = URLRequest(
      url: configuration.controlPlaneURL.appending(
        path: "v1/environments/\(configuration.environmentID.uuidString.lowercased())/rpc"
      )
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder.commercial.encode(input)
    let (data, response) = try await session.data(for: request)
    if response.statusCode == 402 { throw OttoManagedMobileError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw OttoManagedMobileError.httpStatus(response.statusCode)
    }
    guard
      let rpcResponse = try? JSONDecoder.commercial.decode(
        OttoRPCResponse.self,
        from: data
      )
    else { throw OttoManagedMobileError.invalidResponse }
    return try rpcResponse.decodeResult(Output.self)
  }

  private func issueTicket(scope: OttoRPCScope) async throws -> SignedDocument {
    let input = ManagedConnectionTicketRequest(
      deviceID: configuration.deviceID,
      environmentID: configuration.environmentID,
      scopes: [scope.rawValue],
      lifetime: 120
    )
    var request = URLRequest(
      url: configuration.controlPlaneURL.appending(path: "v1/managed/tickets")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(configuration.credential)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder.commercial.encode(input)
    let (data, response) = try await session.data(for: request)
    if response.statusCode == 402 { throw OttoManagedMobileError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw OttoManagedMobileError.httpStatus(response.statusCode)
    }
    guard let ticket = try? JSONDecoder.commercial.decode(SignedDocument.self, from: data) else {
      throw OttoManagedMobileError.invalidResponse
    }
    return ticket
  }
}

import Foundation
import OttoModels
import OttoRPCContracts

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OttoMobileConnectionConfiguration: Codable, Equatable, Sendable {
  public var baseURL: URL
  public var token: String
  public var deviceID: UUID

  public init(baseURL: URL, token: String, deviceID: UUID) {
    self.baseURL = baseURL
    self.token = token
    self.deviceID = deviceID
  }
}

public enum OttoMobileConnectionError: Error, LocalizedError, Equatable, Sendable {
  case invalidURL
  case privateInputUnsupported
  case invalidResponse
  case httpStatus(Int)
  case eventGap(expected: Int64, received: Int64)

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "The Otto Host URL is invalid."
    case .privateInputUnsupported:
      "This connection does not support private sign-in. Use Website Accounts on your Mac or a direct paired HTTPS connection."
    case .invalidResponse: "Otto Host returned an invalid response."
    case .httpStatus(let status): "Otto Host returned HTTP \(status)."
    case .eventGap(let expected, let received):
      "The event stream skipped from \(expected) to \(received)."
    }
  }
}

public protocol OttoMobileConnecting: Sendable {
  func secureLogin(_ input: SecureLoginInput) async throws -> SecureLoginOutput
  func capabilities() async throws -> EnvironmentCapabilitiesOutput
  func listBots() async throws -> MobileRosterOutput
  func listThreads() async throws -> ThreadListOutput
  func startThread(botProfileID: UUID, initialMessage: String?) async throws -> ThreadStartOutput
  func registerPush(token: String, environment: OttoPushEnvironment) async throws -> AcceptedOutput
  func snapshot(threadID: UUID) async throws -> ThreadSnapshot
  func events(threadID: UUID, afterSequence: Int64) async throws -> ThreadEventPage
  func send(threadID: UUID, clientMessageID: UUID, body: String) async throws
    -> MessageSendOutput
  func interrupt(threadID: UUID, runID: UUID) async throws -> AcceptedOutput
  func stop(threadID: UUID, runID: UUID) async throws -> AcceptedOutput
  func pendingApproval(threadID: UUID) async throws -> ApprovalGetOutput
  func respondToApproval(_ input: ApprovalRespondInput) async throws -> ApprovalRespondOutput
  func listAttachments(threadID: UUID) async throws -> AttachmentListOutput
  func prepareAttachmentUpload(
    _ input: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput
  func uploadAttachmentChunk(
    _ input: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput
  func downloadAttachmentChunk(
    _ input: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput
  func diagnostics() async throws -> MobileDiagnosticsOutput
  func eventStream(threadID: UUID, afterSequence: Int64) async throws
    -> AsyncThrowingStream<RunEvent, Error>
}

extension OttoMobileConnecting {
  public func secureLogin(_ input: SecureLoginInput) async throws -> SecureLoginOutput {
    throw OttoMobileConnectionError.privateInputUnsupported
  }
  public func pendingApproval(threadID _: UUID) async throws -> ApprovalGetOutput {
    ApprovalGetOutput(request: nil)
  }

  public func respondToApproval(_: ApprovalRespondInput) async throws -> ApprovalRespondOutput {
    throw OttoMobileConnectionError.invalidResponse
  }
  public func listAttachments(threadID _: UUID) async throws -> AttachmentListOutput {
    AttachmentListOutput(attachments: [])
  }
  public func prepareAttachmentUpload(
    _: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    throw OttoMobileConnectionError.invalidResponse
  }
  public func uploadAttachmentChunk(
    _: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    throw OttoMobileConnectionError.invalidResponse
  }
  public func downloadAttachmentChunk(
    _: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    throw OttoMobileConnectionError.invalidResponse
  }
  public func diagnostics() async throws -> MobileDiagnosticsOutput {
    throw OttoMobileConnectionError.invalidResponse
  }
}

public actor OttoMobileConnection: OttoMobileConnecting {
  private let configuration: OttoMobileConnectionConfiguration
  private let session: URLSession

  public init(
    configuration: OttoMobileConnectionConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func secureLogin(_ input: SecureLoginInput) async throws -> SecureLoginOutput {
    let url = configuration.baseURL
    let loopback = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    guard url.scheme == "https" || (url.scheme == "http" && loopback) else {
      throw OttoMobileConnectionError.invalidURL
    }
    var request = URLRequest(
      url: url.appending(path: "v1/secure-login"), cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    addAuthentication(to: &request)
    request.httpBody = try JSONEncoder().encode(input)
    // Ephemeral transport, no generic RPC journal, retry, cache, or diagnostic payload.
    let privateSession = URLSession(
      configuration: .ephemeral, delegate: SecureLoginRedirectDelegate(), delegateQueue: nil)
    defer { privateSession.invalidateAndCancel() }
    let (data, response) = try await privateSession.data(for: request)
    guard response.statusCode == 200 else {
      throw OttoMobileConnectionError.invalidResponse
    }
    return try JSONDecoder().decode(SecureLoginOutput.self, from: data)
  }

  public func capabilities() async throws -> EnvironmentCapabilitiesOutput {
    try await call(.environmentGetCapabilities, parameters: EmptyParameters())
  }

  public func listThreads() async throws -> ThreadListOutput {
    try await call(.threadList, parameters: EmptyParameters())
  }

  public func listBots() async throws -> MobileRosterOutput {
    try await call(.botList, parameters: EmptyParameters())
  }

  public func startThread(
    botProfileID: UUID,
    initialMessage: String? = nil
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
    try await call(
      .threadGetSnapshot,
      parameters: ThreadReferenceInput(threadID: threadID)
    )
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

  public func eventStream(threadID: UUID, afterSequence: Int64) async throws
    -> AsyncThrowingStream<RunEvent, Error>
  {
    guard
      var components = URLComponents(
        url: configuration.baseURL.appending(path: "v1/events"),
        resolvingAgainstBaseURL: false
      )
    else { throw OttoMobileConnectionError.invalidURL }
    components.scheme =
      switch components.scheme {
      case "https": "wss"
      case "http": "ws"
      default: nil
      }
    components.queryItems = [
      URLQueryItem(name: "thread_id", value: threadID.uuidString),
      URLQueryItem(name: "after", value: String(afterSequence)),
    ]
    guard let url = components.url else { throw OttoMobileConnectionError.invalidURL }
    var request = URLRequest(url: url)
    addAuthentication(to: &request)
    let task = session.webSocketTask(with: request)
    task.resume()
    return AsyncThrowingStream { continuation in
      let receiveTask = Task {
        do {
          while !Task.isCancelled {
            let message = try await task.receive()
            let data: Data =
              switch message {
              case .data(let data): data
              case .string(let text): Data(text.utf8)
              @unknown default: throw OttoMobileConnectionError.invalidResponse
              }
            continuation.yield(try OttoRPCCodec.decoder.decode(RunEvent.self, from: data))
          }
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        receiveTask.cancel()
        task.cancel(with: .goingAway, reason: nil)
      }
    }
  }

  private func call<Parameters: Encodable & Sendable, Output: Decodable>(
    _ method: OttoRPCMethod,
    parameters: Parameters
  ) async throws -> Output {
    let rpc = try OttoRPCRequest(method: method, parameters: parameters)
    var request = URLRequest(url: configuration.baseURL.appending(path: "v1/rpc"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    addAuthentication(to: &request)
    request.httpBody = try OttoRPCCodec.encoder.encode(rpc)
    let (data, http) = try await session.data(for: request)
    guard (200..<300).contains(http.statusCode) else {
      throw OttoMobileConnectionError.httpStatus(http.statusCode)
    }
    let rpcResponse = try OttoRPCCodec.decoder.decode(OttoRPCResponse.self, from: data)
    return try rpcResponse.decodeResult(Output.self)
  }

  private func addAuthentication(to request: inout URLRequest) {
    request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
    request.setValue(
      configuration.deviceID.uuidString, forHTTPHeaderField: OttoLegacyWire.deviceIDHeader)
  }
}

private final class SecureLoginRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

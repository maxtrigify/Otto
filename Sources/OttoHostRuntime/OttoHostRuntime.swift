import Foundation
import OttoModels
import OttoRPCContracts

public struct OttoHostClientContext: Sendable, Equatable {
  public var deviceID: UUID
  public var scopes: Set<OttoRPCScope>

  public init(deviceID: UUID, scopes: Set<OttoRPCScope>) {
    self.deviceID = deviceID
    self.scopes = scopes
  }
}

/// The host boundary depends on this projection/command surface rather than owning provider
/// processes. The Mac app adapter delegates these calls to the existing ApplicationServices.
public protocol OttoHostDataSource: Sendable {
  func secureLogin(_ input: SecureLoginInput, deviceID: UUID) async throws -> SecureLoginOutput
  func environment() async -> ExecutionEnvironment
  func listBots() async throws -> MobileRosterOutput
  func listThreads() async throws -> [OttoModels.Thread]
  func startThread(_ input: ThreadStartInput) async throws -> ThreadStartOutput
  func registerPush(deviceID: UUID, input: DeviceRegisterPushInput) async throws
  func snapshot(threadID: UUID) async throws -> ThreadSnapshot
  func sendMessage(threadID: UUID, body: String) async throws -> ThreadMessage
  func interrupt(threadID: UUID, runID: UUID) async throws
  func stop(threadID: UUID, runID: UUID) async throws
  func pendingApproval(threadID: UUID) async throws -> MobileApprovalRequest?
  func respondToApproval(_ input: ApprovalRespondInput) async throws
  func listAttachments(threadID: UUID) async throws -> [OttoAttachment]
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
}

extension OttoHostDataSource {
  public func secureLogin(_ input: SecureLoginInput, deviceID: UUID) async throws
    -> SecureLoginOutput
  {
    throw OttoHostError.unsupportedOperation("Secure sign-in")
  }
  public func listBots() async throws -> MobileRosterOutput {
    MobileRosterOutput(bots: [], teams: [])
  }
  public func startThread(_: ThreadStartInput) async throws -> ThreadStartOutput {
    throw OttoHostError.unsupportedOperation("Starting a mobile session")
  }
  public func registerPush(deviceID _: UUID, input _: DeviceRegisterPushInput) async throws {
    throw OttoHostError.unsupportedOperation("Push registration")
  }
  public func pendingApproval(threadID _: UUID) async throws -> MobileApprovalRequest? { nil }
  public func respondToApproval(_: ApprovalRespondInput) async throws {
    throw OttoHostError.unsupportedOperation("Remote approval")
  }
  public func listAttachments(threadID _: UUID) async throws -> [OttoAttachment] { [] }
  public func prepareAttachmentUpload(
    _: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    throw OttoHostError.unsupportedOperation("Attachment upload")
  }
  public func uploadAttachmentChunk(
    _: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    throw OttoHostError.unsupportedOperation("Attachment upload")
  }
  public func downloadAttachmentChunk(
    _: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    throw OttoHostError.unsupportedOperation("Attachment download")
  }
  public func diagnostics() async throws -> MobileDiagnosticsOutput {
    throw OttoHostError.diagnosticsUnavailable
  }
}

public struct RunEventDraft: Sendable, Equatable {
  public var id: UUID
  public var threadID: UUID
  public var timestamp: Date
  public var kind: RunEventKind
  public var author: RunEventAuthor?
  public var correlationID: UUID?
  public var causationID: UUID?
  public var content: RunEventContent

  public init(
    id: UUID = UUID(),
    threadID: UUID,
    timestamp: Date = .now,
    kind: RunEventKind,
    author: RunEventAuthor? = nil,
    correlationID: UUID? = nil,
    causationID: UUID? = nil,
    content: RunEventContent = RunEventContent()
  ) {
    self.id = id
    self.threadID = threadID
    self.timestamp = timestamp
    self.kind = kind
    self.author = author
    self.correlationID = correlationID
    self.causationID = causationID
    self.content = content
  }
}

public enum OttoHostError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedProtocol(Int)
  case forbidden(OttoRPCScope)
  case invalidCursor
  case invalidLimit
  case invalidMessage
  case commandConflict
  case commandUncertain
  case staleRun
  case threadNotFound(UUID)
  case botNotFound(UUID)
  case unsupportedOperation(String)
  case approvalUnavailable
  case invalidAttachment(String)
  case attachmentTransferUnavailable
  case diagnosticsUnavailable
  case journal(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedProtocol(let version):
      "Otto RPC protocol version \(version) is not supported."
    case .forbidden(let scope): "The paired device lacks the \(scope.rawValue) scope."
    case .invalidCursor: "Event cursors cannot be negative."
    case .invalidLimit: "Event page size is outside the supported range."
    case .staleRun: "That run has changed. Refresh before sending another control."
    case .commandConflict: "This message ID was already used for different content."
    case .commandUncertain:
      "This message may already have been accepted. Check the conversation before sending new work."
    case .invalidMessage:
      "Messages must contain non-whitespace text and at most 100,000 characters."
    case .threadNotFound(let id): "Thread \(id.uuidString) was not found."
    case .botNotFound(let id): "Bot \(id.uuidString) was not found."
    case .unsupportedOperation(let operation): "\(operation) is unavailable on this host."
    case .approvalUnavailable: "That approval is no longer pending. Refresh before responding."
    case .invalidAttachment(let reason): "The attachment is invalid: \(reason)"
    case .attachmentTransferUnavailable: "That attachment transfer expired or is unavailable."
    case .diagnosticsUnavailable: "Privacy-safe diagnostics are unavailable on this host."
    case .journal(let message): "The Otto host event journal failed: \(message)"
    }
  }
}

/// Durable per-thread JSONL storage. A reconnect cursor is meaningful across host restarts and
/// every append is synchronized before subscribers observe it.
public actor RunEventJournal {
  public static let maximumPageSize = 500

  private let directory: URL
  private let maximumBytesPerThread: Int64
  private var history: [UUID: [RunEvent]] = [:]
  private var commands: [UUID: MessageSendInput] = [:]
  private var subscribers: [UUID: [UUID: AsyncStream<RunEvent>.Continuation]] = [:]

  public init(
    directory: URL,
    maximumBytesPerThread: Int64 = 64 * 1_024 * 1_024
  ) throws {
    guard maximumBytesPerThread > 0 else { throw OttoHostError.invalidLimit }
    self.directory = directory
    self.maximumBytesPerThread = maximumBytesPerThread
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    )
    for file in files where file.pathExtension == "command" {
      let command = try OttoRPCCodec.decoder.decode(
        MessageSendInput.self, from: Data(contentsOf: file))
      commands[command.clientMessageID] = command
    }
    for file in files where file.pathExtension == "jsonl" {
      guard let threadID = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
        continue
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      guard byteCount <= maximumBytesPerThread else {
        throw OttoHostError.journal("\(file.lastPathComponent) exceeds its byte limit")
      }
      let data = try Data(contentsOf: file)
      let events = try data.split(separator: 0x0a).filter { !$0.isEmpty }.map {
        try OttoRPCCodec.decoder.decode(RunEvent.self, from: Data($0))
      }
      for (index, event) in events.enumerated() {
        guard event.threadID == threadID, event.sequence == Int64(index + 1) else {
          throw OttoHostError.journal("\(file.lastPathComponent) has a non-contiguous sequence")
        }
      }
      history[threadID] = events
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }

  /// Admission is committed before dispatch. Unfinished receipts are deliberately not replayed:
  /// a provider may have accepted work before the host lost its acknowledgement.
  public func reserveCommand(_ input: MessageSendInput) throws -> RunEvent? {
    if let previous = commands[input.clientMessageID] {
      guard previous.threadID == input.threadID, previous.body == input.body else {
        throw OttoHostError.commandConflict
      }
      guard let receipt = event(threadID: input.threadID, correlationID: input.clientMessageID)
      else {
        throw OttoHostError.commandUncertain
      }
      return receipt
    }
    // Upgrade compatibility for commands journaled before durable admission existed.
    if let receipt = event(threadID: input.threadID, correlationID: input.clientMessageID) {
      guard receipt.content.message?.text == input.body else { throw OttoHostError.commandConflict }
      return receipt
    }
    let file = directory.appending(path: "\(input.clientMessageID.uuidString).command")
    try OttoRPCCodec.encoder.encode(input).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.synchronize()
    commands[input.clientMessageID] = input
    return nil
  }

  @discardableResult
  public func append(_ draft: RunEventDraft) throws -> RunEvent {
    if let existing = history[draft.threadID]?.first(where: { $0.id == draft.id }) {
      return existing
    }
    let sequence = Int64((history[draft.threadID]?.count ?? 0) + 1)
    let event = RunEvent(
      id: draft.id,
      threadID: draft.threadID,
      sequence: sequence,
      timestamp: millisecondDate(draft.timestamp),
      kind: draft.kind,
      author: draft.author,
      correlationID: draft.correlationID,
      causationID: draft.causationID,
      content: draft.content
    )
    let file = fileURL(threadID: draft.threadID)
    if !FileManager.default.fileExists(atPath: file.path) {
      guard
        FileManager.default.createFile(
          atPath: file.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else { throw OttoHostError.journal("Could not create \(file.lastPathComponent)") }
    }
    var data = try OttoRPCCodec.encoder.encode(event)
    data.append(0x0a)
    let currentBytes =
      (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
      .int64Value ?? 0
    guard currentBytes + Int64(data.count) <= maximumBytesPerThread else {
      throw OttoHostError.journal("\(file.lastPathComponent) exceeds its byte limit")
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
    history[draft.threadID, default: []].append(event)
    if let continuations = subscribers[draft.threadID]?.values {
      for continuation in continuations { continuation.yield(event) }
    }
    return event
  }

  public func page(threadID: UUID, afterSequence: Int64, limit: Int) throws -> ThreadEventPage {
    guard afterSequence >= 0 else { throw OttoHostError.invalidCursor }
    guard (1...Self.maximumPageSize).contains(limit) else { throw OttoHostError.invalidLimit }
    let allEvents = history[threadID] ?? []
    let events = Array(allEvents.lazy.filter { $0.sequence > afterSequence }.prefix(limit))
    let latest = Int64(allEvents.count)
    return ThreadEventPage(
      threadID: threadID,
      events: events,
      latestSequence: latest,
      hasMore: events.last.map { $0.sequence < latest } ?? false
    )
  }

  public func latestSequence(threadID: UUID) -> Int64 {
    Int64(history[threadID]?.count ?? 0)
  }

  public func event(threadID: UUID, correlationID: UUID) -> RunEvent? {
    history[threadID]?.first { $0.correlationID == correlationID }
  }

  public func event(threadID: UUID, messageID: UUID) -> RunEvent? {
    history[threadID]?.first { $0.content.message?.id == messageID }
  }

  public func stream(threadID: UUID, afterSequence: Int64 = 0) throws -> AsyncStream<RunEvent> {
    guard afterSequence >= 0 else { throw OttoHostError.invalidCursor }
    let subscriberID = UUID()
    let replay = history[threadID]?.filter { $0.sequence > afterSequence } ?? []
    return AsyncStream<RunEvent>(bufferingPolicy: .unbounded) { continuation in
      subscribers[threadID, default: [:]][subscriberID] = continuation
      for event in replay { continuation.yield(event) }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(subscriberID, threadID: threadID) }
      }
    }
  }

  private func removeSubscriber(_ subscriberID: UUID, threadID: UUID) {
    subscribers[threadID]?[subscriberID] = nil
    if subscribers[threadID]?.isEmpty == true { subscribers[threadID] = nil }
  }

  private func fileURL(threadID: UUID) -> URL {
    directory.appending(path: "\(threadID.uuidString.lowercased()).jsonl")
  }

  private func millisecondDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 * 1_000) / 1_000)
  }
}

/// Typed local host API. HTTPS/WSS, pairing tickets, and relay transport wrap this boundary; they
/// do not gain direct access to ApplicationServices or provider processes.
public actor OttoHostRuntime {
  private let dataSource: any OttoHostDataSource
  public let journal: RunEventJournal
  private var submissions: [UUID: (input: MessageSendInput, task: Task<MessageSendOutput, Error>)] =
    [:]

  public init(dataSource: any OttoHostDataSource, journal: RunEventJournal) {
    self.dataSource = dataSource
    self.journal = journal
  }

  /// Deliberately outside the journaled/message RPC path. Never logs or caches payloads.
  public func secureLogin(_ input: SecureLoginInput, client: OttoHostClientContext) async throws
    -> SecureLoginOutput
  {
    guard client.scopes.contains(.secureLogin) else { throw OttoHostError.forbidden(.secureLogin) }
    return try await dataSource.secureLogin(input, deviceID: client.deviceID)
  }

  public func handle(_ request: OttoRPCRequest, client: OttoHostClientContext) async
    -> OttoRPCResponse
  {
    do {
      guard OttoRPCProtocol.supportedVersions.contains(request.protocolVersion) else {
        throw OttoHostError.unsupportedProtocol(request.protocolVersion)
      }
      guard client.scopes.contains(request.method.requiredScope) else {
        throw OttoHostError.forbidden(request.method.requiredScope)
      }
      switch request.method {
      case .environmentGetCapabilities:
        return try response(
          request,
          EnvironmentCapabilitiesOutput(
            environment: await dataSource.environment(),
            supportedProtocolVersions: Array(OttoRPCProtocol.supportedVersions)
          ))
      case .threadList:
        var threads = try await dataSource.listThreads()
        for index in threads.indices {
          threads[index].lastEventSequence = await journal.latestSequence(
            threadID: threads[index].id)
        }
        return try response(request, ThreadListOutput(threads: threads))
      case .botList:
        return try response(request, try await dataSource.listBots())
      case .threadStart:
        let input = try request.decodeParameters(ThreadStartInput.self)
        return try response(request, try await dataSource.startThread(input))
      case .deviceRegisterPush:
        let input = try request.decodeParameters(DeviceRegisterPushInput.self)
        try await dataSource.registerPush(deviceID: client.deviceID, input: input)
        return try response(request, AcceptedOutput(accepted: true))
      case .threadGetSnapshot:
        let input = try request.decodeParameters(ThreadReferenceInput.self)
        // Capture before the asynchronous snapshot: replay may overlap its contents, but can
        // never skip an event emitted while the snapshot was being read. Clients deduplicate IDs.
        let latest = await journal.latestSequence(threadID: input.threadID)
        var snapshot = try await dataSource.snapshot(threadID: input.threadID)
        snapshot.thread.lastEventSequence = latest
        snapshot.lastEventSequence = latest
        return try response(request, snapshot)
      case .threadEvents, .threadSubscribe:
        let input = try request.decodeParameters(ThreadEventCursorInput.self)
        try await requireThread(input.threadID)
        return try response(
          request,
          try await journal.page(
            threadID: input.threadID,
            afterSequence: input.afterSequence,
            limit: input.limit
          ))
      case .messageSend:
        let input = try request.decodeParameters(MessageSendInput.self)
        return try response(request, try await sendMessage(input))
      case .runInterrupt:
        let input = try request.decodeParameters(RunControlInput.self)
        try await requireThread(input.threadID)
        try await dataSource.interrupt(threadID: input.threadID, runID: input.runID)
        return try response(request, AcceptedOutput(accepted: true))
      case .runStop:
        let input = try request.decodeParameters(RunControlInput.self)
        try await requireThread(input.threadID)
        try await dataSource.stop(threadID: input.threadID, runID: input.runID)
        return try response(request, AcceptedOutput(accepted: true))
      case .approvalGet:
        let input = try request.decodeParameters(ApprovalGetInput.self)
        try await requireThread(input.threadID)
        return try response(
          request,
          ApprovalGetOutput(request: try await dataSource.pendingApproval(threadID: input.threadID))
        )
      case .approvalRespond:
        let input = try request.decodeParameters(ApprovalRespondInput.self)
        try await requireThread(input.threadID)
        guard !input.nonce.isEmpty else { throw OttoHostError.approvalUnavailable }
        try await dataSource.respondToApproval(input)
        return try response(
          request,
          ApprovalRespondOutput(
            accepted: true,
            requestID: input.requestID,
            decision: input.decision
          )
        )
      case .attachmentList:
        let input = try request.decodeParameters(AttachmentListInput.self)
        try await requireThread(input.threadID)
        return try response(
          request,
          AttachmentListOutput(
            attachments: try await dataSource.listAttachments(threadID: input.threadID)
          )
        )
      case .attachmentPrepareUpload:
        let input = try request.decodeParameters(AttachmentPrepareUploadInput.self)
        try await requireThread(input.threadID)
        return try response(request, try await dataSource.prepareAttachmentUpload(input))
      case .attachmentUploadChunk:
        let input = try request.decodeParameters(AttachmentUploadChunkInput.self)
        try await requireThread(input.threadID)
        return try response(request, try await dataSource.uploadAttachmentChunk(input))
      case .attachmentDownloadChunk:
        let input = try request.decodeParameters(AttachmentDownloadChunkInput.self)
        try await requireThread(input.threadID)
        return try response(request, try await dataSource.downloadAttachmentChunk(input))
      case .diagnosticsGet:
        return try response(request, try await dataSource.diagnostics())
      }
    } catch {
      return failure(request, error: error)
    }
  }

  @discardableResult
  public func publish(_ draft: RunEventDraft) async throws -> RunEvent {
    try await requireThread(draft.threadID)
    return try await journal.append(draft)
  }

  public func subscribe(threadID: UUID, afterSequence: Int64) async throws
    -> AsyncStream<RunEvent>
  {
    try await requireThread(threadID)
    return try await journal.stream(threadID: threadID, afterSequence: afterSequence)
  }

  private func sendMessage(_ input: MessageSendInput) async throws -> MessageSendOutput {
    try await requireThread(input.threadID)
    let body = input.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty, body.count <= 100_000 else { throw OttoHostError.invalidMessage }
    let normalized = MessageSendInput(
      threadID: input.threadID, clientMessageID: input.clientMessageID, body: body)
    if let pending = submissions[input.clientMessageID] {
      guard pending.input.threadID == normalized.threadID, pending.input.body == normalized.body
      else {
        throw OttoHostError.commandConflict
      }
      return try await pending.task.value
    }
    let task = Task { try await self.dispatchMessage(normalized) }
    submissions[input.clientMessageID] = (normalized, task)
    defer { submissions[input.clientMessageID] = nil }
    return try await task.value
  }

  private func dispatchMessage(_ input: MessageSendInput) async throws -> MessageSendOutput {
    if let receipt = try await journal.reserveCommand(input) {
      return MessageSendOutput(accepted: true, event: receipt, duplicate: true)
    }
    let body = input.body
    var message = try await dataSource.sendMessage(threadID: input.threadID, body: body)
    message.clientMessageID = input.clientMessageID
    let event = try await journal.append(
      RunEventDraft(
        threadID: input.threadID,
        kind: .messageAdded,
        author: message.author,
        correlationID: input.clientMessageID,
        content: RunEventContent(message: message)
      ))
    return MessageSendOutput(accepted: true, event: event, duplicate: false)
  }

  private func requireThread(_ id: UUID) async throws {
    guard try await dataSource.listThreads().contains(where: { $0.id == id }) else {
      throw OttoHostError.threadNotFound(id)
    }
  }

  private func response<Result: Encodable & Sendable>(
    _ request: OttoRPCRequest,
    _ result: Result
  ) throws -> OttoRPCResponse {
    try OttoRPCResponse(id: request.id, result: result)
  }

  private func failure(_ request: OttoRPCRequest, error: Error) -> OttoRPCResponse {
    let code: String
    switch error {
    case OttoHostError.unsupportedProtocol: code = "unsupported_protocol"
    case OttoHostError.forbidden: code = "forbidden"
    case OttoHostError.invalidCursor: code = "invalid_cursor"
    case OttoHostError.invalidLimit: code = "invalid_limit"
    case OttoHostError.invalidMessage: code = "invalid_message"
    case OttoHostError.staleRun: code = "stale_run"
    case OttoHostError.commandConflict: code = "command_conflict"
    case OttoHostError.commandUncertain: code = "command_uncertain"
    case OttoHostError.threadNotFound: code = "thread_not_found"
    case OttoHostError.approvalUnavailable: code = "approval_unavailable"
    case OttoHostError.invalidAttachment: code = "invalid_attachment"
    case OttoHostError.attachmentTransferUnavailable: code = "attachment_transfer_unavailable"
    case OttoHostError.diagnosticsUnavailable: code = "diagnostics_unavailable"
    case OttoHostError.journal: code = "journal_error"
    case OttoRPCContractError.missingParameters: code = "missing_parameters"
    case OttoRPCContractError.missingResult, OttoRPCContractError.encoding,
      OttoRPCContractError.remote:
      code = "invalid_contract"
    default: code = "host_error"
    }
    return OttoRPCResponse(
      id: request.id,
      error: OttoRPCFailure(code: code, message: error.localizedDescription)
    )
  }
}

import Foundation
import OttoModels

public enum OttoRPCProtocol {
  public static let currentVersion = 1
  public static let supportedVersions = 1...1
}

public enum OttoRPCMethod: String, Codable, CaseIterable, Sendable {
  case environmentGetCapabilities = "environment.getCapabilities"
  case threadList = "thread.list"
  case botList = "bot.list"
  case threadStart = "thread.start"
  case deviceRegisterPush = "device.registerPush"
  case threadGetSnapshot = "thread.getSnapshot"
  case threadEvents = "thread.events"
  case threadSubscribe = "thread.subscribe"
  case messageSend = "message.send"
  case runInterrupt = "run.interrupt"
  case runStop = "run.stop"
  case approvalGet = "approval.get"
  case approvalRespond = "approval.respond"
  case attachmentList = "attachment.list"
  case attachmentPrepareUpload = "attachment.prepareUpload"
  case attachmentUploadChunk = "attachment.uploadChunk"
  case attachmentDownloadChunk = "attachment.downloadChunk"
  case diagnosticsGet = "diagnostics.get"
}

public enum OttoRPCScope: String, Codable, CaseIterable, Hashable, Sendable {
  case environmentRead = "environment:read"
  case threadRead = "thread:read"
  case messageWrite = "message:write"
  case runControl = "run:control"
  case approvalRespond = "approval:respond"
  case secureLogin = "secure-login:control"
}

extension OttoRPCMethod {
  public var requiredScope: OttoRPCScope {
    switch self {
    case .environmentGetCapabilities, .deviceRegisterPush, .diagnosticsGet: .environmentRead
    case .botList, .threadList, .threadGetSnapshot, .threadEvents, .threadSubscribe,
      .attachmentList, .attachmentDownloadChunk:
      .threadRead
    case .threadStart, .messageSend, .attachmentPrepareUpload, .attachmentUploadChunk:
      .messageWrite
    case .runInterrupt, .runStop: .runControl
    case .approvalGet, .approvalRespond: .approvalRespond
    }
  }
}

public struct OttoRPCRequest: Codable, Equatable, Sendable {
  public var id: UUID
  public var protocolVersion: Int
  public var method: OttoRPCMethod
  public var parameters: OpaqueCodableValue?

  public init(
    id: UUID = UUID(),
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    method: OttoRPCMethod,
    parameters: OpaqueCodableValue? = nil
  ) {
    self.id = id
    self.protocolVersion = protocolVersion
    self.method = method
    self.parameters = parameters
  }

  public init<Parameters: Encodable & Sendable>(
    id: UUID = UUID(),
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    method: OttoRPCMethod,
    parameters: Parameters
  ) throws {
    self.id = id
    self.protocolVersion = protocolVersion
    self.method = method
    self.parameters = try OttoRPCCodec.value(parameters)
  }

  public func decodeParameters<Parameters: Decodable>(_: Parameters.Type) throws -> Parameters {
    guard let parameters else {
      throw OttoRPCContractError.missingParameters
    }
    return try OttoRPCCodec.decode(Parameters.self, from: parameters)
  }
}

public struct OttoRPCFailure: Codable, Equatable, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct OttoRPCResponse: Codable, Equatable, Sendable {
  public var id: UUID
  public var protocolVersion: Int
  public var result: OpaqueCodableValue?
  public var error: OttoRPCFailure?

  public init(
    id: UUID,
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    result: OpaqueCodableValue? = nil,
    error: OttoRPCFailure? = nil
  ) {
    self.id = id
    self.protocolVersion = protocolVersion
    self.result = result
    self.error = error
  }

  public init<Result: Encodable & Sendable>(
    id: UUID,
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    result: Result
  ) throws {
    self.id = id
    self.protocolVersion = protocolVersion
    self.result = try OttoRPCCodec.value(result)
    self.error = nil
  }

  public func decodeResult<Result: Decodable>(_: Result.Type) throws -> Result {
    if let error { throw OttoRPCContractError.remote(error) }
    guard let result else { throw OttoRPCContractError.missingResult }
    return try OttoRPCCodec.decode(Result.self, from: result)
  }
}

public enum OttoRPCContractError: Error, LocalizedError, Equatable, Sendable {
  case missingParameters
  case missingResult
  case encoding(String)
  case remote(OttoRPCFailure)

  public var errorDescription: String? {
    switch self {
    case .missingParameters: "The RPC request has no parameters."
    case .missingResult: "The RPC response has no result."
    case .encoding(let message): "The RPC payload is invalid: \(message)"
    case .remote(let failure): failure.message
    }
  }
}

public enum OttoRPCCodec {
  public static func value<Value: Encodable>(_ value: Value) throws -> OpaqueCodableValue {
    do {
      return try decoder.decode(OpaqueCodableValue.self, from: encoder.encode(value))
    } catch {
      throw OttoRPCContractError.encoding(error.localizedDescription)
    }
  }

  public static func decode<Value: Decodable>(
    _ type: Value.Type,
    from value: OpaqueCodableValue
  ) throws -> Value {
    do {
      return try decoder.decode(type, from: encoder.encode(value))
    } catch {
      throw OttoRPCContractError.encoding(error.localizedDescription)
    }
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

public struct EmptyParameters: Codable, Equatable, Sendable {
  public init() {}
}

public struct EnvironmentCapabilitiesOutput: Codable, Equatable, Sendable {
  public var environment: ExecutionEnvironment
  public var supportedProtocolVersions: [Int]

  public init(environment: ExecutionEnvironment, supportedProtocolVersions: [Int]) {
    self.environment = environment
    self.supportedProtocolVersions = supportedProtocolVersions
  }
}

public struct ThreadListOutput: Codable, Equatable, Sendable {
  public var threads: [OttoModels.Thread]

  public init(threads: [OttoModels.Thread]) { self.threads = threads }
}

public struct MobileRosterOutput: Codable, Equatable, Sendable {
  public var bots: [MobileBotSummary]
  public var teams: [MobileTeamSummary]

  public init(bots: [MobileBotSummary], teams: [MobileTeamSummary]) {
    self.bots = bots
    self.teams = teams
  }
}

public struct ThreadStartInput: Codable, Equatable, Sendable {
  public var botProfileID: UUID
  public var initialMessage: String?

  public init(botProfileID: UUID, initialMessage: String? = nil) {
    self.botProfileID = botProfileID
    self.initialMessage = initialMessage
  }
}

public struct ThreadStartOutput: Codable, Equatable, Sendable {
  public var thread: OttoModels.Thread
  public var openedExisting: Bool

  public init(thread: OttoModels.Thread, openedExisting: Bool) {
    self.thread = thread
    self.openedExisting = openedExisting
  }
}

public enum OttoPushEnvironment: String, Codable, CaseIterable, Sendable {
  case sandbox
  case production
}

public struct DeviceRegisterPushInput: Codable, Equatable, Sendable {
  public var token: String
  public var environment: OttoPushEnvironment

  public init(token: String, environment: OttoPushEnvironment) {
    self.token = token
    self.environment = environment
  }
}

public struct ThreadReferenceInput: Codable, Equatable, Sendable {
  public var threadID: UUID

  public init(threadID: UUID) { self.threadID = threadID }
}

public struct ThreadSnapshot: Codable, Equatable, Sendable {
  public var thread: OttoModels.Thread
  public var activeRunID: UUID?
  public var messages: [ThreadMessage]
  public var lastEventSequence: Int64

  public init(
    thread: OttoModels.Thread,
    messages: [ThreadMessage],
    lastEventSequence: Int64,
    activeRunID: UUID? = nil
  ) {
    self.activeRunID = activeRunID
    self.thread = thread
    self.messages = messages
    self.lastEventSequence = lastEventSequence
  }
}

public struct ThreadEventCursorInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var afterSequence: Int64
  public var limit: Int

  public init(threadID: UUID, afterSequence: Int64 = 0, limit: Int = 200) {
    self.threadID = threadID
    self.afterSequence = afterSequence
    self.limit = limit
  }
}

public struct ThreadEventPage: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var events: [RunEvent]
  public var latestSequence: Int64
  public var hasMore: Bool

  public init(
    threadID: UUID,
    events: [RunEvent],
    latestSequence: Int64,
    hasMore: Bool
  ) {
    self.threadID = threadID
    self.events = events
    self.latestSequence = latestSequence
    self.hasMore = hasMore
  }
}

public struct MessageSendInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var clientMessageID: UUID
  public var body: String

  public init(threadID: UUID, clientMessageID: UUID, body: String) {
    self.threadID = threadID
    self.clientMessageID = clientMessageID
    self.body = body
  }
}

public struct MessageSendOutput: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var event: RunEvent
  public var duplicate: Bool

  public init(accepted: Bool, event: RunEvent, duplicate: Bool) {
    self.accepted = accepted
    self.event = event
    self.duplicate = duplicate
  }
}

public struct RunControlInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var runID: UUID

  public init(threadID: UUID, runID: UUID) {
    self.threadID = threadID
    self.runID = runID
  }
}

public struct ApprovalGetInput: Codable, Equatable, Sendable {
  public var threadID: UUID

  public init(threadID: UUID) { self.threadID = threadID }
}

public struct ApprovalGetOutput: Codable, Equatable, Sendable {
  public var request: MobileApprovalRequest?

  public init(request: MobileApprovalRequest?) { self.request = request }
}

public struct ApprovalRespondInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var requestID: UUID
  public var nonce: String
  public var decision: MobileApprovalDecision

  public init(
    threadID: UUID,
    requestID: UUID,
    nonce: String,
    decision: MobileApprovalDecision
  ) {
    self.threadID = threadID
    self.requestID = requestID
    self.nonce = nonce
    self.decision = decision
  }
}

public struct ApprovalRespondOutput: Codable, Equatable, Sendable {
  public var accepted: Bool
  public var requestID: UUID
  public var decision: MobileApprovalDecision

  public init(accepted: Bool, requestID: UUID, decision: MobileApprovalDecision) {
    self.accepted = accepted
    self.requestID = requestID
    self.decision = decision
  }
}

public struct AttachmentListInput: Codable, Equatable, Sendable {
  public var threadID: UUID

  public init(threadID: UUID) { self.threadID = threadID }
}

public struct AttachmentListOutput: Codable, Equatable, Sendable {
  public var attachments: [OttoAttachment]

  public init(attachments: [OttoAttachment]) { self.attachments = attachments }
}

public struct AttachmentPrepareUploadInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var displayName: String
  public var mimeType: String
  public var byteCount: Int64
  public var sha256: String

  public init(
    threadID: UUID,
    displayName: String,
    mimeType: String,
    byteCount: Int64,
    sha256: String
  ) {
    self.threadID = threadID
    self.displayName = displayName
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct AttachmentPrepareUploadOutput: Codable, Equatable, Sendable {
  public var uploadID: UUID
  public var chunkSize: Int
  public var expiresAt: Date

  public init(uploadID: UUID, chunkSize: Int, expiresAt: Date) {
    self.uploadID = uploadID
    self.chunkSize = chunkSize
    self.expiresAt = expiresAt
  }
}

public struct AttachmentUploadChunkInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var uploadID: UUID
  public var offset: Int64
  public var data: Data

  public init(threadID: UUID, uploadID: UUID, offset: Int64, data: Data) {
    self.threadID = threadID
    self.uploadID = uploadID
    self.offset = offset
    self.data = data
  }
}

public struct AttachmentUploadChunkOutput: Codable, Equatable, Sendable {
  public var receivedBytes: Int64
  public var complete: Bool
  public var attachment: OttoAttachment?

  public init(receivedBytes: Int64, complete: Bool, attachment: OttoAttachment? = nil) {
    self.receivedBytes = receivedBytes
    self.complete = complete
    self.attachment = attachment
  }
}

public struct AttachmentDownloadChunkInput: Codable, Equatable, Sendable {
  public var threadID: UUID
  public var attachmentID: UUID
  public var offset: Int64
  public var limit: Int

  public init(threadID: UUID, attachmentID: UUID, offset: Int64 = 0, limit: Int = 262_144) {
    self.threadID = threadID
    self.attachmentID = attachmentID
    self.offset = offset
    self.limit = limit
  }
}

public struct AttachmentDownloadChunkOutput: Codable, Equatable, Sendable {
  public var attachment: OttoAttachment
  public var offset: Int64
  public var data: Data
  public var hasMore: Bool
  /// Present on the final chunk so the client can verify the complete downloaded file.
  public var sha256: String?

  public init(
    attachment: OttoAttachment,
    offset: Int64,
    data: Data,
    hasMore: Bool,
    sha256: String? = nil
  ) {
    self.attachment = attachment
    self.offset = offset
    self.data = data
    self.hasMore = hasMore
    self.sha256 = sha256
  }
}

public enum MobileDiagnosticEventKind: String, Codable, CaseIterable, Sendable {
  case sessionStarted = "session.started"
  case sessionEnded = "session.ended"
  case previousSessionAbnormal = "session.previous_abnormal"
  case toolCall = "tool.call"
  case agentStateChanged = "agent.state_changed"
  case providerFailure = "provider.failure"
  case resultExtracted = "agent.result_extracted"
  case voiceStateChanged = "voice.state_changed"
  case notification = "notification.sent"
}

public enum MobileDiagnosticAgentState: String, Codable, CaseIterable, Sendable {
  case idle
  case launching
  case working
  case waitingForUser = "waiting_for_user"
  case blocked
  case failed
  case done
  case stopped
}

public struct MobileDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var kind: MobileDiagnosticEventKind
  public var toolName: String?
  public var provider: AgentProvider?
  public var agentState: MobileDiagnosticAgentState?
  public var targetOrdinal: Int?
  public var durationMilliseconds: Double?
  public var succeeded: Bool?
  public var exitCode: Int32?

  public init(
    id: UUID = UUID(),
    timestamp: Date = .now,
    kind: MobileDiagnosticEventKind,
    toolName: String? = nil,
    provider: AgentProvider? = nil,
    agentState: MobileDiagnosticAgentState? = nil,
    targetOrdinal: Int? = nil,
    durationMilliseconds: Double? = nil,
    succeeded: Bool? = nil,
    exitCode: Int32? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.toolName = toolName
    self.provider = provider
    self.agentState = agentState
    self.targetOrdinal = targetOrdinal
    self.durationMilliseconds = durationMilliseconds
    self.succeeded = succeeded
    self.exitCode = exitCode
  }
}

public struct MobileDiagnosticsOutput: Codable, Equatable, Sendable {
  public static let maximumRecentEvents = 50

  public var generatedAt: Date
  public var appVersion: String
  public var operatingSystemVersion: String
  public var previousSessionAbnormal: Bool
  public var eventCounts: [String: Int]
  public var toolSuccessCount: Int
  public var toolFailureCount: Int
  public var toolLatencyMedianMilliseconds: Double?
  public var providerFailureCount: Int
  public var recentEvents: [MobileDiagnosticEvent]

  public init(
    generatedAt: Date = .now,
    appVersion: String,
    operatingSystemVersion: String,
    previousSessionAbnormal: Bool,
    eventCounts: [String: Int],
    toolSuccessCount: Int,
    toolFailureCount: Int,
    toolLatencyMedianMilliseconds: Double?,
    providerFailureCount: Int,
    recentEvents: [MobileDiagnosticEvent]
  ) {
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.operatingSystemVersion = operatingSystemVersion
    self.previousSessionAbnormal = previousSessionAbnormal
    self.eventCounts = eventCounts
    self.toolSuccessCount = toolSuccessCount
    self.toolFailureCount = toolFailureCount
    self.toolLatencyMedianMilliseconds = toolLatencyMedianMilliseconds
    self.providerFailureCount = providerFailureCount
    self.recentEvents = Array(recentEvents.suffix(Self.maximumRecentEvents))
  }

  public var isPrivacySafe: Bool {
    let safeVersion =
      !appVersion.isEmpty && appVersion.count <= 32
      && appVersion.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    let safeOS =
      !operatingSystemVersion.isEmpty && operatingSystemVersion.count <= 32
      && operatingSystemVersion.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" }
    let allowedKinds = Set(MobileDiagnosticEventKind.allCases.map(\.rawValue))
    let safeCounts =
      eventCounts.count <= allowedKinds.count
      && eventCounts.allSatisfy {
        allowedKinds.contains($0.key) && (0...1_000_000).contains($0.value)
      }
    let aggregateCounts = [toolSuccessCount, toolFailureCount, providerFailureCount]
      .allSatisfy { (0...1_000_000).contains($0) }
    let safeLatency = toolLatencyMedianMilliseconds.map { $0.isFinite && $0 >= 0 } ?? true
    let safeEvents =
      recentEvents.count <= Self.maximumRecentEvents
      && recentEvents.allSatisfy {
        let safeTool =
          $0.toolName.map { name in
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._")
            return name.count <= 64 && name.unicodeScalars.allSatisfy(allowed.contains)
          } ?? true
        let safeOrdinal = $0.targetOrdinal.map { $0 > 0 } ?? true
        let safeDuration = $0.durationMilliseconds.map { $0.isFinite && $0 >= 0 } ?? true
        return safeTool && safeOrdinal && safeDuration
      }
    return safeVersion && safeOS && safeCounts && aggregateCounts && safeLatency && safeEvents
  }

  /// Aggregate-only payload used for explicit support export. Recent event rows are local UI data.
  public var supportExport: MobileDiagnosticsSupportReport {
    MobileDiagnosticsSupportReport(
      generatedAt: generatedAt,
      appVersion: appVersion,
      operatingSystemVersion: operatingSystemVersion,
      previousSessionAbnormal: previousSessionAbnormal,
      eventCounts: eventCounts,
      toolSuccessCount: toolSuccessCount,
      toolFailureCount: toolFailureCount,
      toolLatencyMedianMilliseconds: toolLatencyMedianMilliseconds,
      providerFailureCount: providerFailureCount
    )
  }
}

/// The explicit-consent support artifact has no field capable of carrying local event rows.
public struct MobileDiagnosticsSupportReport: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var appVersion: String
  public var operatingSystemVersion: String
  public var previousSessionAbnormal: Bool
  public var eventCounts: [String: Int]
  public var toolSuccessCount: Int
  public var toolFailureCount: Int
  public var toolLatencyMedianMilliseconds: Double?
  public var providerFailureCount: Int

  public init(
    generatedAt: Date,
    appVersion: String,
    operatingSystemVersion: String,
    previousSessionAbnormal: Bool,
    eventCounts: [String: Int],
    toolSuccessCount: Int,
    toolFailureCount: Int,
    toolLatencyMedianMilliseconds: Double?,
    providerFailureCount: Int
  ) {
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.operatingSystemVersion = operatingSystemVersion
    self.previousSessionAbnormal = previousSessionAbnormal
    self.eventCounts = eventCounts
    self.toolSuccessCount = toolSuccessCount
    self.toolFailureCount = toolFailureCount
    self.toolLatencyMedianMilliseconds = toolLatencyMedianMilliseconds
    self.providerFailureCount = providerFailureCount
  }
}

public struct AcceptedOutput: Codable, Equatable, Sendable {
  public var accepted: Bool

  public init(accepted: Bool) { self.accepted = accepted }
}

public enum OttoMobilePairingContractError: Error, LocalizedError, Equatable, Sendable {
  case invalidPayload

  public var errorDescription: String? {
    switch self {
    case .invalidPayload: "That Otto pairing code is invalid. Ask the Mac to create a new one."
    }
  }
}

/// The short-lived payload rendered as a QR code by the Mac. It contains no durable credential;
/// the single-use offer code can only be exchanged before `expiresAt`.
public struct OttoMobilePairingPayload: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var offerID: UUID
  public var environmentID: UUID
  public var environmentName: String
  public var fingerprint: String
  public var baseURL: URL
  public var code: String
  public var expiresAt: Date
  public var scopes: Set<OttoRPCScope>

  public init(
    protocolVersion: Int = OttoRPCProtocol.currentVersion,
    offerID: UUID,
    environmentID: UUID,
    environmentName: String,
    fingerprint: String,
    baseURL: URL,
    code: String,
    expiresAt: Date,
    scopes: Set<OttoRPCScope>
  ) {
    self.protocolVersion = protocolVersion
    self.offerID = offerID
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.fingerprint = fingerprint
    self.baseURL = baseURL
    self.code = code
    self.expiresAt = expiresAt
    self.scopes = scopes
  }

  public func qrString() throws -> String {
    let data = try OttoRPCCodec.encoder.encode(self)
    let payload = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var components = URLComponents()
    components.scheme = OttoNames.urlScheme
    components.host = "pair"
    components.queryItems = [URLQueryItem(name: "payload", value: payload)]
    guard let value = components.string else {
      throw OttoMobilePairingContractError.invalidPayload
    }
    return value
  }

  public init(qrString: String) throws {
    guard let components = URLComponents(string: qrString),
      OttoNames.isAppURLScheme(components.scheme),
      components.host == "pair",
      let encoded = components.queryItems?.first(where: { $0.name == "payload" })?.value
    else { throw OttoMobilePairingContractError.invalidPayload }
    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    guard let data = Data(base64Encoded: base64),
      let decoded = try? OttoRPCCodec.decoder.decode(Self.self, from: data),
      OttoRPCProtocol.supportedVersions.contains(decoded.protocolVersion),
      ["https", "http"].contains(decoded.baseURL.scheme?.lowercased()),
      !decoded.code.isEmpty,
      !decoded.fingerprint.isEmpty
    else { throw OttoMobilePairingContractError.invalidPayload }
    self = decoded
  }
}

public struct OttoMobilePairingExchangeInput: Codable, Equatable, Sendable {
  public var offerID: UUID
  public var code: String
  public var deviceName: String
  public var devicePublicKey: String

  public init(offerID: UUID, code: String, deviceName: String, devicePublicKey: String) {
    self.offerID = offerID
    self.code = code
    self.deviceName = deviceName
    self.devicePublicKey = devicePublicKey
  }
}

public struct OttoMobilePairingExchangeOutput: Codable, Equatable, Sendable {
  public var deviceID: UUID
  public var credential: String
  public var environmentID: UUID
  public var environmentName: String
  public var baseURL: URL
  public var fingerprint: String
  public var scopes: Set<OttoRPCScope>

  public init(
    deviceID: UUID,
    credential: String,
    environmentID: UUID,
    environmentName: String,
    baseURL: URL,
    fingerprint: String,
    scopes: Set<OttoRPCScope>
  ) {
    self.deviceID = deviceID
    self.credential = credential
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.baseURL = baseURL
    self.fingerprint = fingerprint
    self.scopes = scopes
  }
}

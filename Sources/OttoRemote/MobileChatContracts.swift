import Foundation
import OttoModels

public enum MobileChatProtocol {
  public static let version = 1
}

public enum MobileChatCodec {
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode(type, from: data)
  }
}

public enum MobileChatMethod: String, Codable, CaseIterable, Sendable {
  case capabilities = "environment.getCapabilities"
  case botList = "bot.list"
  case teamList = "team.list"
  case activityList = "activity.list"
  case activitySubscribe = "activity.subscribe"
  case threadList = "thread.list"
  case threadSnapshot = "thread.getSnapshot"
  case threadSubscribe = "thread.subscribe"
  case threadCreate = "thread.create"
  case messageSend = "message.send"
  case runInterrupt = "run.interrupt"
  case runStop = "run.stop"
  case approvalRespond = "approval.respond"
  case attachmentPrepareUpload = "attachment.prepareUpload"
  case attachmentDownload = "attachment.download"
  case deviceList = "device.list"
  case deviceRevoke = "device.revoke"
  case computerAcquire = "computer.acquire"
  case computerInput = "computer.input"
  case computerHandBack = "computer.handBack"
}

public struct MobileEnvironmentCapabilities: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var environmentID: UUID
  public var environmentName: String
  public var hostOnline: Bool
  public var hostVersion: String
  public var capabilities: Set<String>

  public init(
    protocolVersion: Int = MobileChatProtocol.version, environmentID: UUID,
    environmentName: String, hostOnline: Bool, hostVersion: String,
    capabilities: Set<String>
  ) {
    self.protocolVersion = protocolVersion
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.hostOnline = hostOnline
    self.hostVersion = hostVersion
    self.capabilities = capabilities
  }
}

public struct MobileBotSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var jobTitle: String?
  public var avatar: BotShareAppearance?
  public var state: BotAvatarState
  public var channelID: UUID?

  public init(
    id: UUID, name: String, jobTitle: String? = nil, avatar: BotShareAppearance? = nil,
    state: BotAvatarState, channelID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.jobTitle = jobTitle
    self.avatar = avatar
    self.state = state
    self.channelID = channelID
  }
}

public struct MobileTeamSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var memberProfileIDs: [UUID]
  public var orchestratorProfileID: UUID?
  public var state: BotActivityState?

  public init(
    id: UUID, name: String, memberProfileIDs: [UUID],
    orchestratorProfileID: UUID? = nil, state: BotActivityState? = nil
  ) {
    self.id = id
    self.name = name
    self.memberProfileIDs = memberProfileIDs
    self.orchestratorProfileID = orchestratorProfileID
    self.state = state
  }
}

public enum MobileThreadKind: String, Codable, Sendable {
  case bot
  case team
}

public struct MobileThreadSummary: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var kind: MobileThreadKind
  public var title: String
  public var profileID: UUID?
  public var memberProfileIDs: [UUID]
  public var updatedAt: Date
  public var needsUser: Bool

  public init(
    id: UUID, kind: MobileThreadKind, title: String, profileID: UUID? = nil,
    memberProfileIDs: [UUID] = [], updatedAt: Date = .now, needsUser: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.profileID = profileID
    self.memberProfileIDs = memberProfileIDs
    self.updatedAt = updatedAt
    self.needsUser = needsUser
  }
}

public enum MobileMessageAuthor: Codable, Equatable, Sendable {
  case user
  case bot(profileID: UUID, name: String)
  case system
}

public struct MobileMessage: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var clientMessageID: String?
  public var author: MobileMessageAuthor
  public var body: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), clientMessageID: String? = nil, author: MobileMessageAuthor,
    body: String, createdAt: Date = .now
  ) {
    self.id = id
    self.clientMessageID = clientMessageID
    self.author = author
    self.body = body
    self.createdAt = createdAt
  }
}

public struct MobileThreadSnapshot: Codable, Equatable, Sendable {
  public var thread: MobileThreadSummary
  public var messages: [MobileMessage]
  public var latestSequence: Int64

  public init(thread: MobileThreadSummary, messages: [MobileMessage], latestSequence: Int64) {
    self.thread = thread
    self.messages = messages
    self.latestSequence = latestSequence
  }
}

public struct MobileHomeSnapshot: Codable, Equatable, Sendable {
  public var capabilities: MobileEnvironmentCapabilities
  public var bots: [MobileBotSummary]
  public var teams: [MobileTeamSummary]
  public var threads: [MobileThreadSummary]
  public var activity: [BotActivityItem]
  public var latestSequence: Int64

  public init(
    capabilities: MobileEnvironmentCapabilities, bots: [MobileBotSummary],
    teams: [MobileTeamSummary], threads: [MobileThreadSummary],
    activity: [BotActivityItem], latestSequence: Int64
  ) {
    self.capabilities = capabilities
    self.bots = bots
    self.teams = teams
    self.threads = threads
    self.activity = activity
    self.latestSequence = latestSequence
  }
}

public enum MobileHostEventType: String, Codable, CaseIterable, Sendable {
  case homeChanged = "home.changed"
  case threadMessage = "thread.message"
  case threadState = "thread.state"
  case activityChanged = "activity.changed"
  case approvalRequested = "approval.requested"
  case computerControlChanged = "computer.changed"
}

public struct MobileHostEvent: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var sequence: Int64
  public var timestamp: Date
  public var type: MobileHostEventType
  public var schemaVersion: Int
  public var threadID: UUID?
  public var profileID: UUID?
  public var correlationID: UUID?
  public var causationID: UUID?
  public var payload: Data?

  public init(
    id: UUID = UUID(), sequence: Int64 = 0, timestamp: Date = .now,
    type: MobileHostEventType, schemaVersion: Int = 1, threadID: UUID? = nil,
    profileID: UUID? = nil, correlationID: UUID? = nil, causationID: UUID? = nil,
    payload: Data? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.timestamp = timestamp
    self.type = type
    self.schemaVersion = schemaVersion
    self.threadID = threadID
    self.profileID = profileID
    self.correlationID = correlationID
    self.causationID = causationID
    self.payload = payload
  }
}

public struct MobileEventPage: Codable, Equatable, Sendable {
  public var events: [MobileHostEvent]
  public var latestSequence: Int64

  public init(events: [MobileHostEvent], latestSequence: Int64) {
    self.events = events
    self.latestSequence = latestSequence
  }
}

public struct MobileQueuedMessage: Codable, Equatable, Sendable, Identifiable {
  public var id: String { clientMessageID }
  public var threadID: UUID
  public var clientMessageID: String
  public var body: String
  public var createdAt: Date

  public init(threadID: UUID, clientMessageID: String, body: String, createdAt: Date = .now) {
    self.threadID = threadID
    self.clientMessageID = clientMessageID
    self.body = body
    self.createdAt = createdAt
  }
}

public struct MobileApprovalResponse: Codable, Equatable, Sendable {
  public var requestID: UUID
  public var decision: String
  public var nonce: String

  public init(requestID: UUID, decision: String, nonce: String) {
    self.requestID = requestID
    self.decision = decision
    self.nonce = nonce
  }
}

public enum MobileOfflinePolicyError: Error, LocalizedError, Equatable, Sendable {
  case approvalRequiresOnlineHost
  case duplicateClientMessage

  public var errorDescription: String? {
    switch self {
    case .approvalRequiresOnlineHost:
      "Approvals are never queued offline. Reconnect to review the current request."
    case .duplicateClientMessage: "That client message has already been queued."
    }
  }
}

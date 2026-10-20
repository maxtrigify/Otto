import Foundation

public enum EnvironmentKind: String, Codable, CaseIterable, Sendable {
  case macHost = "mac_host"
  case cloudHost = "cloud_host"
}

public enum EnvironmentStatus: String, Codable, CaseIterable, Sendable {
  case online
  case degraded
  case offline
}

public enum EnvironmentCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case conversations
  case files
  case canvas
  case browser
  case shell
  case approvals
  case attachments
  case notifications
  case diagnostics
}

/// A place where Otto owns execution. Phase 0 creates only `.macHost` environments; the model is
/// shared so adding a cloud host later does not turn a bot or provider session into a mode flag.
public struct ExecutionEnvironment: Identifiable, Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var id: UUID
  public var name: String
  public var kind: EnvironmentKind
  public var status: EnvironmentStatus
  public var capabilities: Set<EnvironmentCapability>
  public var protocolVersion: Int
  public var hostVersion: String?
  public var lastSeenAt: Date?
  public var schemaVersion: Int

  public init(
    id: UUID,
    name: String,
    kind: EnvironmentKind,
    status: EnvironmentStatus,
    capabilities: Set<EnvironmentCapability>,
    protocolVersion: Int,
    hostVersion: String? = nil,
    lastSeenAt: Date? = nil,
    schemaVersion: Int = ExecutionEnvironment.currentSchemaVersion
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.status = status
    self.capabilities = capabilities
    self.protocolVersion = protocolVersion
    self.hostVersion = hostVersion
    self.lastSeenAt = lastSeenAt
    self.schemaVersion = schemaVersion
  }
}

public enum ThreadKind: String, Codable, CaseIterable, Sendable {
  case task
  case botChannel = "bot_channel"
  case group
}

public enum ThreadState: String, Codable, CaseIterable, Sendable {
  case idle
  case working
  case waitingForUser = "waiting_for_user"
  case approvalRequired = "approval_required"
  case failed
  case done
  case stopped
  case hostOffline = "host_offline"
}

public struct MobileBotSummary: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var jobTitle: String?
  public var role: String
  public var provider: AgentProvider
  public var hasSession: Bool
  public var updatedAt: Date

  public init(
    id: UUID,
    name: String,
    jobTitle: String? = nil,
    role: String = "",
    provider: AgentProvider,
    hasSession: Bool,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.jobTitle = jobTitle
    self.role = role
    self.provider = provider
    self.hasSession = hasSession
    self.updatedAt = updatedAt
  }
}

public struct MobileTeamSummary: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var memberProfileIDs: [UUID]
  public var orchestratorProfileID: UUID?
  public var updatedAt: Date

  public init(
    id: UUID,
    name: String,
    memberProfileIDs: [UUID],
    orchestratorProfileID: UUID? = nil,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.memberProfileIDs = memberProfileIDs
    self.orchestratorProfileID = orchestratorProfileID
    self.updatedAt = updatedAt
  }
}

/// A mobile-facing reference to an existing Otto conversation. `id` is the existing
/// `BotChannel.conversationID` for bot channels; bot profiles, canvas nodes, and provider session
/// identifiers remain references rather than being copied into a new ownership model.
public struct Thread: Identifiable, Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var id: UUID
  public var kind: ThreadKind
  public var title: String
  public var botProfileIDs: [UUID]
  public var channelID: UUID?
  public var nodeID: UUID?
  public var executionEnvironmentID: UUID
  public var runtimeSessionID: String?
  public var state: ThreadState
  public var lastEventSequence: Int64
  public var createdAt: Date
  public var updatedAt: Date
  public var schemaVersion: Int

  public init(
    id: UUID,
    kind: ThreadKind,
    title: String,
    botProfileIDs: [UUID],
    channelID: UUID? = nil,
    nodeID: UUID? = nil,
    executionEnvironmentID: UUID,
    runtimeSessionID: String? = nil,
    state: ThreadState = .idle,
    lastEventSequence: Int64 = 0,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    schemaVersion: Int = Thread.currentSchemaVersion
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.botProfileIDs = botProfileIDs
    self.channelID = channelID
    self.nodeID = nodeID
    self.executionEnvironmentID = executionEnvironmentID
    self.runtimeSessionID = runtimeSessionID
    self.state = state
    self.lastEventSequence = lastEventSequence
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.schemaVersion = schemaVersion
  }
}

public enum ThreadMessageRole: String, Codable, CaseIterable, Sendable {
  case user
  case assistant
  case activity
  case system
}

public enum ThreadMessageKind: String, Codable, CaseIterable, Sendable {
  case text
  case reasoning
  case toolCall = "tool_call"
  case notice
}

public struct RunEventAuthor: Codable, Equatable, Sendable {
  public var role: ThreadMessageRole
  public var botProfileID: UUID?
  public var displayName: String?

  public init(
    role: ThreadMessageRole,
    botProfileID: UUID? = nil,
    displayName: String? = nil
  ) {
    self.role = role
    self.botProfileID = botProfileID
    self.displayName = displayName
  }
}

public struct ThreadMessage: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var role: ThreadMessageRole
  public var kind: ThreadMessageKind
  public var text: String
  public var detail: String?
  public var author: RunEventAuthor?
  public var clientMessageID: UUID?
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    role: ThreadMessageRole,
    kind: ThreadMessageKind = .text,
    text: String,
    detail: String? = nil,
    author: RunEventAuthor? = nil,
    clientMessageID: UUID? = nil,
    createdAt: Date = .now
  ) {
    self.id = id
    self.role = role
    self.kind = kind
    self.text = text
    self.detail = detail
    self.author = author
    self.clientMessageID = clientMessageID
    self.createdAt = createdAt
  }
}

public enum RunEventKind: String, Codable, CaseIterable, Sendable {
  case messageAdded = "message.added"
  case messageUpdated = "message.updated"
  case runStarted = "run.started"
  case runStateChanged = "run.state_changed"
  case runCompleted = "run.completed"
  case runFailed = "run.failed"
  case approvalRequested = "approval.requested"
  case questionAsked = "question.asked"
  case desktopRequired = "desktop.required"
  case threadStateChanged = "thread.state_changed"
}

/// Classification only; notification routing and APNs payload construction remain outside the
/// canonical event store. This lets the next slice add completion pushes without schema churn.
public enum RunEventNotification: String, Codable, CaseIterable, Sendable {
  case none
  case needsUser = "needs_user"
  case approval
  case failure
  case completion
}

public struct MobileApprovalRequest: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID { requestID }
  public var requestID: UUID
  public var threadID: UUID
  public var runID: UUID?
  public var reason: String
  public var nonce: String
  public var requestedAt: Date

  public init(
    requestID: UUID,
    threadID: UUID,
    runID: UUID? = nil,
    reason: String,
    nonce: String,
    requestedAt: Date = .now
  ) {
    self.requestID = requestID
    self.threadID = threadID
    self.runID = runID
    self.reason = reason
    self.nonce = nonce
    self.requestedAt = requestedAt
  }
}

public enum MobileApprovalDecision: String, Codable, CaseIterable, Sendable {
  case approveOnce = "approve_once"
  case deny
}

public struct RunEventContent: Codable, Equatable, Sendable {
  public var message: ThreadMessage?
  public var runID: UUID?
  public var state: ThreadState?
  public var detail: String?
  public var approval: MobileApprovalRequest?
  public var notification: RunEventNotification

  public init(
    message: ThreadMessage? = nil,
    runID: UUID? = nil,
    state: ThreadState? = nil,
    detail: String? = nil,
    notification: RunEventNotification = .none
  ) {
    self.message = message
    self.runID = runID
    self.state = state
    self.detail = detail
    self.approval = nil
    self.notification = notification
  }

  public init(
    message: ThreadMessage? = nil,
    runID: UUID? = nil,
    state: ThreadState? = nil,
    detail: String? = nil,
    approval: MobileApprovalRequest,
    notification: RunEventNotification = .none
  ) {
    self.message = message
    self.runID = runID
    self.state = state
    self.detail = detail
    self.approval = approval
    self.notification = notification
  }
}

/// Canonical, durable event used for snapshot catch-up and foreground streaming. Sequence numbers
/// are monotonic within one thread; stable IDs make application on the client idempotent.
public struct RunEvent: Identifiable, Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var id: UUID
  public var threadID: UUID
  public var sequence: Int64
  public var timestamp: Date
  public var kind: RunEventKind
  public var schemaVersion: Int
  public var author: RunEventAuthor?
  public var correlationID: UUID?
  public var causationID: UUID?
  public var content: RunEventContent

  public init(
    id: UUID = UUID(),
    threadID: UUID,
    sequence: Int64,
    timestamp: Date = .now,
    kind: RunEventKind,
    schemaVersion: Int = RunEvent.currentSchemaVersion,
    author: RunEventAuthor? = nil,
    correlationID: UUID? = nil,
    causationID: UUID? = nil,
    content: RunEventContent = RunEventContent()
  ) {
    self.id = id
    self.threadID = threadID
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.schemaVersion = schemaVersion
    self.author = author
    self.correlationID = correlationID
    self.causationID = causationID
    self.content = content
  }
}

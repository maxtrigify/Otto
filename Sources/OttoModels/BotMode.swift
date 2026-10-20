import Foundation

// MARK: - Appearance (sidecar; cosmetic churn must not revise the profile)

/// Personality marks a bot may wear. Stored in `BotAppearance.avatarRef`.
public enum BotIconCatalog {
  public static let symbols = [
    "🦊", "🦉", "🐙", "🐝", "🐺", "🐱", "🐸", "🐧",
    "🍄", "🌙", "☄️", "⚡️", "🌸", "🎭", "🐉", "🪐",
  ]
}

/// The animated faces a bot can wear. A face is drawn, not an image, so it can react to the
/// bot's state: it blinks while idle, scans while working, and looks straight at you when it
/// needs an answer. Identifiers live in `BotAppearance.avatarRef` next to the emoji catalog,
/// and the `face.` prefix is what keeps the two apart.
public enum BotFaceCatalog {
  public struct Face: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }

  public static let all: [Face] = [
    Face(id: "face.pip", name: "Pip"),
    Face(id: "face.sol", name: "Sol"),
    Face(id: "face.mochi", name: "Mochi"),
    Face(id: "face.bit", name: "Bit"),
    Face(id: "face.nox", name: "Nox"),
    Face(id: "face.vex", name: "Vex"),
    Face(id: "face.echo", name: "Echo"),
    Face(id: "face.zip", name: "Zip"),
  ]

  public static func contains(_ reference: String?) -> Bool {
    guard let reference else { return false }
    return all.contains { $0.id == reference }
  }

  public static func name(for reference: String?) -> String? {
    guard let reference else { return nil }
    return all.first { $0.id == reference }?.name
  }
}

public struct BotAppearance: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { profileID }
  public var profileID: UUID
  public var avatarRef: String?
  public var petRef: String?
  /// Cosmetic shape token used by Chat/Bots UI: rounded, circle, diamond.
  public var shape: String?
  /// Hex color such as `#397b69`. Cosmetic; never revises the profile.
  public var colorHex: String?
  public var initials: String?
  /// Workspace-relative path under `.otto/bot-avatars/`. Never stored in the profile revision.
  public var photoRelativePath: String?
  public var updatedAt: Date

  public init(
    profileID: UUID,
    avatarRef: String? = nil,
    petRef: String? = nil,
    shape: String? = nil,
    colorHex: String? = nil,
    initials: String? = nil,
    photoRelativePath: String? = nil,
    updatedAt: Date = .now
  ) {
    self.profileID = profileID
    self.avatarRef = avatarRef
    self.petRef = petRef
    self.shape = shape
    self.colorHex = colorHex
    self.initials = initials
    self.photoRelativePath = photoRelativePath
    self.updatedAt = updatedAt
  }
}

// MARK: - Channels

public enum BotConversationKind: String, Codable, CaseIterable, Sendable {
  case task
  case botChannel
  case group
}

// MARK: - Durable bot message delivery

public enum BotMessageDeliveryState: String, Codable, CaseIterable, Sendable {
  case queued
  case dispatching
  case delivered
  case failed
  case expired
  case uncertain
}

public enum BotMessageTrust: String, Codable, Sendable {
  case userInitiated
  case peerUntrusted
}

public enum BotMessageReceiptSide: String, Codable, CaseIterable, Sendable {
  case sender
  case receiver
}

public struct BotMessageReceipt: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var side: BotMessageReceiptSide
  public var profileID: UUID
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    side: BotMessageReceiptSide,
    profileID: UUID,
    createdAt: Date = .now
  ) {
    self.id = id
    self.side = side
    self.profileID = profileID
    self.createdAt = createdAt
  }
}

public struct BotMessageDelivery: Codable, Equatable, Sendable, Identifiable {
  public static let maxHopCount = 4

  public var id: UUID
  public var idempotencyKey: String
  public var humanTurnID: UUID
  public var replyToDeliveryID: UUID?
  public var senderProfileID: UUID
  public var receiverProfileID: UUID
  public var channelID: UUID
  public var projectContext: ConversationProjectContext?
  public var body: String
  public var trust: BotMessageTrust
  public var hopCount: Int
  public var state: BotMessageDeliveryState
  public var receipts: [BotMessageReceipt]
  public var failureReason: String?
  public var createdAt: Date
  public var deliveredAt: Date?
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    idempotencyKey: String,
    humanTurnID: UUID,
    replyToDeliveryID: UUID? = nil,
    senderProfileID: UUID,
    receiverProfileID: UUID,
    channelID: UUID,
    body: String,
    projectContext: ConversationProjectContext? = nil,
    trust: BotMessageTrust,
    hopCount: Int = 0,
    state: BotMessageDeliveryState = .queued,
    receipts: [BotMessageReceipt] = [],
    failureReason: String? = nil,
    createdAt: Date = .now,
    deliveredAt: Date? = nil,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.humanTurnID = humanTurnID
    self.replyToDeliveryID = replyToDeliveryID
    self.senderProfileID = senderProfileID
    self.receiverProfileID = receiverProfileID
    self.channelID = channelID
    self.projectContext = projectContext
    self.body = body
    self.trust = trust
    self.hopCount = hopCount
    self.state = state
    self.receipts = receipts
    self.failureReason = failureReason
    self.createdAt = createdAt
    self.deliveredAt = deliveredAt
    self.updatedAt = updatedAt
  }
}

// MARK: - Consequential external effects

public enum ExternalEffectState: String, Codable, CaseIterable, Sendable {
  case intended
  case approved
  case executing
  case completed
  case denied
  case uncertain
}

public enum ExternalEffectRiskClass: String, Codable, CaseIterable, Sendable {
  case reversibleLocal
  case sendOrPublish
  case spend
  case delete
  case accountChange
}

public enum ExternalEffectApprovalDecision: String, Codable, Sendable {
  case notRequired
  case pending
  case approved
  case denied
}

public struct ExternalEffect: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var idempotencyKey: String
  public var action: String
  public var actorID: String
  public var canonicalRequestHash: String
  public var redactedArguments: [String: String]
  public var riskClass: ExternalEffectRiskClass
  public var approvalDecision: ExternalEffectApprovalDecision
  public var state: ExternalEffectState
  public var resultReference: String?
  public var verificationGuidance: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), idempotencyKey: String, action: String, actorID: String,
    canonicalRequestHash: String, redactedArguments: [String: String] = [:],
    riskClass: ExternalEffectRiskClass,
    approvalDecision: ExternalEffectApprovalDecision = .pending,
    state: ExternalEffectState = .intended, resultReference: String? = nil,
    verificationGuidance: String? = nil, createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.idempotencyKey = idempotencyKey
    self.action = action
    self.actorID = actorID
    self.canonicalRequestHash = canonicalRequestHash
    self.redactedArguments = redactedArguments
    self.riskClass = riskClass
    self.approvalDecision = approvalDecision
    self.state = state
    self.resultReference = resultReference
    self.verificationGuidance = verificationGuidance
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct ExternalEffectStandingRule: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var actorID: String?
  public var action: String?
  public var riskClass: ExternalEffectRiskClass
  public var createdAt: Date

  public init(
    id: UUID = UUID(), actorID: String? = nil, action: String? = nil,
    riskClass: ExternalEffectRiskClass, createdAt: Date = .now
  ) {
    self.id = id
    self.actorID = actorID
    self.action = action
    self.riskClass = riskClass
    self.createdAt = createdAt
  }
}

public struct BotChannel: Codable, Equatable, Sendable, Identifiable {
  public static let currentSchemaVersion = 1

  public var id: UUID
  public var profileID: UUID
  public var kind: BotConversationKind
  public var conversationID: UUID
  public var nodeID: UUID?
  public var memberProfileIDs: [UUID]
  /// Display name for a group. One-to-one bot channels leave this nil.
  public var name: String?
  /// How this team works: who leads, who reviews, when to @mention.
  public var instructions: String?
  /// The chief of staff. When the user sends without an @mention, this bot is addressed first.
  public var orchestratorProfileID: UUID?
  /// Team-wide permission mode (`AgentPermissionMode` raw value) applied to every member's team
  /// turns. Nil keeps each bot's own mode, which is how teams created before this setting behave.
  public var permissionMode: String?
  public var archived: Bool
  public var archivedAt: Date?
  public var archivedByProfileIDs: [UUID]?
  public var createdAt: Date
  public var updatedAt: Date
  public var revision: Int
  public var schemaVersion: Int

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    kind: BotConversationKind = .botChannel,
    conversationID: UUID = UUID(),
    nodeID: UUID? = nil,
    memberProfileIDs: [UUID] = [],
    name: String? = nil,
    instructions: String? = nil,
    orchestratorProfileID: UUID? = nil,
    permissionMode: String? = nil,
    archived: Bool = false,
    archivedAt: Date? = nil,
    archivedByProfileIDs: [UUID]? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    revision: Int = 1,
    schemaVersion: Int = BotChannel.currentSchemaVersion
  ) {
    self.id = id
    self.profileID = profileID
    self.kind = kind
    self.conversationID = conversationID
    self.nodeID = nodeID
    self.memberProfileIDs = memberProfileIDs
    self.name = name
    self.instructions = instructions
    self.orchestratorProfileID = orchestratorProfileID
    self.permissionMode = permissionMode
    self.archived = archived
    self.archivedAt = archivedAt
    self.archivedByProfileIDs = archivedByProfileIDs
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.revision = revision
    self.schemaVersion = schemaVersion
  }

  public func displayTitle(profileNames: [UUID: String]) -> String {
    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return name
    }
    let members = memberProfileIDs.compactMap { profileNames[$0] }
    if members.isEmpty { return "Team" }
    return members.joined(separator: " + ")
  }
}

// MARK: - Disposable bounded context projections

public struct BotContextMessage: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var speaker: String
  public var text: String
  public var createdAt: Date

  public init(id: UUID = UUID(), speaker: String, text: String, createdAt: Date = .now) {
    self.id = id
    self.speaker = speaker
    self.text = text
    self.createdAt = createdAt
  }
}

public struct BotOwnedWork: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var owner: String
  public var text: String

  public init(id: UUID = UUID(), owner: String, text: String) {
    self.id = id
    self.owner = owner
    self.text = text
  }
}

public struct BotChannelContextProjection: Codable, Equatable, Sendable, Identifiable {
  public static let currentVersion = 2
  public var id: UUID { channelID }
  public var channelID: UUID
  public var generationID: UUID
  public var generationStartedAt: Date
  public var sourceStartID: UUID?
  public var sourceEndID: UUID?
  public var estimatedTokenCount: Int
  public var decisions: [String]
  public var openWork: [BotOwnedWork]
  public var completedResults: [String]
  public var artifacts: [String]
  public var constraints: [String]
  public var risks: [String]
  public var recentMessages: [BotContextMessage]
  public var summary: String?
  public var summaryProvenance: [UUID]
  public var version: Int
  public var updatedAt: Date

  public init(
    channelID: UUID, generationID: UUID = UUID(), generationStartedAt: Date = .distantPast,
    sourceStartID: UUID? = nil,
    sourceEndID: UUID? = nil, estimatedTokenCount: Int = 0,
    decisions: [String] = [], openWork: [BotOwnedWork] = [],
    completedResults: [String] = [], artifacts: [String] = [], constraints: [String] = [],
    risks: [String] = [], recentMessages: [BotContextMessage] = [], summary: String? = nil,
    summaryProvenance: [UUID] = [], version: Int = BotChannelContextProjection.currentVersion,
    updatedAt: Date = .now
  ) {
    self.channelID = channelID
    self.generationID = generationID
    self.generationStartedAt = generationStartedAt
    self.sourceStartID = sourceStartID
    self.sourceEndID = sourceEndID
    self.estimatedTokenCount = estimatedTokenCount
    self.decisions = decisions
    self.openWork = openWork
    self.completedResults = completedResults
    self.artifacts = artifacts
    self.constraints = constraints
    self.risks = risks
    self.recentMessages = recentMessages
    self.summary = summary
    self.summaryProvenance = summaryProvenance
    self.version = version
    self.updatedAt = updatedAt
  }
}

// MARK: - Derived activity and discovery

public enum BotActivityState: String, Codable, CaseIterable, Sendable {
  case working
  case needsUser
  case completed
  case failed
  case cancelled
}

public enum BotActivityDeepLink: Codable, Equatable, Sendable {
  case bot(profileID: UUID, channelID: UUID?)
  case team(channelID: UUID)
  case agent(nodeID: UUID)
  case routine(routineID: UUID, runID: UUID?)
  case effect(effectID: UUID)
  case memory(recordID: String, profileID: UUID?)
}

public struct BotActivityItem: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var state: BotActivityState
  public var title: String
  public var detail: String?
  public var profileID: UUID?
  public var channelID: UUID?
  public var deepLink: BotActivityDeepLink
  public var sourceEventSequence: Int
  public var updatedAt: Date

  public init(
    id: String, state: BotActivityState, title: String, detail: String? = nil,
    profileID: UUID? = nil, channelID: UUID? = nil, deepLink: BotActivityDeepLink,
    sourceEventSequence: Int, updatedAt: Date = .now
  ) {
    self.id = id
    self.state = state
    self.title = title
    self.detail = detail
    self.profileID = profileID
    self.channelID = channelID
    self.deepLink = deepLink
    self.sourceEventSequence = sourceEventSequence
    self.updatedAt = updatedAt
  }
}

public struct BotActivityNotification: Codable, Equatable, Sendable, Identifiable {
  public var id: String { transitionKey }
  public var transitionKey: String
  public var activityID: String
  public var state: BotActivityState
  public var deepLink: BotActivityDeepLink
  public var createdAt: Date

  public init(
    transitionKey: String, activityID: String, state: BotActivityState,
    deepLink: BotActivityDeepLink, createdAt: Date = .now
  ) {
    self.transitionKey = transitionKey
    self.activityID = activityID
    self.state = state
    self.deepLink = deepLink
    self.createdAt = createdAt
  }
}

public enum BotSearchKind: String, Codable, CaseIterable, Sendable {
  case bot
  case room
  case message
  case artifact
  case routine
  case memory
}

public struct BotSearchResult: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var kind: BotSearchKind
  public var title: String
  public var excerpt: String
  public var deepLink: BotActivityDeepLink
  public var score: Double

  public init(
    id: String, kind: BotSearchKind, title: String, excerpt: String,
    deepLink: BotActivityDeepLink, score: Double
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.excerpt = excerpt
    self.deepLink = deepLink
    self.score = score
  }
}

// MARK: - Lease-bound computer takeover

public enum ComputerControlPhase: String, Codable, CaseIterable, Sendable {
  case requested
  case userControlling
  case resuming
  case completed
  case skipped
  case expired
}

public enum ComputerControlOwner: String, Codable, Sendable {
  case bot
  case user
}

public enum ComputerHandbackOutcome: String, Codable, Sendable {
  case done
  case skipped
  case expired
}

public struct ComputerControlState: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var runID: UUID
  public var profileID: UUID?
  public var pausedCheckpointID: String
  public var reason: String
  public var phase: ComputerControlPhase
  public var owner: ComputerControlOwner
  public var leaseID: UUID?
  public var leaseDeviceID: UUID?
  public var leaseExpiresAt: Date?
  public var handbackOutcome: ComputerHandbackOutcome?
  public var resumeToken: UUID?
  public var resumeClaimedAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), runID: UUID, profileID: UUID? = nil,
    pausedCheckpointID: String, reason: String, phase: ComputerControlPhase = .requested,
    owner: ComputerControlOwner = .bot, leaseID: UUID? = nil,
    leaseDeviceID: UUID? = nil, leaseExpiresAt: Date? = nil,
    handbackOutcome: ComputerHandbackOutcome? = nil, resumeToken: UUID? = nil,
    resumeClaimedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.runID = runID
    self.profileID = profileID
    self.pausedCheckpointID = pausedCheckpointID
    self.reason = reason
    self.phase = phase
    self.owner = owner
    self.leaseID = leaseID
    self.leaseDeviceID = leaseDeviceID
    self.leaseExpiresAt = leaseExpiresAt
    self.handbackOutcome = handbackOutcome
    self.resumeToken = resumeToken
    self.resumeClaimedAt = resumeClaimedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

// MARK: - Curated notes

public struct BotNote: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var profileID: UUID
  public var body: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    body: String,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.profileID = profileID
    self.body = body
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct BotNotesSnapshot: Codable, Equatable, Sendable {
  public var profileID: UUID
  public var notes: [BotNote]
  public var archived: Bool
  public var archivedAt: Date?

  public init(
    profileID: UUID,
    notes: [BotNote] = [],
    archived: Bool = false,
    archivedAt: Date? = nil
  ) {
    self.profileID = profileID
    self.notes = notes
    self.archived = archived
    self.archivedAt = archivedAt
  }

  public var composedBody: String {
    notes.map(\.body).joined(separator: "\n")
  }
}

// MARK: - Presence

public enum BotPresence: String, Codable, CaseIterable, Sendable {
  case active
  case recent
  case idle
}

/// Presentation state derived from runtime/activity data. It is intentionally not persisted:
/// appearance remains cosmetic while work and attention state stay truthful after relaunch.
public enum BotAvatarState: String, Codable, CaseIterable, Sendable {
  case idle
  case working
  case needsUser
  case failed
  case offline

  public var accessibilityLabel: String {
    switch self {
    case .idle: "Idle"
    case .working: "Working"
    case .needsUser: "Needs you"
    case .failed: "Failed"
    case .offline: "Offline"
    }
  }
}

// MARK: - Product identity and sharing contracts

/// A roster bot is a durable user-created identity. A turn helper exists only inside its parent
/// run: it never appears in the roster and can never acquire a profile, memory, connections, or
/// standing permissions merely because work was delegated to it.
public enum BotActorIdentity: Equatable, Sendable {
  case persistentBot(profileID: UUID)
  case turnHelper(runID: UUID)

  public var isDurable: Bool {
    if case .persistentBot = self { return true }
    return false
  }

  public var appearsInRoster: Bool { isDurable }
}

/// Fields considered by `BotShareManifest`.
public enum BotShareField: String, CaseIterable, Sendable {
  case role
  case instructions
  case executionDefaults
  case appearance
  case suggestedSkills
  case suggestedConnections
  case credentials
  case connectionInstances
  case privateIdentifiers
  case history
  case memory
  case files
  case routines
  case machineState
  case cookies
  case providerSessions
}

public enum BotShareDisposition: Equatable, Sendable {
  case allowed
  case prohibited
}

public enum BotShareContract {
  public static let allowedFields: Set<BotShareField> = [
    .role, .instructions, .executionDefaults, .appearance, .suggestedSkills,
    .suggestedConnections,
  ]

  public static func disposition(for field: BotShareField) -> BotShareDisposition {
    allowedFields.contains(field) ? .allowed : .prohibited
  }
}

public struct BotShareExecutionDefaults: Codable, Equatable, Sendable {
  public var provider: AgentProvider
  public var model: String?
  public var effort: String?
  public var permissionMode: String
  public var executionStrategy: AgentExecutionStrategy
  public var isolatedWorktree: Bool

  public init(
    provider: AgentProvider,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String = "workspaceWrite",
    executionStrategy: AgentExecutionStrategy = .direct,
    isolatedWorktree: Bool = false
  ) {
    self.provider = provider
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.executionStrategy = executionStrategy
    self.isolatedWorktree = isolatedWorktree
  }
}

public struct BotShareAppearance: Codable, Equatable, Sendable {
  public var avatarRef: String?
  public var petRef: String?
  public var shape: String?
  public var colorHex: String?
  public var initials: String?

  public init(
    avatarRef: String? = nil,
    petRef: String? = nil,
    shape: String? = nil,
    colorHex: String? = nil,
    initials: String? = nil
  ) {
    self.avatarRef = avatarRef
    self.petRef = petRef
    self.shape = shape
    self.colorHex = colorHex
    self.initials = initials
  }
}

/// Portable bot definition. The closed Codable shape deliberately has no place for workspace
/// identifiers, credentials, connection instances, history, memory, files, routines, machine
/// state, cookies, or provider sessions.
public struct BotShareManifest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var name: String
  public var role: String
  public var instructions: String
  public var executionDefaults: BotShareExecutionDefaults
  public var appearance: BotShareAppearance?
  public var suggestedSkillIDs: [String]
  public var suggestedConnectionIDs: [String]

  public init(
    schemaVersion: Int = BotShareManifest.currentSchemaVersion,
    name: String,
    role: String,
    instructions: String,
    executionDefaults: BotShareExecutionDefaults,
    appearance: BotShareAppearance? = nil,
    suggestedSkillIDs: [String] = [],
    suggestedConnectionIDs: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.name = name
    self.role = role
    self.instructions = instructions
    self.executionDefaults = executionDefaults
    self.appearance = appearance
    self.suggestedSkillIDs = suggestedSkillIDs
    self.suggestedConnectionIDs = suggestedConnectionIDs
  }
}

public enum BotSafetyDefaults {
  /// Connecting an app only registers it with the workspace. A bot still needs an explicit
  /// allowlist assignment, and effect-level write approval is a separate decision.
  public static let connectionImpliesBotAccess = false
  public static let connectionImpliesWritePermission = false
}

// MARK: - Mentions

public enum BotMentionResolution: Equatable, Sendable {
  case matched(AgentProfile)
  case ambiguous([AgentProfile])
  case user
  case none
}

// MARK: - Group sessions

public enum BotGroupTurnKind: String, Codable, Sendable {
  case reply
  case pass
}

public enum BotGroupMessageAuthor: Codable, Equatable, Sendable {
  case user
  case bot(UUID)
}

public struct BotGroupMessage: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var author: BotGroupMessageAuthor
  public var projectContext: ConversationProjectContext?
  public var text: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), author: BotGroupMessageAuthor, text: String, createdAt: Date = .now,
    projectContext: ConversationProjectContext? = nil
  ) {
    self.projectContext = projectContext
    self.id = id
    self.author = author
    self.text = text
    self.createdAt = createdAt
  }
}

public struct BotGroupTurn: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var profileID: UUID
  public var kind: BotGroupTurnKind
  public var text: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    profileID: UUID,
    kind: BotGroupTurnKind,
    text: String = "",
    createdAt: Date = .now
  ) {
    self.id = id
    self.profileID = profileID
    self.kind = kind
    self.text = text
    self.createdAt = createdAt
  }
}

public struct BotTeamAssignment: Codable, Equatable, Sendable {
  public var profileID: UUID
  public var task: String
  public var projectContext: ConversationProjectContext?
  public init(profileID: UUID, task: String, projectContext: ConversationProjectContext? = nil) {
    self.projectContext = projectContext
    self.profileID = profileID
    self.task = task
  }
}

/// Persisted with the room transcript before any provider dispatch.
public struct BotTeamCheckpoint: Codable, Equatable, Sendable {
  public var queue: [BotTeamAssignment]
  public var point: WorldPoint
  public var turnCounts: [UUID: Int]
  public var replyFingerprints: [String]
  public var activeRuntimeID: UUID?
  public var activeAssignment: BotTeamAssignment?
  public init(
    queue: [BotTeamAssignment], point: WorldPoint,
    turnCounts: [UUID: Int], replyFingerprints: [String],
    activeRuntimeID: UUID? = nil, activeAssignment: BotTeamAssignment? = nil
  ) {
    self.queue = queue
    self.point = point
    self.turnCounts = turnCounts
    self.replyFingerprints = replyFingerprints
    self.activeRuntimeID = activeRuntimeID
    self.activeAssignment = activeAssignment
  }
}

public struct BotGroupSession: Codable, Equatable, Sendable, Identifiable {
  public static let minMembers = 2
  public static let maxMembers = 6
  public static let maxRounds = 3
  public static let maxMessagesPerTurn = 10

  public var id: UUID
  public var memberProfileIDs: [UUID]
  public var channelID: UUID
  public var mentionedProfileIDs: [UUID]
  public var round: Int
  public var messagesThisTurn: Int
  public var silentRound: Bool
  public var settled: Bool
  public var needsUser: Bool
  public var supersededAt: Date?
  public var turns: [BotGroupTurn]
  public var messages: [BotGroupMessage]
  /// Extractive, bounded context for messages that no longer fit in the live prompt window.
  /// The full visible transcript remains in `messages`; this only controls what agents receive.
  public var teamCheckpoint: BotTeamCheckpoint?
  public var contextSummary: String?
  public var contextCompactedAt: Date?
  public var contextSpeakerNames: [UUID: String]?
  public var contextDecisions: [String]?
  public var contextOpenWork: [BotOwnedWork]?
  public var contextArtifacts: [String]?
  public var contextConstraints: [String]?
  public var contextRisks: [String]?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    memberProfileIDs: [UUID],
    channelID: UUID,
    mentionedProfileIDs: [UUID] = [],
    round: Int = 0,
    messagesThisTurn: Int = 0,
    silentRound: Bool = true,
    settled: Bool = false,
    needsUser: Bool = false,
    turns: [BotGroupTurn] = [],
    messages: [BotGroupMessage] = [],
    contextSummary: String? = nil,
    contextCompactedAt: Date? = nil,
    contextSpeakerNames: [UUID: String]? = nil,
    contextDecisions: [String]? = nil,
    contextOpenWork: [BotOwnedWork]? = nil,
    contextArtifacts: [String]? = nil,
    contextConstraints: [String]? = nil,
    contextRisks: [String]? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.memberProfileIDs = memberProfileIDs
    self.channelID = channelID
    self.mentionedProfileIDs = mentionedProfileIDs
    self.round = round
    self.messagesThisTurn = messagesThisTurn
    self.silentRound = silentRound
    self.settled = settled
    self.needsUser = needsUser
    self.turns = turns
    self.messages = messages
    self.contextSummary = contextSummary
    self.contextCompactedAt = contextCompactedAt
    self.contextSpeakerNames = contextSpeakerNames
    self.contextDecisions = contextDecisions
    self.contextOpenWork = contextOpenWork
    self.contextArtifacts = contextArtifacts
    self.contextConstraints = contextConstraints
    self.contextRisks = contextRisks
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

// MARK: - Fleet connections (references only; secrets stay in Keychain)

public enum BotIntegrationKind: String, Codable, CaseIterable, Sendable {
  case mcpServer
  case token
}

public struct BotIntegration: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var kind: BotIntegrationKind
  public var keychainRef: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    kind: BotIntegrationKind,
    keychainRef: String,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.keychainRef = keychainRef
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct BotWorkingSet: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { profileID }
  public var profileID: UUID
  public var worktreePath: String?
  public var terminalSessionID: UUID?
  public var browserProfileRef: String?
  public var browserTabGroupID: String?
  public var updatedAt: Date

  public init(
    profileID: UUID,
    worktreePath: String? = nil,
    terminalSessionID: UUID? = nil,
    browserProfileRef: String? = nil,
    browserTabGroupID: String? = nil,
    updatedAt: Date = .now
  ) {
    self.profileID = profileID
    self.worktreePath = worktreePath
    self.terminalSessionID = terminalSessionID
    self.browserProfileRef = browserProfileRef
    self.browserTabGroupID = browserTabGroupID
    self.updatedAt = updatedAt
  }
}

// MARK: - Routines / skills hooks (thin; engine lives with Routines MVP)

public enum BotRoutineDelivery: Codable, Equatable, Sendable {
  case botChannel(profileID: UUID)
}

public struct BotSkillDraft: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var sourceCapturePath: String
  public var proposedSkillID: String
  public var profileID: UUID?
  public var body: String
  public var status: BotSkillDraftStatus
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    sourceCapturePath: String,
    proposedSkillID: String,
    profileID: UUID? = nil,
    body: String,
    status: BotSkillDraftStatus = .pendingReview,
    createdAt: Date = .now
  ) {
    self.id = id
    self.sourceCapturePath = sourceCapturePath
    self.proposedSkillID = proposedSkillID
    self.profileID = profileID
    self.body = body
    self.status = status
    self.createdAt = createdAt
  }
}

public enum BotSkillDraftStatus: String, Codable, Sendable {
  case pendingReview
  case approved
  case rejected
}

// MARK: - Audit

public struct BotInteractionAudit: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var kind: String
  public var senderProfileID: UUID?
  public var receiverProfileID: UUID?
  public var source: String
  public var succeeded: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: String,
    senderProfileID: UUID? = nil,
    receiverProfileID: UUID? = nil,
    source: String,
    succeeded: Bool,
    createdAt: Date = .now
  ) {
    self.id = id
    self.kind = kind
    self.senderProfileID = senderProfileID
    self.receiverProfileID = receiverProfileID
    self.source = source
    self.succeeded = succeeded
    self.createdAt = createdAt
  }
}

// MARK: - Injection scan (Routines fire-time posture)

public enum BotPromptInjectionScanner {
  public static let notesCharacterCap = 4_000

  private static let strictPatterns: [(marker: String, expression: String)] = [
    (
      "ignore-previous-instructions",
      #"(?i)ignore\s+(all\s+)?(previous|prior|above)\s+instructions"#
    ),
    (
      "system-prompt-override",
      #"(?i)(you\s+are\s+now|new\s+system\s+prompt|override\s+(the\s+)?system)"#
    ),
    ("disable-safety", #"(?i)(disable|bypass|ignore)\s+(safety|guardrails|permissions)"#),
    (
      "exfiltrate-secrets",
      #"(?i)(print|reveal|dump)\s+(your\s+)?(system\s+prompt|api\s+key|secret|token)"#
    ),
  ]

  public static func firstStrictHit(in text: String) -> String? {
    for (marker, expression) in strictPatterns
    where text.range(of: expression, options: .regularExpression) != nil {
      return marker
    }
    return nil
  }
}

public enum BotStoreError: Error, LocalizedError, Equatable, Sendable {
  case jobTitleTooLong
  case notesTooLong(limit: Int)
  case injectionPattern(String)
  case secretDetected(String)
  case profileNotFound
  case channelArchived
  case ambiguousMention
  case mentionNotFound
  case forgeryRejected
  case groupTooSmall
  case groupTooLarge
  case groupSettled
  case groupCapReached(String)
  case credentialInRegistry
  case dirtyWorktreeBound
  case draftOnly
  case unsupportedPhoto
  case invalidDeliveryKey
  case deliveryKeyCollision
  case messageHopLimit
  case invalidDeliveryTransition

  public var errorDescription: String? {
    switch self {
    case .jobTitleTooLong:
      "Job titles must be 80 characters or fewer."
    case .notesTooLong(let limit):
      "Bot notes must stay under \(limit) characters."
    case .injectionPattern(let marker):
      "Bot memory rejected: matched injection pattern (\(marker))."
    case .secretDetected(let marker):
      "Bot memory must never contain credentials; found \(marker)."
    case .profileNotFound:
      "No saved bot profile matches that identity."
    case .channelArchived:
      "That bot channel has been archived with its profile."
    case .ambiguousMention:
      "That mention matches more than one bot. Ask the user which one."
    case .mentionNotFound:
      "No bot matches that mention."
    case .forgeryRejected:
      "A bot cannot spoof another bot or the user."
    case .groupTooSmall:
      "Group sessions need at least 2 bots."
    case .groupTooLarge:
      "Group sessions may include at most 6 bots."
    case .groupSettled:
      "This group room has already settled."
    case .groupCapReached(let cap):
      "Group session \(cap) cap reached."
    case .credentialInRegistry:
      "Connection registry holds references only; store secrets in the Keychain."
    case .dirtyWorktreeBound:
      "A dirty worktree cannot be silently rebound or deleted."
    case .draftOnly:
      "Skill drafts stay pending review until the user approves them."
    case .unsupportedPhoto:
      "Use a JPG, PNG, HEIC, or WebP photo."
    case .invalidDeliveryKey:
      "Bot messages require a bounded idempotency key."
    case .deliveryKeyCollision:
      "That bot-message idempotency key belongs to a different request."
    case .messageHopLimit:
      "This bot-message chain reached its hop limit and was stopped."
    case .invalidDeliveryTransition:
      "That bot-message delivery transition is not valid."
    }
  }
}

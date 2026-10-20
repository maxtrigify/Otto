import Foundation

public enum OrchestrationPhase: String, Codable, CaseIterable, Sendable {
  case planning
  case workers
  case review
  case corrections
  case passed
  case escalated
  case failed
  case cancelled
  case budgetExhausted
  case needsUser

  public var isTerminal: Bool {
    switch self {
    case .passed, .escalated, .failed, .cancelled, .budgetExhausted, .needsUser: true
    case .planning, .workers, .review, .corrections: false
    }
  }
}

public enum OrchestrationAssignmentStatus: String, Codable, Sendable {
  case pending
  case running
  case completed
  case failed
  case cancelled
  case timedOut
  case quotaExceeded
}

public enum OrchestrationPermissionGrant: String, Codable, CaseIterable, Sendable {
  case readOnly
  case workspaceWrite
  case unrestricted
}

public struct OrchestrationAssignment: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var expectedOutput: String
  /// Provider-neutral assignment routing. Nil lets the coordinator choose at execution time.
  public var provider: AgentProvider?
  public var model: String?
  public var executionStrategy: AgentExecutionStrategy?
  public var workerNodeID: UUID?
  public var worktreePath: String?
  public var status: OrchestrationAssignmentStatus
  public var result: String?
  /// Written before a worker performs effects. Reusing this ID is idempotent; a different ID is
  /// rejected until a user explicitly starts another correction round.
  public var executionID: UUID?
  public var resultRound: Int?
  public var evidence: [String]?
  public var baseRevision: String?
  public var completedRevision: String?

  public init(
    id: UUID = UUID(),
    title: String,
    expectedOutput: String,
    provider: AgentProvider? = nil,
    model: String? = nil,
    executionStrategy: AgentExecutionStrategy? = nil,
    workerNodeID: UUID? = nil,
    worktreePath: String? = nil,
    status: OrchestrationAssignmentStatus = .pending,
    result: String? = nil,
    executionID: UUID? = nil,
    resultRound: Int? = nil,
    evidence: [String]? = nil,
    baseRevision: String? = nil,
    completedRevision: String? = nil
  ) {
    self.id = id
    self.title = title
    self.expectedOutput = expectedOutput
    self.provider = provider
    self.model = model
    self.executionStrategy = executionStrategy
    self.workerNodeID = workerNodeID
    self.worktreePath = worktreePath
    self.status = status
    self.result = result
    self.executionID = executionID
    self.resultRound = resultRound
    self.evidence = evidence
    self.baseRevision = baseRevision
    self.completedRevision = completedRevision
  }
}

public enum OrchestrationBillingMode: String, Codable, CaseIterable, Sendable {
  case subscription
  case metered
}

public struct OrchestrationHandoff: Codable, Equatable, Sendable {
  public var reason: String
  public var round: Int
  public var pendingAssignmentIDs: [UUID]
  public var details: [String]
  public var createdAt: Date

  public init(
    reason: String,
    round: Int,
    pendingAssignmentIDs: [UUID],
    details: [String] = [],
    createdAt: Date = .now
  ) {
    self.reason = reason
    self.round = round
    self.pendingAssignmentIDs = pendingAssignmentIDs
    self.details = details
    self.createdAt = createdAt
  }
}

public struct OrchestrationReviewer: Codable, Equatable, Sendable {
  public var nodeID: UUID?
  public var provider: AgentProvider
  public var rubric: [String]

  public init(
    nodeID: UUID? = nil,
    provider: AgentProvider,
    rubric: [String]
  ) {
    self.nodeID = nodeID
    self.provider = provider
    self.rubric = rubric
  }

  public static func simplicityAware(provider: AgentProvider, nodeID: UUID? = nil)
    -> OrchestrationReviewer
  {
    OrchestrationReviewer(
      nodeID: nodeID,
      provider: provider,
      rubric: [
        "Does the evidence satisfy every acceptance criterion?",
        "Is this more complicated than necessary?",
        "What can be removed or simplified without weakening the result?",
      ]
    )
  }
}

public enum OrchestrationReviewVerdict: String, Codable, Sendable {
  case pass
  case correctionsRequired
}

public struct OrchestrationReview: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var round: Int
  public var verdict: OrchestrationReviewVerdict
  public var findings: [String]
  public var simplicityFinding: String
  public var evidence: [String]
  public var correctionAssignmentIDs: [UUID]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    round: Int,
    verdict: OrchestrationReviewVerdict,
    findings: [String],
    simplicityFinding: String,
    evidence: [String] = [],
    correctionAssignmentIDs: [UUID] = [],
    createdAt: Date = .now
  ) {
    self.id = id
    self.round = round
    self.verdict = verdict
    self.findings = findings
    self.simplicityFinding = simplicityFinding
    self.evidence = evidence
    self.correctionAssignmentIDs = correctionAssignmentIDs
    self.createdAt = createdAt
  }
}

public struct OrchestrationSpendPolicy: Codable, Equatable, Sendable {
  public var maximumWorkers: Int
  public var maximumEstimatedCost: Decimal?
  public var billingMode: OrchestrationBillingMode?
  public var knownSpend: Decimal?

  public init(
    maximumWorkers: Int,
    maximumEstimatedCost: Decimal? = nil,
    billingMode: OrchestrationBillingMode = .subscription,
    knownSpend: Decimal = 0
  ) {
    self.maximumWorkers = max(1, maximumWorkers)
    self.maximumEstimatedCost = maximumEstimatedCost
    self.billingMode = billingMode
    self.knownSpend = max(0, knownSpend)
  }

  public var effectiveBillingMode: OrchestrationBillingMode { billingMode ?? .subscription }
  public var effectiveKnownSpend: Decimal { knownSpend ?? 0 }
}

public struct OrchestrationRun: Identifiable, Codable, Equatable, Sendable {
  public var projectContext: ConversationProjectContext?
  public var id: UUID
  public var objective: String
  public var acceptanceCriteria: [String]
  public var assignments: [OrchestrationAssignment]
  public var reviewer: OrchestrationReviewer
  public var maximumRounds: Int
  public var currentRound: Int
  public var deadline: Date?
  public var permissionGrant: OrchestrationPermissionGrant
  public var spendPolicy: OrchestrationSpendPolicy
  public var phase: OrchestrationPhase
  public var reviews: [OrchestrationReview]
  public var escalationReason: String?
  public var failureReason: String?
  public var handoff: OrchestrationHandoff?
  public var mergeOwnerAssignmentID: UUID?
  public var checkpointSequence: Int?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    objective: String,
    projectContext: ConversationProjectContext? = nil,
    acceptanceCriteria: [String],
    assignments: [OrchestrationAssignment],
    reviewer: OrchestrationReviewer,
    maximumRounds: Int = 2,
    currentRound: Int = 1,
    deadline: Date? = nil,
    permissionGrant: OrchestrationPermissionGrant,
    spendPolicy: OrchestrationSpendPolicy,
    phase: OrchestrationPhase = .planning,
    reviews: [OrchestrationReview] = [],
    escalationReason: String? = nil,
    failureReason: String? = nil,
    handoff: OrchestrationHandoff? = nil,
    mergeOwnerAssignmentID: UUID? = nil,
    checkpointSequence: Int = 0,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.projectContext = projectContext
    self.objective = objective
    self.acceptanceCriteria = acceptanceCriteria
    self.assignments = assignments
    self.reviewer = reviewer
    self.maximumRounds = max(1, maximumRounds)
    self.currentRound = max(1, currentRound)
    self.deadline = deadline
    self.permissionGrant = permissionGrant
    self.spendPolicy = spendPolicy
    self.phase = phase
    self.reviews = reviews
    self.escalationReason = escalationReason
    self.failureReason = failureReason
    self.handoff = handoff
    self.mergeOwnerAssignmentID = mergeOwnerAssignmentID
    self.checkpointSequence = checkpointSequence
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

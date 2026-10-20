import Foundation
import OttoModels
import OttoRuntime
import OttoTools

public struct OrchestrationReadInput: Codable, Sendable { public init() {} }
public struct OrchestrationReadOutput: Codable, Sendable, Equatable {
  public var run: OrchestrationRun?
}

public struct OrchestrationCreateInput: Codable, Sendable {
  public var objective: String
  public var acceptanceCriteria: [String]
  public var assignments: [OrchestrationAssignment]
  public var reviewerProvider: AgentProvider
  public var maximumRounds: Int
  public var permissionGrant: OrchestrationPermissionGrant
  public var maximumWorkers: Int
  public var deadline: Date?
  public var billingMode: OrchestrationBillingMode?
  public var maximumEstimatedCost: Decimal?
}

public struct OrchestrationAssignmentResultInput: Codable, Sendable {
  public var assignmentID: UUID
  public var result: String
  public var succeeded: Bool
  public var executionID: UUID?
  public var evidence: [String]?
  public var completedRevision: String?
}

public struct OrchestrationClaimInput: Codable, Sendable {
  public var assignmentID: UUID
  public var executionID: UUID
}

public struct OrchestrationStopInput: Codable, Sendable {
  public var reason: String
}

public struct OrchestrationQuotaInput: Codable, Sendable {
  public var details: [String]
}

public struct OrchestrationSpendInput: Codable, Sendable {
  public var amount: Decimal
}

public struct OrchestrationAuthorizeInput: Codable, Sendable {
  public var permission: OrchestrationPermissionGrant
}

public struct OrchestrationBindWorktreeInput: Codable, Sendable {
  public var assignmentID: UUID
  public var path: String
  public var baseRevision: String
}

public struct OrchestrationMergeOwnerInput: Codable, Sendable {
  public var assignmentID: UUID
}

public struct OrchestrationReviewInput: Codable, Sendable {
  public var round: Int
  public var verdict: OrchestrationReviewVerdict
  public var findings: [String]
  public var simplicityFinding: String
  public var evidence: [String]
  public var correctionAssignmentIDs: [UUID]
}

public struct OrchestrationReadTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.read",
    description: "Reads the single durable orchestration contract shared by every worker.",
    inputSchema: .objectSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationReadInput, context: ToolContext) async throws
    -> OrchestrationReadOutput
  {
    OrchestrationReadOutput(run: try await store.current())
  }
}

public struct OrchestrationCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.create",
    description:
      "Creates one bounded orchestration contract with explicit acceptance criteria. Version one routes workers and the reviewer only to Claude Code or Codex; each assignment may choose its provider, model, and internal execution strategy.",
    inputSchema: .objectSchema(
      properties: [
        "objective": .stringSchema(),
        "acceptanceCriteria": orchestrationArraySchema(.stringSchema()),
        "assignments": orchestrationArraySchema(
          .objectSchema(
            properties: [
              "title": .stringSchema(description: "Bounded worker task"),
              "expectedOutput": .stringSchema(
                description: "Concrete result the worker must return"),
              "provider": .stringSchema(description: "Optional Claude Code or Codex provider"),
              "model": .stringSchema(description: "Optional provider model identifier"),
              "executionStrategy": .stringSchema(
                description:
                  "Optional direct, delegated, or scriptedWorkflow strategy; scriptedWorkflow is Claude Code only"
              ),
            ],
            required: ["title", "expectedOutput"])),
        "reviewerProvider": .stringSchema(), "maximumRounds": .numberSchema(),
        "permissionGrant": .stringSchema(), "maximumWorkers": .numberSchema(),
        "billingMode": .stringSchema(), "maximumEstimatedCost": .numberSchema(),
      ],
      required: [
        "objective", "acceptanceCriteria", "assignments", "reviewerProvider", "maximumRounds",
        "permissionGrant", "maximumWorkers",
      ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
  private let store: OrchestrationRunStore
  private let projectContext: (@Sendable (ToolContext) async -> ConversationProjectContext?)?
  public init(
    store: OrchestrationRunStore,
    projectContext: (@Sendable (ToolContext) async -> ConversationProjectContext?)? = nil
  ) {
    self.store = store
    self.projectContext = projectContext
  }
  public func call(_ input: OrchestrationCreateInput, context: ToolContext) async throws
    -> OrchestrationRun
  {
    let v1Providers: Set<AgentProvider> = [.claudeCode, .codex]
    guard v1Providers.contains(input.reviewerProvider) else {
      throw ToolRegistryError.invalidInput(
        "Otto orchestration v1 supports Claude Code and Codex reviewers")
    }
    for assignment in input.assignments {
      guard let provider = assignment.provider else { continue }
      guard v1Providers.contains(provider) else {
        throw ToolRegistryError.invalidInput(
          "Otto orchestration v1 supports Claude Code and Codex workers")
      }
      let strategy = assignment.executionStrategy ?? .direct
      guard strategy.isSupported(by: provider) else {
        throw ToolRegistryError.invalidInput(
          "\(strategy.rawValue) is not supported by \(provider.rawValue)")
      }
    }
    return try await store.create(
      OrchestrationRun(
        objective: input.objective,
        projectContext: await projectContext?(context),
        acceptanceCriteria: input.acceptanceCriteria,
        assignments: input.assignments,
        reviewer: .simplicityAware(provider: input.reviewerProvider),
        maximumRounds: input.maximumRounds,
        deadline: input.deadline,
        permissionGrant: input.permissionGrant,
        spendPolicy: OrchestrationSpendPolicy(
          maximumWorkers: input.maximumWorkers,
          maximumEstimatedCost: input.maximumEstimatedCost,
          billingMode: input.billingMode ?? .subscription)
      ))
  }
}

public struct OrchestrationBeginWorkersTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.begin_workers",
    description: "Explicitly advances the durable contract into a worker round.",
    inputSchema: .objectSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationReadInput, context: ToolContext) async throws
    -> OrchestrationRun
  { try await store.beginWorkers() }
}

public struct OrchestrationClaimAssignmentTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.claim_assignment",
    description:
      "Durably claims a worker assignment before effects; replaying its execution ID is safe.",
    inputSchema: .objectSchema(
      properties: ["assignmentID": .stringSchema(), "executionID": .stringSchema()],
      required: ["assignmentID", "executionID"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationClaimInput, context: ToolContext) async throws
    -> OrchestrationRun
  {
    try await store.claimAssignment(
      assignmentID: input.assignmentID, executionID: input.executionID)
  }
}

public struct OrchestrationReportAssignmentTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.report_assignment",
    description:
      "Records one worker result in the shared contract; it never prompts another agent.",
    inputSchema: .objectSchema(
      properties: [
        "assignmentID": .stringSchema(), "result": .stringSchema(),
        "succeeded": .booleanSchema(),
        "executionID": .stringSchema(),
        "evidence": orchestrationArraySchema(.stringSchema()),
        "completedRevision": .stringSchema(),
      ], required: ["assignmentID", "result", "succeeded"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible
  )
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationAssignmentResultInput, context: ToolContext) async throws
    -> OrchestrationRun
  {
    try await store.recordWorkerResult(
      assignmentID: input.assignmentID,
      result: input.result,
      succeeded: input.succeeded,
      executionID: input.executionID,
      evidence: input.evidence ?? [],
      completedRevision: input.completedRevision)
  }
}

public struct OrchestrationCancelTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.cancel",
    description: "Cancels the run and checkpoints every unfinished assignment as cancelled.",
    inputSchema: .objectSchema(
      properties: ["reason": .stringSchema()], required: ["reason"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationStopInput, context: ToolContext) async throws
    -> OrchestrationRun
  { try await store.cancel(reason: input.reason) }
}

public struct OrchestrationReportQuotaTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.report_quota",
    description: "Stops autonomous work and emits a structured user handoff at a quota threshold.",
    inputSchema: .objectSchema(
      properties: ["details": orchestrationArraySchema(.stringSchema())], required: ["details"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationQuotaInput, context: ToolContext) async throws
    -> OrchestrationRun
  { try await store.reportQuotaHandoff(details: input.details) }
}

public struct OrchestrationRecordSpendTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.record_spend",
    description: "Checkpoints known metered spend and stops at the configured ceiling.",
    inputSchema: .objectSchema(
      properties: ["amount": .numberSchema()], required: ["amount"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationSpendInput, context: ToolContext) async throws
    -> OrchestrationRun
  { try await store.recordSpend(input.amount) }
}

public struct OrchestrationAuthorizeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.authorize",
    description: "Checks a requested permission against the immutable up-front grant.",
    inputSchema: .objectSchema(
      properties: ["permission": .stringSchema()], required: ["permission"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .read)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationAuthorizeInput, context: ToolContext) async throws
    -> OrchestrationReadOutput
  {
    try await store.authorize(input.permission)
    return OrchestrationReadOutput(run: try await store.current())
  }
}

public struct OrchestrationBindWorktreeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.bind_worktree",
    description: "Binds an isolated worktree and base revision to one assignment.",
    inputSchema: .objectSchema(
      properties: [
        "assignmentID": .stringSchema(), "path": .stringSchema(),
        "baseRevision": .stringSchema(),
      ], required: ["assignmentID", "path", "baseRevision"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .reversible)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationBindWorktreeInput, context: ToolContext) async throws
    -> OrchestrationRun
  {
    try await store.bindWorktree(
      assignmentID: input.assignmentID, path: input.path, baseRevision: input.baseRevision)
  }
}

public struct OrchestrationClaimMergeOwnerTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.claim_merge_owner",
    description: "Selects exactly one assignment as integration owner; competing claims fail.",
    inputSchema: .objectSchema(
      properties: ["assignmentID": .stringSchema()], required: ["assignmentID"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential)
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationMergeOwnerInput, context: ToolContext) async throws
    -> OrchestrationRun
  { try await store.claimMergeOwnership(assignmentID: input.assignmentID) }
}

public struct OrchestrationSubmitReviewTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "orchestration.submit_review",
    description: "Records the single review, including simplicity findings and evidence.",
    inputSchema: .objectSchema(
      properties: [
        "round": .numberSchema(), "verdict": .stringSchema(),
        "findings": orchestrationArraySchema(.stringSchema()),
        "simplicityFinding": .stringSchema(),
        "evidence": orchestrationArraySchema(.stringSchema()),
        "correctionAssignmentIDs": orchestrationArraySchema(.stringSchema()),
      ],
      required: ["round", "verdict", "findings", "simplicityFinding"]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
  private let store: OrchestrationRunStore
  public init(store: OrchestrationRunStore) { self.store = store }
  public func call(_ input: OrchestrationReviewInput, context: ToolContext) async throws
    -> OrchestrationRun
  {
    try await store.submitReview(
      OrchestrationReview(
        round: input.round,
        verdict: input.verdict,
        findings: input.findings,
        simplicityFinding: input.simplicityFinding,
        evidence: input.evidence,
        correctionAssignmentIDs: input.correctionAssignmentIDs
      ))
  }
}

private func orchestrationArraySchema(_ items: JSONValue) -> JSONValue {
  .object(["type": .string("array"), "items": items])
}

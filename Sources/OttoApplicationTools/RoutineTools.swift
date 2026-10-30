import Foundation
import OttoModels
import OttoTools

public struct RoutineListInput: Codable, Sendable { public init() {} }
public struct RoutineGetInput: Codable, Sendable {
  public var id: UUID
  public init(id: UUID) { self.id = id }
}
public struct RoutineMutationInput: Codable, Sendable {
  public var routine: Routine
  public init(routine: Routine) { self.routine = routine }
}
public struct RoutineDeleteInput: Codable, Sendable {
  public var id: UUID
  public init(id: UUID) { self.id = id }
}
public struct RoutineTestRunInput: Codable, Sendable {
  public var id: UUID
  public var payload: String?
  public init(id: UUID, payload: String? = nil) {
    self.id = id
    self.payload = payload
  }
}
public struct RoutineRunsInput: Codable, Sendable {
  public var id: UUID?
  public var limit: Int?
  public init(id: UUID? = nil, limit: Int? = nil) {
    self.id = id
    self.limit = limit
  }
}
public struct RoutineInstructionsInput: Codable, Sendable {
  public var id: UUID
  public init(id: UUID) { self.id = id }
}
public struct RoutineWebhookReceiveInput: Codable, Sendable {
  public var slug: String
  public var body: String
  public var idempotencyKey: String
  public init(slug: String, body: String, idempotencyKey: String) {
    self.slug = slug
    self.body = body
    self.idempotencyKey = idempotencyKey
  }
}
public struct RoutineDetail: Codable, Sendable, Equatable {
  public var routine: Routine
  public var recentRuns: [RoutineRunRecord]
  public init(routine: Routine, recentRuns: [RoutineRunRecord]) {
    self.routine = routine
    self.recentRuns = recentRuns
  }
}
public struct RoutineTestRunOutput: Codable, Sendable, Equatable {
  public var fired: Bool
  public var runID: UUID?
  public var agentNodeID: UUID?
  public var reason: String?
  public init(fired: Bool, runID: UUID? = nil, agentNodeID: UUID? = nil, reason: String? = nil) {
    self.fired = fired
    self.runID = runID
    self.agentNodeID = agentNodeID
    self.reason = reason
  }
}
public struct RoutineInstructionsOutput: Codable, Sendable, Equatable {
  public var text: String
  public var oneTimeSecret: String?
  public init(text: String, oneTimeSecret: String? = nil) {
    self.text = text
    self.oneTimeSecret = oneTimeSecret
  }
}

private let routineSchema = JSONValue.objectSchema(
  properties: ["routine": .objectSchema(additionalProperties: true)], required: ["routine"])
private let routineIDSchema = JSONValue.objectSchema(
  properties: ["id": .stringSchema(description: "Routine UUID")], required: ["id"])

public struct RoutineToolHandlers: Sendable {
  public var list: @MainActor @Sendable () async throws -> [Routine]
  public var get: @MainActor @Sendable (UUID) async throws -> RoutineDetail
  public var create: @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  public var update: @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  public var delete: @MainActor @Sendable (UUID) async throws -> Bool
  public var testRun:
    @MainActor @Sendable (UUID, String?, ToolContext) async throws -> RoutineTestRunOutput
  public var runs: @MainActor @Sendable (UUID?, Int) async throws -> [RoutineRunRecord]
  public var instructions:
    @MainActor @Sendable (UUID, ToolContext) async throws -> RoutineInstructionsOutput
  public var webhookReceive:
    @MainActor @Sendable (RoutineWebhookReceiveInput, ToolContext) async throws ->
      RoutineTestRunOutput

  public init(
    list: @escaping @MainActor @Sendable () async throws -> [Routine],
    get: @escaping @MainActor @Sendable (UUID) async throws -> RoutineDetail,
    create: @escaping @MainActor @Sendable (Routine, ToolContext) async throws -> Routine,
    update: @escaping @MainActor @Sendable (Routine, ToolContext) async throws -> Routine,
    delete: @escaping @MainActor @Sendable (UUID) async throws -> Bool,
    testRun:
      @escaping @MainActor @Sendable (UUID, String?, ToolContext) async throws ->
      RoutineTestRunOutput,
    runs: @escaping @MainActor @Sendable (UUID?, Int) async throws -> [RoutineRunRecord],
    instructions:
      @escaping @MainActor @Sendable (UUID, ToolContext) async throws -> RoutineInstructionsOutput,
    webhookReceive:
      @escaping @MainActor @Sendable (RoutineWebhookReceiveInput, ToolContext) async throws ->
      RoutineTestRunOutput
  ) {
    self.list = list
    self.get = get
    self.create = create
    self.update = update
    self.delete = delete
    self.testRun = testRun
    self.runs = runs
    self.instructions = instructions
    self.webhookReceive = webhookReceive
  }
}

public struct RoutineListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.list", description: "Lists workspace routines and their current status.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  private let handler: @MainActor @Sendable () async throws -> [Routine]
  public init(handler: @escaping @MainActor @Sendable () async throws -> [Routine]) {
    self.handler = handler
  }
  public func call(_ input: RoutineListInput, context: ToolContext) async throws -> [Routine] {
    try await handler()
  }
}

public struct RoutineGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.get", description: "Gets a routine definition and recent runs.",
    inputSchema: routineIDSchema, outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  private let handler: @MainActor @Sendable (UUID) async throws -> RoutineDetail
  public init(handler: @escaping @MainActor @Sendable (UUID) async throws -> RoutineDetail) {
    self.handler = handler
  }
  public func call(_ input: RoutineGetInput, context: ToolContext) async throws -> RoutineDetail {
    try await handler(input.id)
  }
}

public struct RoutineCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.create",
    description:
      "Creates an automation. Bots and sessions can set enabled to true to turn it on, or false to save it paused. Webhook automations need a signing secret configured before they can turn on. To chain it into a flow, set runAfter to {\"routineID\": \"<UUID>\", \"when\": \"succeeded\"|\"failed\"|\"finished\"}; it then runs when that routine finishes and receives its answer as untrusted payload. To have the user approve each answer first, set reviewOnHome to true: the answer waits on their Home page to approve, comment on or reject, and following steps run only once approved. afterApproval (optional) is what the same agent then does with the approved text, e.g. \"Post it in #tips on Discord\".",
    inputSchema: routineSchema, outputSchema: .objectSchema(), requiredScopes: [.canvasWrite],
    riskLevel: .consequential)
  private let handler: @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  public init(
    handler: @escaping @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  ) { self.handler = handler }
  public func call(_ input: RoutineMutationInput, context: ToolContext) async throws -> Routine {
    try await handler(input.routine, context)
  }
}

public struct RoutineUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.update",
    description:
      "Updates an automation. Use routine.get first, then pass the full routine with enabled set to true to turn it on or false to pause it. Bots and sessions can enable automations. Webhook automations need a signing secret configured before they can turn on.",
    inputSchema: routineSchema, outputSchema: .objectSchema(), requiredScopes: [.canvasWrite],
    riskLevel: .consequential)
  private let handler: @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  public init(
    handler: @escaping @MainActor @Sendable (Routine, ToolContext) async throws -> Routine
  ) { self.handler = handler }
  public func call(_ input: RoutineMutationInput, context: ToolContext) async throws -> Routine {
    try await handler(input.routine, context)
  }
}

public struct RoutineDeleteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.delete", description: "Permanently deletes a routine.",
    inputSchema: routineIDSchema,
    outputSchema: .objectSchema(), requiredScopes: [.globalDestructive], riskLevel: .destructive,
    requiresConfirmation: true)
  private let handler: @MainActor @Sendable (UUID) async throws -> Bool
  public init(handler: @escaping @MainActor @Sendable (UUID) async throws -> Bool) {
    self.handler = handler
  }
  public func call(_ input: RoutineDeleteInput, context: ToolContext) async throws -> Bool {
    try await handler(input.id)
  }
}

public struct RoutineTestRunTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.test_run",
    description: "Runs a routine once with an optional sample payload. User initiated only.",
    inputSchema: .objectSchema(
      properties: ["id": .stringSchema(), "payload": .stringSchema()], required: ["id"]),
    outputSchema: .objectSchema(), requiredScopes: [.agentControl], riskLevel: .consequential)
  private let handler:
    @MainActor @Sendable (UUID, String?, ToolContext) async throws -> RoutineTestRunOutput
  public init(
    handler:
      @escaping @MainActor @Sendable (UUID, String?, ToolContext) async throws ->
      RoutineTestRunOutput
  ) { self.handler = handler }
  public func call(_ input: RoutineTestRunInput, context: ToolContext) async throws
    -> RoutineTestRunOutput
  { try await handler(input.id, input.payload, context) }
}

public struct RoutineRunsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.runs", description: "Reads recent routine run history.",
    inputSchema: .objectSchema(properties: ["id": .stringSchema(), "limit": .integerSchema()]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  private let handler: @MainActor @Sendable (UUID?, Int) async throws -> [RoutineRunRecord]
  public init(
    handler: @escaping @MainActor @Sendable (UUID?, Int) async throws -> [RoutineRunRecord]
  ) { self.handler = handler }
  public func call(_ input: RoutineRunsInput, context: ToolContext) async throws
    -> [RoutineRunRecord]
  { try await handler(input.id, min(200, max(1, input.limit ?? 50))) }
}

public struct RoutineInstructionsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.instructions", description: "Returns setup instructions for a routine trigger.",
    inputSchema: routineIDSchema, outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  private let handler:
    @MainActor @Sendable (UUID, ToolContext) async throws -> RoutineInstructionsOutput
  public init(
    handler:
      @escaping @MainActor @Sendable (UUID, ToolContext) async throws -> RoutineInstructionsOutput
  ) { self.handler = handler }
  public func call(_ input: RoutineInstructionsInput, context: ToolContext) async throws
    -> RoutineInstructionsOutput
  { try await handler(input.id, context) }
}

public struct RoutineWebhookReceiveTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "routine.webhook_receive",
    description: "Internal hook daemon delivery endpoint.",
    inputSchema: .objectSchema(
      properties: [
        "slug": .stringSchema(), "body": .stringSchema(), "idempotencyKey": .stringSchema(),
      ],
      required: ["slug", "body", "idempotencyKey"]),
    outputSchema: .objectSchema(), requiredScopes: [.agentControl], riskLevel: .consequential,
    providerInternal: true)
  private let handler:
    @MainActor @Sendable (RoutineWebhookReceiveInput, ToolContext) async throws ->
      RoutineTestRunOutput
  public init(
    handler:
      @escaping @MainActor @Sendable (RoutineWebhookReceiveInput, ToolContext) async throws ->
      RoutineTestRunOutput
  ) { self.handler = handler }
  public func call(_ input: RoutineWebhookReceiveInput, context: ToolContext) async throws
    -> RoutineTestRunOutput
  {
    guard context.source == .automation else {
      throw ToolRegistryError.invalidInput("Webhook delivery requires automation provenance")
    }
    return try await handler(input, context)
  }
}

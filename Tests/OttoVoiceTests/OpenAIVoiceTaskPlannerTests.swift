import Foundation
import OttoSecurity
import OttoTools
import OttoVoice
import Testing

private struct StaticVoiceTaskPlanner: VoiceTaskPlanning {
  let value: VoiceTaskPlan

  func plan(
    objective: String,
    context: VoiceContext?,
    availableProviders: [String]
  ) async throws -> VoiceTaskPlan {
    value
  }
}

private actor ParallelLaunchProbe {
  private(set) var maximumInFlight = 0
  private var inFlight = 0

  func run() async -> UUID {
    inFlight += 1
    maximumInFlight = max(maximumInFlight, inFlight)
    try? await Task.sleep(for: .milliseconds(150))
    inFlight -= 1
    return UUID()
  }
}

private struct VoiceAgentProvidersProbeTool: OttoTool {
  struct Input: Codable, Sendable {}
  struct ProviderInfo: Codable, Sendable {
    var provider: String
    var installed: Bool
  }
  typealias Output = [ProviderInfo]

  static let definition = ToolDefinition(
    name: "agent.providers",
    description: "Test provider inventory",
    inputSchema: .objectSchema(),
    outputSchema: .objectSchema(),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    [ProviderInfo(provider: "Codex", installed: true)]
  }
}

private struct VoiceAgentSpawnProbeTool: OttoTool {
  struct Input: Codable, Sendable {
    var provider: String
    var displayName: String
    var prompt: String
    var x: Double
    var y: Double
    var permissionMode: String
    var isolatedWorktree: Bool
  }
  struct Output: Codable, Sendable { var agentID: UUID }

  static let definition = ToolDefinition(
    name: "agent.spawn",
    description: "Test agent launch",
    inputSchema: .objectSchema(
      properties: [
        "provider": .stringSchema(),
        "displayName": .stringSchema(),
        "prompt": .stringSchema(),
        "workingDirectory": .stringSchema(),
        "x": .numberSchema(),
        "y": .numberSchema(),
        "permissionMode": .stringSchema(),
        "isolatedWorktree": .booleanSchema(),
      ],
      required: [
        "provider", "displayName", "prompt", "x", "y", "permissionMode", "isolatedWorktree",
      ]
    ),
    outputSchema: .objectSchema(),
    requiredScopes: [],
    riskLevel: .consequential
  )

  let probe: ParallelLaunchProbe

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(agentID: await probe.run())
  }
}

private actor DelegationVoiceProviderProbe: VoiceProvider {
  nonisolated let events: AsyncStream<VoiceProviderEvent>
  nonisolated let results: AsyncStream<VoiceToolResult>
  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let resultContinuation: AsyncStream<VoiceToolResult>.Continuation
  private(set) var projectedTools: [ToolDefinition] = []

  init() {
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var resultContinuation: AsyncStream<VoiceToolResult>.Continuation!
    results = AsyncStream { resultContinuation = $0 }
    self.resultContinuation = resultContinuation
  }

  func connect(tools: [ToolDefinition]) {
    projectedTools = tools
    eventContinuation.yield(.connected)
  }

  func emit(_ event: VoiceProviderEvent) { eventContinuation.yield(event) }
  func sendToolResult(_ result: VoiceToolResult) { resultContinuation.yield(result) }
  func interrupt() { eventContinuation.yield(.interrupted) }
  func disconnect() { eventContinuation.yield(.disconnected) }
}

@Suite("OpenAI voice delegation planner")
struct OpenAIVoiceTaskPlannerTests {
  @Test("Voice acknowledges immediately and launches independent tasks concurrently")
  func asynchronousParallelLaunch() async throws {
    let launchProbe = ParallelLaunchProbe()
    let registry = ToolRegistry()
    try await registry.register(VoiceAgentProvidersProbeTool())
    try await registry.register(VoiceAgentSpawnProbeTool(probe: launchProbe))
    let plan = VoiceTaskPlan(
      summary: "Run both workstreams",
      tasks: [
        VoiceDelegatedTask(
          title: "First", prompt: "Do the first task", expectedOutput: "First result",
          provider: "Codex"),
        VoiceDelegatedTask(
          title: "Second", prompt: "Do the second task", expectedOutput: "Second result",
          provider: "Codex"),
      ]
    )
    let provider = DelegationVoiceProviderProbe()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice", scopes: [.agentControl, .canvasWrite]),
      taskPlanner: StaticVoiceTaskPlanner(value: plan)
    )
    await session.connect(provider: provider)
    #expect(await provider.projectedTools.contains { $0.name == VoiceTaskDelegationTool.name })

    let actionTask = Task<VoiceActionEvent?, Never> {
      for await action in session.actions { return action }
      return nil
    }
    await provider.emit(
      .toolCall(
        id: "parallel-call",
        name: VoiceTaskDelegationTool.name,
        arguments: .object(["objective": .string("Do both tasks")])
      ))

    let accepted = try await firstDelegationResult(from: provider.results)
    #expect(accepted.result["accepted"] == .bool(true))
    let action = try #require(await actionTask.value)
    #expect(action.output["taskCount"] == .number(2))
    #expect(await launchProbe.maximumInFlight == 2)
    await session.sleep()
  }

  @Test("Responses API uses GPT-5.6 structured output and preserves every worker brief")
  func structuredPlan() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("test-key", for: "openai.api-key")
    let responsePlan = VoiceTaskPlan(
      summary: "Build and independently review the feature",
      tasks: [
        VoiceDelegatedTask(
          title: "Implement voice routing",
          prompt: "Implement the routing change and run its tests.",
          expectedOutput: "A tested implementation",
          provider: "Codex"
        ),
        VoiceDelegatedTask(
          title: "Review edge cases",
          prompt: "Review concurrency and interruption edge cases.",
          expectedOutput: "A concise findings report",
          provider: "Claude Code"
        ),
      ]
    )
    let responseText = String(decoding: try JSONEncoder().encode(responsePlan), as: UTF8.self)
    let responseBody = try JSONSerialization.data(withJSONObject: [
      "id": "resp_test",
      "output": [
        [
          "type": "message",
          "content": [["type": "output_text", "text": responseText]],
        ]
      ],
    ])

    let planner = OpenAIVoiceTaskPlanner(
      secrets: secrets,
      transport: { request in
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        guard let requestBody = request.httpBody, let requestURL = request.url else {
          throw OpenAIVoiceTaskPlannerError.invalidResponse("test request was incomplete")
        }
        let body = try #require(
          try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == "gpt-5.6")
        #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        let format = ((body["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format?["type"] as? String == "json_schema")
        #expect(format?["strict"] as? Bool == true)
        return (
          responseBody,
          HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
          )!
        )
      }
    )

    let plan = try await planner.plan(
      objective: "Build the feature and review it independently",
      context: nil,
      availableProviders: ["Codex", "Claude Code"]
    )
    #expect(plan == responsePlan)
  }

  @Test("Planner rejects a provider that is not installed")
  func providerAllowList() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("test-key", for: "openai.api-key")
    let invalid = VoiceTaskPlan(
      summary: "Use an unavailable worker",
      tasks: [
        VoiceDelegatedTask(
          title: "Task",
          prompt: "Do the task",
          expectedOutput: "Result",
          provider: "Unavailable"
        )
      ]
    )
    let text = String(decoding: try JSONEncoder().encode(invalid), as: UTF8.self)
    let body = try JSONSerialization.data(withJSONObject: [
      "output": [
        [
          "type": "message",
          "content": [["type": "output_text", "text": text]],
        ]
      ]
    ])
    let planner = OpenAIVoiceTaskPlanner(
      secrets: secrets,
      transport: { request in
        guard let requestURL = request.url else {
          throw OpenAIVoiceTaskPlannerError.invalidResponse("test request was incomplete")
        }
        return (
          body,
          HTTPURLResponse(
            url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      }
    )

    await #expect(throws: OpenAIVoiceTaskPlannerError.self) {
      try await planner.plan(
        objective: "Do the task",
        context: nil,
        availableProviders: ["Codex"]
      )
    }
  }
}

private func firstDelegationResult(from stream: AsyncStream<VoiceToolResult>) async throws
  -> VoiceToolResult
{
  try await withThrowingTaskGroup(of: VoiceToolResult.self) { group in
    group.addTask {
      for await result in stream { return result }
      throw OpenAIVoiceTaskPlannerError.invalidResponse("result stream closed")
    }
    group.addTask {
      try await Task.sleep(for: .seconds(2))
      throw OpenAIVoiceTaskPlannerError.invalidResponse("timed out waiting for result")
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}

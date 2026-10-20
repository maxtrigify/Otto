import Foundation
import OttoSecurity
import OttoTools

public enum VoiceTaskDelegationTool {
  public static let name = "otto.delegate_tasks"
  public static let definition = ToolDefinition(
    name: name,
    description:
      "Delegates a compound request to Otto's dedicated reasoning path. Use this once when the user asks for two or more independent pieces of work, or explicitly asks Otto to run work in parallel. Put the complete request, including every constraint, in objective.",
    inputSchema: .objectSchema(
      properties: [
        "objective": .stringSchema(
          description:
            "The user's complete compound objective, without paraphrasing away constraints")
      ],
      required: ["objective"]
    ),
    outputSchema: .objectSchema(),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
}

public struct VoiceDelegatedTask: Codable, Sendable, Equatable {
  public var title: String
  public var prompt: String
  public var expectedOutput: String
  public var provider: String
  /// When the objective names or clearly implies an agent that already exists on the canvas,
  /// this carries its node id and the task is sent to that agent instead of spawning a twin.
  public var existingAgentID: String?

  public init(
    title: String, prompt: String, expectedOutput: String, provider: String,
    existingAgentID: String? = nil
  ) {
    self.title = title
    self.prompt = prompt
    self.expectedOutput = expectedOutput
    self.provider = provider
    self.existingAgentID = existingAgentID
  }
}

public struct VoiceTaskPlan: Codable, Sendable, Equatable {
  public var summary: String
  public var tasks: [VoiceDelegatedTask]

  public init(summary: String, tasks: [VoiceDelegatedTask]) {
    self.summary = summary
    self.tasks = tasks
  }
}

public protocol VoiceTaskPlanning: Sendable {
  func plan(
    objective: String,
    context: VoiceContext?,
    availableProviders: [String]
  ) async throws -> VoiceTaskPlan
}

public struct OpenAIVoiceTaskPlannerConfiguration: Sendable, Equatable {
  public var endpoint: URL
  public var model: String
  public var reasoningEffort: String
  public var maximumTasks: Int

  public init(
    endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
    model: String = "gpt-5.6",
    reasoningEffort: String = "medium",
    maximumTasks: Int = 6
  ) {
    self.endpoint = endpoint
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.maximumTasks = min(max(maximumTasks, 1), 8)
  }
}

public enum OpenAIVoiceTaskPlannerError: Error, LocalizedError, Sendable, Equatable {
  case missingAPIKey
  case invalidObjective
  case invalidResponse(String)
  case requestFailed(status: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "An OpenAI API key is required for Otto's multi-task reasoning path"
    case .invalidObjective:
      "The delegated objective is empty"
    case .invalidResponse(let message):
      "The task planner returned an invalid response: \(message)"
    case .requestFailed(let status, let message):
      "The task planner failed (HTTP \(status)): \(message)"
    }
  }
}

/// The slower reasoning half of Otto's two-path voice architecture. Realtime remains responsible
/// for the live conversation; this actor only turns a compound request into bounded worker briefs.
public actor OpenAIVoiceTaskPlanner: VoiceTaskPlanning {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

  private let secrets: any SecretStore
  private let configuration: OpenAIVoiceTaskPlannerConfiguration
  private let transport: Transport

  public init(
    secrets: any SecretStore,
    configuration: OpenAIVoiceTaskPlannerConfiguration = .init(),
    transport: @escaping Transport = { request in
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw OpenAIVoiceTaskPlannerError.invalidResponse("missing HTTP response")
      }
      return (data, http)
    }
  ) {
    self.secrets = secrets
    self.configuration = configuration
    self.transport = transport
  }

  public func plan(
    objective: String,
    context: VoiceContext?,
    availableProviders: [String]
  ) async throws -> VoiceTaskPlan {
    let objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty else { throw OpenAIVoiceTaskPlannerError.invalidObjective }
    guard let apiKey = try await secrets.value(for: "openai.api-key"), !apiKey.isEmpty else {
      throw OpenAIVoiceTaskPlannerError.missingAPIKey
    }

    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 45
    request.httpBody = try JSONSerialization.data(
      withJSONObject: requestBody(
        objective: objective,
        context: context,
        availableProviders: availableProviders
      ))

    let (data, response) = try await transport(request)
    guard (200..<300).contains(response.statusCode) else {
      throw OpenAIVoiceTaskPlannerError.requestFailed(
        status: response.statusCode,
        message: Self.apiErrorMessage(data)
          ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
      )
    }
    let text = try Self.outputText(data)
    let plan: VoiceTaskPlan
    do {
      plan = try JSONDecoder().decode(VoiceTaskPlan.self, from: Data(text.utf8))
    } catch {
      throw OpenAIVoiceTaskPlannerError.invalidResponse(error.localizedDescription)
    }
    return try validate(plan, availableProviders: availableProviders)
  }

  private func requestBody(
    objective: String,
    context: VoiceContext?,
    availableProviders: [String]
  ) -> [String: Any] {
    let providerList =
      availableProviders.isEmpty
      ? ["Codex", "Claude Code", "Hermes"]
      : availableProviders
    let contextJSON: String
    if let context,
      let data = try? JSONEncoder().encode(context)
    {
      contextJSON = String(decoding: data, as: UTF8.self)
    } else {
      contextJSON = "{}"
    }
    let instructions = """
      You are Otto's private delegation planner. Split the user's compound objective into the
      smallest set of genuinely independent worker tasks that can run concurrently. Preserve every
      explicit constraint and named target. Never invent extra product work. If work is sequential,
      keep it in one task. Produce at most \(configuration.maximumTasks) tasks. Each prompt must be
      self-contained and end with concrete acceptance evidence. Select only one of these installed
      providers: \(providerList.joined(separator: ", ")). Prefer Codex for implementation and
      repository work, Claude Code for a second independent implementation/review stream or for
      any task that coordinates, messages, or reads other canvas agents (Claude Code always has
      the otto canvas tools), and Hermes only for bounded external research — Hermes may run
      remotely without canvas access and must never be chosen to coordinate canvas agents.
      The context lists the agents already open on the canvas (nodes with kind "agent",
      including their id, name, provider, and status). When the objective names one of them or
      an existing idle agent of the right provider already fits the task, set existingAgentID
      to that node's id and set provider to that agent's provider instead of creating a
      duplicate. Set existingAgentID to null only when no existing agent fits.
      """
    let userInput = """
      Objective:
      \(objective)

      Compact Otto context (node content excluded):
      \(contextJSON)
      """
    return [
      "model": configuration.model,
      "instructions": instructions,
      "input": userInput,
      "reasoning": ["effort": configuration.reasoningEffort],
      "text": [
        "format": [
          "type": "json_schema",
          "name": "otto_voice_task_plan",
          "strict": true,
          "schema": Self.planSchema(maximumTasks: configuration.maximumTasks),
        ]
      ],
      "store": false,
    ]
  }

  private func validate(_ plan: VoiceTaskPlan, availableProviders: [String]) throws -> VoiceTaskPlan
  {
    guard !plan.tasks.isEmpty, plan.tasks.count <= configuration.maximumTasks else {
      throw OpenAIVoiceTaskPlannerError.invalidResponse(
        "expected 1...\(configuration.maximumTasks) tasks")
    }
    let allowed = Set(
      availableProviders.isEmpty ? ["Codex", "Claude Code", "Hermes"] : availableProviders)
    for task in plan.tasks {
      guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !task.expectedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw OpenAIVoiceTaskPlannerError.invalidResponse("a worker brief is empty")
      }
      guard allowed.contains(task.provider) else {
        throw OpenAIVoiceTaskPlannerError.invalidResponse(
          "provider \(task.provider) is not installed")
      }
      if let existing = task.existingAgentID, !existing.isEmpty {
        guard UUID(uuidString: existing) != nil else {
          throw OpenAIVoiceTaskPlannerError.invalidResponse(
            "existingAgentID must be a node UUID from the context")
        }
      }
    }
    return plan
  }

  private static func planSchema(maximumTasks: Int) -> [String: Any] {
    [
      "type": "object",
      "additionalProperties": false,
      "properties": [
        "summary": ["type": "string"],
        "tasks": [
          "type": "array",
          "minItems": 1,
          "maxItems": maximumTasks,
          "items": [
            "type": "object",
            "additionalProperties": false,
            "properties": [
              "title": ["type": "string"],
              "prompt": ["type": "string"],
              "expectedOutput": ["type": "string"],
              "provider": ["type": "string"],
              "existingAgentID": ["type": ["string", "null"]],
            ],
            "required": ["title", "prompt", "expectedOutput", "provider", "existingAgentID"],
          ],
        ],
      ],
      "required": ["summary", "tasks"],
    ]
  }

  private static func outputText(_ data: Data) throws -> String {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let output = root["output"] as? [[String: Any]]
    else {
      throw OpenAIVoiceTaskPlannerError.invalidResponse("missing output")
    }
    for item in output where item["type"] as? String == "message" {
      guard let content = item["content"] as? [[String: Any]] else { continue }
      if let refusal = content.first(where: { $0["type"] as? String == "refusal" })?["refusal"]
        as? String
      {
        throw OpenAIVoiceTaskPlannerError.invalidResponse(refusal)
      }
      if let text = content.first(where: { $0["type"] as? String == "output_text" })?["text"]
        as? String
      {
        return text
      }
    }
    throw OpenAIVoiceTaskPlannerError.invalidResponse("missing output_text")
  }

  private static func apiErrorMessage(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = root["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }
}

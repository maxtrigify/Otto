import Foundation
import OttoModels
import OttoRuntime
import OttoTools

/// Payload Claude Code sends to its `--permission-prompt-tool`. Extra provider fields such as
/// `permission_suggestions` are accepted and ignored.
public struct AgentPermissionPromptInput: Codable, Sendable {
  public var toolName: String
  public var input: JSONValue?
  public var toolUseID: String?

  enum CodingKeys: String, CodingKey {
    case toolName = "tool_name"
    case input
    case toolUseID = "tool_use_id"
  }

  public init(toolName: String, input: JSONValue? = nil, toolUseID: String? = nil) {
    self.toolName = toolName
    self.input = input
    self.toolUseID = toolUseID
  }
}

/// Claude Code's required response contract: the tool result text must be JSON with `behavior`
/// "allow" (echoing the input as `updatedInput`) or "deny" (with a `message`).
public struct AgentPermissionPromptOutput: Codable, Sendable, Equatable {
  public var behavior: String
  public var updatedInput: JSONValue?
  public var message: String?

  public static func allow(updatedInput: JSONValue) -> Self {
    Self(behavior: "allow", updatedInput: updatedInput, message: nil)
  }

  public static func deny(message: String) -> Self {
    Self(behavior: "deny", updatedInput: nil, message: message)
  }
}

/// The approval tool one-shot provider runs call through the otto-mcp bridge whenever Claude
/// Code needs tool permission. It parks the request on the supervisor, which surfaces the agent
/// as WAITING_PERMISSION until the user answers in the conversation, then relays the decision.
/// Every failure path returns a structured deny rather than throwing, so the provider always
/// receives the JSON contract it expects.
public struct AgentRequestPermissionTool: OttoTool {
  public static let definition = ToolDefinition(
    name: AgentPermissionPrompt.toolName,
    description:
      "Requests the user's permission for a provider tool call and blocks until they approve or deny it in the agent conversation. Called automatically by provider CLIs; agents never need to invoke it directly.",
    inputSchema: .objectSchema(
      properties: [
        "tool_name": .stringSchema(description: "Tool the provider wants to run"),
        "input": .object([
          "type": .string("object"),
          "description": .string("Input the provider wants to pass to the tool"),
        ]),
        "tool_use_id": .stringSchema(description: "Provider identifier for this tool use"),
        "permission_suggestions": .object([
          "type": .string("array"),
          "description": .string("Optional provider permission suggestions; accepted and ignored"),
          "items": .object([:]),
        ]),
      ],
      required: ["tool_name"]
      // Closed schema, like every registered tool. If a future provider adds payload fields the
      // call fails validation and the provider receives an error, which it treats as a denial —
      // extend the properties above rather than opening the schema.
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read,
    providerInternal: true
  )

  private let supervisor: AgentSupervisor
  private let browserConfirmationTimeout: Duration

  public init(
    supervisor: AgentSupervisor,
    browserConfirmationTimeout: Duration = AgentPermissionPrompt.browserConfirmationTimeout
  ) {
    self.supervisor = supervisor
    self.browserConfirmationTimeout = browserConfirmationTimeout
  }

  public func call(_ input: AgentPermissionPromptInput, context: ToolContext) async throws
    -> AgentPermissionPromptOutput
  {
    guard let agentID = context.sourceNodeID ?? Self.nodeID(fromActorID: context.actorID) else {
      return .deny(message: "Otto could not identify the agent requesting permission")
    }
    do {
      let approved = try await supervisor.requestPermission(
        agentID: agentID,
        toolName: input.toolName,
        detail: Self.detail(toolName: input.toolName, input: input.input),
        timeout: input.toolName == "browser.click" ? browserConfirmationTimeout : nil,
        // Dotted Otto tools are app confirmations; the supervisor also applies tool bypass
        // to browser.click, while account access and other app confirmations stay explicit.
        isProviderPermission: !input.toolName.contains("."),
        detailLimit: EmailApprovalSummary.tools.contains(input.toolName)
          ? EmailApprovalSummary.limit : 240
      )
      if approved {
        return .allow(updatedInput: input.input ?? .object([:]))
      }
      return .deny(message: "The user denied \(input.toolName) in Otto")
    } catch RuntimeError.permissionExpired {
      return .deny(message: RuntimeError.permissionExpired.localizedDescription)
    } catch {
      return .deny(
        message: "Otto could not route this permission request: \(error.localizedDescription)")
    }
  }

  /// Agent control tokens are issued as "otto-agent-<nodeID>" ("muse-agent-<nodeID>" before the
  /// rename); recover the node when the grant did not carry an explicit source node.
  static func nodeID(fromActorID actorID: String) -> UUID? {
    for prefix in ["otto-agent-", "muse-agent-"] where actorID.hasPrefix(prefix) {
      return UUID(uuidString: String(actorID.dropFirst(prefix.count)))
    }
    return nil
  }

  private static func detail(toolName: String, input: JSONValue?) -> String {
    guard case .object(let object)? = input else { return "" }
    if let email = EmailApprovalSummary.text(toolName: toolName, input: object) { return email }
    var bridged: [String: Any] = [:]
    for (key, value) in object {
      if case .string(let string) = value { bridged[key] = string }
    }
    return ClaudeOutputParser.toolDetail(name: toolName, input: bridged)
  }
}

/// What the approval card shows before an email goes out: the recipient, the subject and the
/// body itself, so the person approves the exact message rather than a one-line excerpt.
public enum EmailApprovalSummary {
  public static let tools: Set<String> = ["gmail.send", "gmail.reply", "smtp.send"]
  /// Room for the headers and a long body; longer bodies say how much is not shown.
  public static let limit = 2_400
  public static let bodyLimit = 2_000

  public static func text(toolName: String, input: [String: JSONValue]) -> String? {
    guard tools.contains(toolName) else { return nil }
    let to = input["to"]?.stringValue ?? "(no recipient)"
    let subject = input["subject"]?.stringValue ?? "(no subject)"
    let body = (input["body"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = ["Send email to \(to)", "Subject: \(subject)"]
    if toolName == "gmail.reply" || input["inReplyTo"]?.stringValue != nil {
      lines.append("Reply in the original thread")
    }
    lines.append("")
    lines.append(String(body.prefix(bodyLimit)))
    if body.count > bodyLimit {
      lines.append("…and \(body.count - bodyLimit) more characters")
    }
    return lines.joined(separator: "\n")
  }
}

public struct AgentAskUserInput: Codable, Sendable {
  public var question: String
  public var choices: [String]?
  public var multiSelect: Bool?

  enum CodingKeys: String, CodingKey {
    case question
    case choices
    case multiSelect = "multi_select"
  }

  public init(question: String, choices: [String]? = nil, multiSelect: Bool? = nil) {
    self.question = question
    self.choices = choices
    self.multiSelect = multiSelect
  }
}

public struct AgentAskUserOutput: Codable, Sendable, Equatable {
  /// The user's answer: one of the offered choices, several joined with ", " when multi-select,
  /// a free-typed reply, or "" when they skipped or the run ended first.
  public var answer: String

  public init(answer: String) {
    self.answer = answer
  }
}

/// The universal in-chat question tool. An agent asks a question with up to a handful of
/// choices; Otto renders them as buttons in the conversation and blocks this call until the
/// user picks one or types their own answer.
public struct AgentAskUserTool: OttoTool {
  public static let definition = ToolDefinition(
    name: AgentUserChoicePrompt.toolName,
    description:
      "Asks the user a question in the agent conversation and blocks until they answer. Provide up to 5 short choices to render as buttons; the user can always type a custom reply instead. Use this when a decision genuinely needs the user, not for confirmations you can infer.",
    inputSchema: .objectSchema(
      properties: [
        "question": .stringSchema(description: "The question to show the user"),
        "choices": .object([
          "type": .string("array"),
          "description": .string("Up to 5 short selectable answers, rendered as buttons"),
          "items": .object(["type": .string("string")]),
        ]),
        "multi_select": .object([
          "type": .string("boolean"),
          "description": .string(
            "Allow selecting several choices; the answer joins them with ', '"),
        ]),
      ],
      required: ["question"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read,
    providerInternal: true
  )

  private let supervisor: AgentSupervisor

  public init(supervisor: AgentSupervisor) {
    self.supervisor = supervisor
  }

  public func call(_ input: AgentAskUserInput, context: ToolContext) async throws
    -> AgentAskUserOutput
  {
    guard
      let agentID = context.sourceNodeID
        ?? AgentRequestPermissionTool.nodeID(fromActorID: context.actorID)
    else {
      throw ToolRegistryError.invalidInput("Otto could not identify the agent asking the question")
    }
    let question = input.question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else {
      throw ToolRegistryError.invalidInput("question must not be empty")
    }
    let answer = try await supervisor.requestChoice(
      agentID: agentID,
      question: question,
      choices: Array((input.choices ?? []).prefix(5)),
      multiSelect: input.multiSelect ?? false
    )
    return AgentAskUserOutput(answer: answer)
  }
}

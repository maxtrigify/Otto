import Foundation

public enum AgentGoalStatus: String, Codable, Sendable, Equatable {
  case active
  case paused
  case completed
}

public struct AgentGoal: Codable, Sendable, Equatable {
  public var objective: String
  public var status: AgentGoalStatus
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    objective: String,
    status: AgentGoalStatus = .active,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.objective = objective
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct AgentLoop: Codable, Sendable, Equatable {
  public var prompt: String
  public var intervalSeconds: TimeInterval
  public var isEnabled: Bool
  public var iterationCount: Int
  public var nextRunAt: Date
  public var lastRunAt: Date?

  public init(
    prompt: String,
    intervalSeconds: TimeInterval,
    isEnabled: Bool = true,
    iterationCount: Int = 0,
    nextRunAt: Date,
    lastRunAt: Date? = nil
  ) {
    self.prompt = prompt
    self.intervalSeconds = intervalSeconds
    self.isEnabled = isEnabled
    self.iterationCount = iterationCount
    self.nextRunAt = nextRunAt
    self.lastRunAt = lastRunAt
  }
}

public enum AgentGoalCommand: Sendable, Equatable {
  case show
  case set(String)
  case pause
  case resume
  case complete
  case clear
}

public enum AgentLoopCommand: Sendable, Equatable {
  case show
  case start(intervalSeconds: TimeInterval, prompt: String)
  case stop
}

public enum AgentComposerSubmission: Sendable, Equatable {
  case prompt(String)
  case help
  case goal(AgentGoalCommand)
  case loop(AgentLoopCommand)
  case invalid(String)
}

/// Parses only leading slash commands. `//` is the explicit escape for sending a literal slash.
public enum AgentSlashCommandParser {
  public static let defaultLoopInterval: TimeInterval = 5 * 60
  public static let minimumLoopInterval: TimeInterval = 10
  public static let maximumLoopInterval: TimeInterval = 24 * 60 * 60

  public static func isCommand(_ source: String) -> Bool {
    switch parse(source) {
    case .prompt: false
    case .help, .goal, .loop, .invalid: true
    }
  }

  public static func parse(_ source: String) -> AgentComposerSubmission {
    guard let verbatim = verbatim(source) else {
      return .invalid("Enter a prompt or slash command.")
    }
    let leadingCount = verbatim.prefix(while: { $0.isWhitespace }).count
    let leading = verbatim.prefix(leadingCount)
    let body = verbatim.dropFirst(leadingCount)
    guard body.first == "/" else { return .prompt(verbatim) }
    if body.hasPrefix("//") {
      return .prompt(String(leading) + String(body.dropFirst()))
    }

    let commandLine = body.dropFirst()
    let name = commandLine.prefix(while: { !$0.isWhitespace }).lowercased()
    let rawArguments = commandLine.dropFirst(name.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch name {
    case "help", "commands":
      guard rawArguments.isEmpty else {
        return .invalid("Usage: /help")
      }
      return .help
    case "goal":
      return parseGoal(rawArguments)
    case "loop":
      return parseLoop(rawArguments)
    case "":
      return .help
    default:
      return .invalid("Unknown command /\(name). Type /help to see Otto commands.")
    }
  }

  private static func parseGoal(_ arguments: String) -> AgentComposerSubmission {
    guard !arguments.isEmpty else { return .goal(.show) }
    let first = arguments.prefix(while: { !$0.isWhitespace }).lowercased()
    let remainder = arguments.dropFirst(first.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    switch first {
    case "pause" where remainder.isEmpty: return .goal(.pause)
    case "resume" where remainder.isEmpty: return .goal(.resume)
    case "complete" where remainder.isEmpty: return .goal(.complete)
    case "clear" where remainder.isEmpty: return .goal(.clear)
    case "edit":
      guard let objective = normalizedArgument(remainder), objective.count <= 4_000 else {
        return .invalid("Usage: /goal edit <objective> (maximum 4,000 characters)")
      }
      return .goal(.set(objective))
    default:
      guard let objective = normalizedArgument(arguments), objective.count <= 4_000 else {
        return .invalid("Usage: /goal <objective> (maximum 4,000 characters)")
      }
      return .goal(.set(objective))
    }
  }

  private static func parseLoop(_ arguments: String) -> AgentComposerSubmission {
    guard !arguments.isEmpty else { return .loop(.show) }
    if arguments.lowercased() == "stop" { return .loop(.stop) }

    let first = String(arguments.prefix(while: { !$0.isWhitespace }))
    let parsedInterval = interval(from: first)
    let rawPrompt: String
    let intervalSeconds: TimeInterval
    if let parsedInterval {
      intervalSeconds = parsedInterval
      rawPrompt = arguments.dropFirst(first.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
      intervalSeconds = defaultLoopInterval
      rawPrompt = arguments
    }
    guard (minimumLoopInterval...maximumLoopInterval).contains(intervalSeconds) else {
      return .invalid("Loop interval must be between 10s and 24h.")
    }
    guard let prompt = normalizedArgument(rawPrompt) else {
      return .invalid("Usage: /loop [10s|5m|1h] <prompt>")
    }
    return .loop(.start(intervalSeconds: intervalSeconds, prompt: prompt))
  }

  private static func interval(from token: String) -> TimeInterval? {
    guard let suffix = token.last?.lowercased(), ["s", "m", "h"].contains(suffix) else {
      return nil
    }
    guard let value = Double(token.dropLast()), value.isFinite, value > 0 else { return nil }
    switch suffix {
    case "s": return value
    case "m": return value * 60
    case "h": return value * 60 * 60
    default: return nil
    }
  }

  private static func normalizedArgument<S: StringProtocol>(_ source: S) -> String? {
    var value = String(source).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if value.count >= 2,
      let first = value.first,
      let last = value.last,
      (first == "\"" && last == "\"") || (first == "'" && last == "'")
    {
      value.removeFirst()
      value.removeLast()
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func verbatim(_ source: String) -> String? {
    source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : source
  }
}

private struct PersistedAgentCommands: Codable {
  var goals: [String: AgentGoal] = [:]
  var loops: [String: AgentLoop] = [:]
}

/// Small workspace-local persistence store. It deliberately contains objectives and prompts only,
/// never provider credentials or permission grants.
@MainActor
public final class AgentCommandStateStore {
  private let fileURL: URL
  private var persisted: PersistedAgentCommands

  public init(workspacePath: String) {
    fileURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
      .appending(path: ".otto/agent-commands.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let data = try? Data(contentsOf: fileURL),
      let decoded = try? decoder.decode(PersistedAgentCommands.self, from: data)
    {
      persisted = decoded
    } else {
      persisted = PersistedAgentCommands()
    }
  }

  public func goal(for agentID: UUID) -> AgentGoal? {
    persisted.goals[agentID.uuidString]
  }

  public func setGoal(_ goal: AgentGoal?, for agentID: UUID) throws {
    persisted.goals[agentID.uuidString] = goal
    try save()
  }

  public func loop(for agentID: UUID) -> AgentLoop? {
    persisted.loops[agentID.uuidString]
  }

  public func setLoop(_ loop: AgentLoop?, for agentID: UUID) throws {
    persisted.loops[agentID.uuidString] = loop
    try save()
  }

  public func enabledLoops() -> [(UUID, AgentLoop)] {
    persisted.loops.compactMap { key, value in
      guard value.isEnabled, let id = UUID(uuidString: key) else { return nil }
      return (id, value)
    }
  }

  private func save() throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(persisted).write(to: fileURL, options: .atomic)
  }
}

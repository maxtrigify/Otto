import Foundation

/// A reusable identity and set of defaults for launching an agent. Runtime infrastructure does
/// not require a profile: ordinary provider nodes continue to use AgentDefinition directly.
public struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var id: UUID
  public var name: String
  public var role: String
  /// Short role line shown in the fleet roster. Distinct from `instructions` (the operating
  /// prompt) and from `role` (longer description). Changing this revises the profile.
  public var jobTitle: String?
  public var instructions: String
  public var provider: AgentProvider
  /// Local provider account for new sessions; nil inherits the workspace default.
  public var accountID: UUID?
  /// Local, user-approved helpers. Absent in older profiles.
  public var subagents: [BotSubagentConfiguration]? = nil
  public var model: String?
  public var effort: String?
  /// Raw AgentPermissionMode value. Kept in OttoModels so the model layer does not depend on
  /// OttoRuntime; launch-time validation converts it to the runtime enum.
  public var permissionMode: String
  public var executionStrategy: AgentExecutionStrategy
  public var isolatedWorktree: Bool
  public var skillIDs: [String]
  public var revision: Int
  public var schemaVersion: Int
  public var createdAt: Date
  public var updatedAt: Date
  public var archivedAt: Date?

  public init(
    id: UUID = UUID(),
    name: String,
    role: String = "",
    jobTitle: String? = nil,
    instructions: String,
    provider: AgentProvider,
    accountID: UUID? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String = "workspaceWrite",
    executionStrategy: AgentExecutionStrategy = .direct,
    isolatedWorktree: Bool = false,
    skillIDs: [String] = [],
    revision: Int = 1,
    schemaVersion: Int = AgentProfile.currentSchemaVersion,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    archivedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.jobTitle = jobTitle
    self.instructions = instructions
    self.provider = provider
    self.accountID = accountID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.executionStrategy = executionStrategy
    self.isolatedWorktree = isolatedWorktree
    self.skillIDs = skillIDs
    self.revision = revision
    self.schemaVersion = schemaVersion
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.archivedAt = archivedAt
  }

  public var isArchived: Bool { archivedAt != nil }

  /// Stable @handle derived from the display name. Used for attribution and mention resolution.
  public var handle: String {
    Self.handle(from: name)
  }

  public static func handle(from name: String) -> String {
    let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    var result = ""
    for character in folded {
      if character.isLetter || character.isNumber {
        result.append(character)
      }
    }
    return result.isEmpty ? "bot" : result
  }
}

public enum AgentProfileValidationError: Error, LocalizedError, Equatable, Sendable {
  case emptyName
  case nameTooLong
  case jobTitleTooLong
  case emptyInstructions
  case duplicateName
  case unsupportedProvider
  case unsupportedExecutionStrategy

  public var errorDescription: String? {
    switch self {
    case .emptyName: "Give the agent a name."
    case .nameTooLong: "Agent names must be 80 characters or fewer."
    case .jobTitleTooLong: "Job titles must be 80 characters or fewer."
    case .emptyInstructions: "Add instructions describing how this agent should work."
    case .duplicateName: "An agent with this name already exists."
    case .unsupportedProvider: "Custom bots need a coding-agent harness, not a shell."
    case .unsupportedExecutionStrategy: "This execution strategy is unavailable for the harness."
    }
  }
}

/// A helper's billing account is always explicit; never inherit a machine default.
public struct BotSubagentConfiguration: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var role: String
  public var provider: AgentProvider
  /// Nil explicitly selects this Mac’s provider login, never inherited defaults.
  public var accountID: UUID?
  public var model: String?

  public init(
    id: UUID = UUID(), name: String, role: String = "", provider: AgentProvider = .codex,
    accountID: UUID? = nil, model: String? = nil
  ) {
    self.id = id
    self.name = name
    self.role = role
    self.provider = provider
    self.accountID = accountID
    self.model = model
  }
}

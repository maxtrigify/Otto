import Combine
import Foundation
import OttoModels

/// Project selection is separate from channel identity, transcripts and working directories.
@MainActor
public final class ConversationProjectStore: ObservableObject {
  public struct Run: Codable, Equatable, Sendable {
    public var nodeID: UUID
    public var channelID: UUID
    public var context: ConversationProjectContext
    public var startedAt: Date
    public var resolved: Bool
  }
  private struct State: Codable {
    var projects: [ConversationProject] = []
    var selections: [UUID: UUID] = [:]
    var runs: [Run] = []
    var sessionsMigrated: Bool?
    var unassignedChannels: Set<UUID>? = []
  }
  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  public var projects: [ConversationProject] { state.projects }

  public init(
    workspacePath: String, existingChannelIDs: [UUID] = [], existingSessionIDs: [UUID] = []
  ) {
    fileURL = URL(fileURLWithPath: workspacePath).appending(
      path: ".otto/conversation-projects.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: .default) {
        state = saved
        if state.unassignedChannels == nil {
          // Old files encoded both "never chosen" and explicit clears as absent selections.
          // Preserve unassigned existing chats; only newly created chats adopt the default.
          let known =
            existingChannelIDs + (state.sessionsMigrated == true ? existingSessionIDs : [])
          var migrated = state
          migrated.unassignedChannels = Set(known.filter { state.selections[$0] == nil })
          try persist(migrated)
        }
      } else {
        let legacy = ConversationProject(
          name: URL(fileURLWithPath: workspacePath).lastPathComponent, isLegacyWorkspace: true)
        state.projects = [legacy]
        state.selections = Dictionary(
          uniqueKeysWithValues: existingChannelIDs.map { ($0, legacy.id) })
        try persist(state)
      }
      if state.sessionsMigrated != true {
        var next = state
        if let legacy = next.projects.first(where: { $0.isLegacyWorkspace }) {
          for id in existingSessionIDs where next.selections[id] == nil {
            next.selections[id] = legacy.id
          }
        }
        next.sessionsMigrated = true
        try persist(next)
      }
    } catch { persistenceError = error.localizedDescription }
  }

  public func context(channelID: UUID) -> ConversationProjectContext {
    if state.unassignedChannels?.contains(channelID) == true { return ConversationProjectContext() }
    let selected = state.selections[channelID]
    guard
      let project = selected.flatMap({ id in projects.first { $0.id == id } })
        ?? (selected == nil ? projects.first { $0.isLegacyWorkspace } : nil)
    else { return ConversationProjectContext() }
    return ConversationProjectContext(
      projectID: project.id, name: project.name, sourceFolders: project.sourceFolders)
  }

  @discardableResult public func create(name: String, sourceFolders: [String] = []) throws
    -> ConversationProject
  {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 100 else { throw ProjectError.invalidName }
    guard !projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
      throw ProjectError.ambiguous
    }
    var folders: [String] = []
    for path in sourceFolders {
      guard path.hasPrefix("/") else { throw ProjectError.invalidFolder }
      let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: normalized, isDirectory: &directory),
        directory.boolValue
      else { throw ProjectError.invalidFolder }
      if !folders.contains(normalized) { folders.append(normalized) }
    }
    let project = ConversationProject(name: name, sourceFolders: folders)
    var next = state
    next.projects.append(project)
    try persist(next)
    return project
  }

  public func resolve(name: String) throws -> ConversationProject {
    let matches = projects.filter {
      $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines))
        == .orderedSame
    }
    guard matches.count == 1 else { throw ProjectError.ambiguous }
    return matches[0]
  }

  public func select(channelID: UUID, projectID: UUID?) throws {
    guard projectID == nil || projects.contains(where: { $0.id == projectID }) else {
      throw ProjectError.unknownProject
    }
    var next = state
    next.selections[channelID] = projectID
    var unassigned = next.unassignedChannels ?? []
    if projectID == nil { unassigned.insert(channelID) } else { unassigned.remove(channelID) }
    next.unassignedChannels = unassigned
    try persist(next)
  }

  /// The provider account new work in this project runs on. Nil falls back to the global default.
  public func setDefaultAccount(projectID: UUID, accountID: UUID?) throws {
    guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
      throw ProjectError.unknownProject
    }
    var next = state
    next.projects[index].defaultAccountID = accountID
    try persist(next)
  }

  /// What the project does when a run hits its account's usage limit.
  public func setUsageLimitPolicy(
    projectID: UUID, policy: ProviderUsageLimitPolicy, fallbackAccountID: UUID?
  ) throws {
    guard let index = state.projects.firstIndex(where: { $0.id == projectID }) else {
      throw ProjectError.unknownProject
    }
    var next = state
    next.projects[index].usageLimitPolicy = policy
    next.projects[index].usageLimitFallbackAccountID = fallbackAccountID
    try persist(next)
  }

  /// The project a session or bot channel is currently assigned to, if any.
  public func project(channelID: UUID) -> ConversationProject? {
    guard let id = state.selections[channelID] else { return nil }
    return projects.first { $0.id == id }
  }

  @discardableResult public func capture(
    nodeID: UUID, channelID: UUID, context: ConversationProjectContext? = nil, at: Date = .now
  ) throws -> Run {
    let scope = context ?? self.context(channelID: channelID)
    let run = Run(
      nodeID: nodeID, channelID: channelID, context: scope, startedAt: at,
      resolved: scope.projectID != nil)
    var next = state
    next.runs.append(run)
    try persist(next)
    return run
  }

  public func run(nodeID: UUID) -> Run? { state.runs.last { $0.nodeID == nodeID } }

  /// A previously unassigned turn may explicitly resolve its scope once. UI changes never call this.
  public func resolveUnassignedRun(nodeID: UUID, context: ConversationProjectContext) throws {
    guard let index = state.runs.lastIndex(where: { $0.nodeID == nodeID }),
      !state.runs[index].resolved
    else { return }
    var next = state
    next.runs[index].context = context
    next.runs[index].resolved = true
    try persist(next)
  }

  public func attribution(nodeID: UUID, at date: Date) -> String {
    state.runs.last { $0.nodeID == nodeID && $0.startedAt <= date }?.context.attribution
      ?? "[Project: legacy workspace history; attribution not recorded]"
  }

  private func persist(_ next: State) throws {
    // Do not replace unreadable state with defaults.
    if let persistenceError { throw ProjectError.unavailable(persistenceError) }
    do {
      try WorkspaceJSONFile.save(next, to: fileURL, fileManager: .default)
      state = next
    } catch {
      persistenceError = error.localizedDescription
      throw error
    }
  }

  public enum ProjectError: Error, LocalizedError {
    case invalidName, ambiguous, unknownProject, invalidFolder
    case unavailable(String)
    public var errorDescription: String? {
      switch self {
      case .invalidFolder: "Choose an existing folder on this computer."
      case .invalidName: "Use a project name of 1–100 characters."
      case .ambiguous:
        "Project selection is ambiguous or not an exact match. Ask the user which project; use its ID."
      case .unknownProject: "Unknown project."
      case .unavailable(let message): "Project context could not be loaded: \(message)"
      }
    }
  }
}

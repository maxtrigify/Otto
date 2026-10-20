import Foundation
import OttoApplicationTools
import OttoMemory
import OttoModels
import OttoTools

public struct ConversationProjectInput: Codable, Sendable {
  public var action: String
  public var projectID: UUID?
  public var name: String?
  public var channelID: UUID?
  public var sourceFolders: [String]?
  public init(
    action: String, projectID: UUID? = nil, name: String? = nil, channelID: UUID? = nil,
    sourceFolders: [String]? = nil
  ) {
    self.action = action
    self.projectID = projectID
    self.name = name
    self.channelID = channelID
    self.sourceFolders = sourceFolders
  }
}
public struct ConversationProjectOutput: Codable, Sendable {
  public var projects: [ConversationProject]
  public var active: ConversationProjectContext
  public var assignment: ConversationProjectContext?
  public var note: String
}
public struct ConversationProjectTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "project.context",
    description:
      "Lists, selects, clears or creates an optional project in the bot chat, team room or session. List first; choose only when the request clearly identifies the project. Ask the user when several fit. Casual chat needs no project. Selecting does not change permissions, directory or history. A bound assignment keeps its original project; selection then applies to future work.",
    inputSchema: .objectSchema(
      properties: [
        "action": .stringSchema(description: "list, select, clear, or create"),
        "projectID": .stringSchema(description: "Exact project ID for select"),
        "name": .stringSchema(description: "Exact project name for select or new name for create"),
        "sourceFolders": .object([
          "type": .string("array"), "items": .object(["type": .string("string")]),
          "description": .string(
            "Optional existing absolute source folder paths for create. Does not change working directory or permissions."
          ),
        ]),
        "channelID": .stringSchema(description: "UI/control-plane only; agents use their own room"),
      ], required: ["action"]), outputSchema: .objectSchema(),
    requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler:
    @Sendable (ConversationProjectInput, ToolContext) async throws -> ConversationProjectOutput
  public init(
    handler:
      @escaping @Sendable (ConversationProjectInput, ToolContext) async throws ->
      ConversationProjectOutput
  ) { self.handler = handler }
  public func call(_ input: ConversationProjectInput, context: ToolContext) async throws
    -> ConversationProjectOutput
  { try await handler(input, context) }
}

extension ApplicationServices {
  public func projectChannel(nodeID: UUID) -> UUID? {
    teamChannelID(runtimeID: nodeID)
      ?? botChannels.channels.first {
        $0.kind == .botChannel && $0.nodeID == nodeID && !$0.archived
      }?.id
      ?? store.snapshot.canvases.lazy.flatMap(\.nodes)
      .first(where: { $0.id == nodeID && $0.kind == .agent })?.id
  }

  public func selectProject(channelID: UUID, projectID: UUID?) throws {
    guard
      botChannels.channel(id: channelID)?.archived == false
        || (botChannels.channel(id: channelID) == nil
          && store.snapshot.canvases.lazy.flatMap(\.nodes).contains {
            $0.id == channelID && $0.kind == .agent
          })
    else {
      throw BotStoreError.channelArchived
    }
    try conversationProjects.select(channelID: channelID, projectID: projectID)
    objectWillChange.send()
  }

  func projectContextAction(_ input: ConversationProjectInput, context: ToolContext) throws
    -> ConversationProjectOutput
  {
    let isAgent = context.source == .agent || context.source == .automation
    let channelID: UUID?
    if isAgent {
      guard input.channelID == nil, let node = context.sourceNodeID else {
        throw ToolRegistryError.invalidInput(
          "Project context requires an authenticated agent caller.")
      }
      channelID = projectChannel(nodeID: node)
    } else {
      channelID = input.channelID ?? context.sourceNodeID.flatMap { projectChannel(nodeID: $0) }
    }
    guard let channelID else {
      throw ToolRegistryError.invalidInput(
        "Choose a bot chat, team room or session.")
    }
    switch input.action {
    case "list": break
    case "clear": try selectProject(channelID: channelID, projectID: nil)
    case "select":
      let id = try input.projectID ?? conversationProjects.resolve(name: input.name ?? "").id
      try selectProject(channelID: channelID, projectID: id)
    case "create":
      let project = try conversationProjects.create(
        name: input.name ?? "", sourceFolders: input.sourceFolders ?? [])
      try selectProject(channelID: channelID, projectID: project.id)
    default: throw ToolRegistryError.invalidInput("Expected list, select, clear or create.")
    }
    let active = conversationProjects.context(channelID: channelID)
    if isAgent, input.action != "list", let node = context.sourceNodeID {
      try conversationProjects.resolveUnassignedRun(nodeID: node, context: active)
    }
    return ConversationProjectOutput(
      projects: conversationProjects.projects, active: active,
      assignment: context.sourceNodeID.flatMap { conversationProjects.run(nodeID: $0)?.context },
      note:
        "History is retained, including earlier projects. Working directory and permissions are unchanged. Already bound work stays in its original project."
    )
  }

  func resolvedProjectContext(nodeID: UUID) -> ConversationProjectContext? {
    if conversationProjects.persistenceError != nil {
      return ConversationProjectContext(name: "Unavailable — project state needs repair")
    }
    if let run = conversationProjects.run(nodeID: nodeID) { return run.context }
    guard let channel = projectChannel(nodeID: nodeID) else { return nil }
    return conversationProjects.context(channelID: channel)
  }

  func brainForProject(_ context: ConversationProjectContext) throws -> ProjectBrainStore? {
    guard let id = context.projectID else { return nil }
    guard let project = conversationProjects.projects.first(where: { $0.id == id }) else {
      throw ConversationProjectStore.ProjectError.unknownProject
    }
    if project.isLegacyWorkspace { return brain }
    if let existing = conversationProjectBrains[id] { return existing }
    let created = try ProjectBrainStore(
      rootPath: URL(fileURLWithPath: workspacePath).appending(
        path: ".otto/projects/\(id.uuidString)/brain"
      ).path,
      project: project.name)
    conversationProjectBrains[id] = created
    return created
  }

  func scopedBrain(context: ToolContext) throws -> ProjectBrainStore {
    if let error = conversationProjects.persistenceError {
      throw ConversationProjectStore.ProjectError.unavailable(error)
    }
    if let node = context.sourceNodeID, let scope = resolvedProjectContext(nodeID: node) {
      guard let selected = try brainForProject(scope) else {
        throw ToolRegistryError.invalidInput(
          "This assignment is unassigned. Resolve a project explicitly with project.context before using project memory."
        )
      }
      return selected
    }
    // Existing session/control-plane behavior stays workspace-scoped.
    guard let brain else { throw ToolRegistryError.invalidInput("Project memory is unavailable.") }
    return brain
  }
}

extension ApplicationServices {
  func scopedDocumentPath(_ path: String, context: ToolContext, creating: Bool) throws -> String {
    if let error = conversationProjects.persistenceError {
      throw ConversationProjectStore.ProjectError.unavailable(error)
    }
    guard let node = context.sourceNodeID, let scope = resolvedProjectContext(nodeID: node) else {
      return path
    }
    let prefix: String
    if let id = scope.projectID {
      if conversationProjects.projects.first(where: { $0.id == id })?.isLegacyWorkspace == true {
        let resolved = URL(fileURLWithPath: workspacePath).appending(path: path)
          .resolvingSymlinksInPath().standardizedFileURL.path
        let root = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL
          .path
        guard !path.hasPrefix("Projects/"), !path.hasPrefix("Unassigned/"),
          !resolved.hasPrefix(root + "/Projects/"), !resolved.hasPrefix(root + "/Unassigned/")
        else {
          throw ToolRegistryError.invalidInput("Document belongs to another project.")
        }
        return path
      }
      prefix = "Projects/\(id.uuidString)/"
    } else {
      prefix = "Unassigned/"
    }
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      throw ToolRegistryError.invalidInput("Use a relative path within this assignment's project.")
    }
    if path.hasPrefix(prefix) {
      let root = URL(fileURLWithPath: workspacePath).appending(path: prefix).standardizedFileURL
      let resolved = URL(fileURLWithPath: workspacePath).appending(path: path)
        .resolvingSymlinksInPath().standardizedFileURL
      guard resolved.path.hasPrefix(root.path + "/") else {
        throw ToolRegistryError.invalidInput("Document resolves outside its project.")
      }
      return path
    }
    if creating, !path.hasPrefix("Projects/"), !path.hasPrefix("Unassigned/") {
      return try scopedDocumentPath(prefix + path, context: context, creating: false)
    }
    throw ToolRegistryError.invalidInput(
      "Document is outside this assignment's project (\(scope.name)).")
  }

  public func runningProjectDescription(channelID: UUID) -> String? {
    let node =
      activeTeamRuntimeID(channelID: channelID)
      ?? botChannels.channel(id: channelID)?.nodeID
      ?? store.snapshot.canvases.lazy.flatMap(\.nodes).first(where: { $0.id == channelID })?.id
    guard let node, let run = conversationProjects.run(nodeID: node),
      isTeamRunning(channelID: channelID) || fleet[node]?.state == .working,
      run.context != conversationProjects.context(channelID: channelID)
    else { return nil }
    return "Running task: \(run.context.name)"
  }
}

extension ApplicationServices {
  func projectBootstrapBuilder(nodeID: UUID) -> AgentMemoryBootstrapBuilder {
    projectBootstrapBuilder(context: resolvedProjectContext(nodeID: nodeID))
  }
  func projectBootstrapBuilder(context: ConversationProjectContext?) -> AgentMemoryBootstrapBuilder
  {
    let path: String
    if let context {
      if let id = context.projectID,
        conversationProjects.projects.first(where: { $0.id == id })?.isLegacyWorkspace == false
      {
        path =
          URL(fileURLWithPath: workspacePath).appending(
            path: ".otto/projects/\(id.uuidString)/brain"
          ).path
      } else if context.projectID == nil {
        path = "No active project. Resolve with project.context before using project memory."
      } else {
        path = URL(fileURLWithPath: workspacePath).appending(path: ".otto/brain").path
      }
    } else {
      path = URL(fileURLWithPath: workspacePath).appending(path: ".otto/brain").path
    }
    return AgentMemoryBootstrapBuilder(
      project: context?.name ?? URL(fileURLWithPath: workspacePath).lastPathComponent,
      brainPath: path,
      projectCharterPath: URL(fileURLWithPath: workspacePath).appending(path: ".otto/charter.md")
        .path,
      profileContext: profileBootstrapText)
  }
}

public struct ConversationProjectListTool: OttoTool {
  public struct Input: Codable, Sendable { public init() {} }
  public static let definition = ToolDefinition(
    name: "project.list",
    description:
      "Lists optional projects and this bot/team assignment's captured context. Ask the user when multiple projects fit; do not guess from partial names.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.canvasRead],
    riskLevel: .read)
  private let handler:
    @Sendable (ConversationProjectInput, ToolContext) async throws -> ConversationProjectOutput
  public init(
    handler:
      @escaping @Sendable (ConversationProjectInput, ToolContext) async throws ->
      ConversationProjectOutput
  ) { self.handler = handler }
  public func call(_ input: Input, context: ToolContext) async throws -> ConversationProjectOutput {
    try await handler(ConversationProjectInput(action: "list"), context)
  }
}

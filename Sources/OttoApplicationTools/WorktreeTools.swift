import Foundation
import OttoTools
import OttoWorktrees

public struct WorktreeNodeInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct WorktreeDiffOutput: Codable, Sendable, Equatable {
  public var nodeID: UUID
  public var branch: String
  public var diff: String
}

public struct WorktreeCleanupOutput: Codable, Sendable, Equatable {
  public var nodeID: UUID
  public var branch: String
  public var message: String
}

public struct WorktreeIntegrateOutput: Codable, Sendable, Equatable {
  public var nodeID: UUID
  public var branch: String
  public var commits: [String]
  public var repositoryHead: String
  public var message: String
}

public struct WorktreeStatusTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "worktree.status",
    description: "Returns branch, path, dirty state, changed-file count, and bounded diff stat.",
    inputSchema: worktreeNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )
  private let manager: GitWorktreeManager
  private let sessions: WorktreeSessionStore
  public init(manager: GitWorktreeManager, sessions: WorktreeSessionStore) {
    self.manager = manager
    self.sessions = sessions
  }
  public func call(_ input: WorktreeNodeInput, context: ToolContext) async throws -> WorktreeStatus
  {
    let handle = try await requiredHandle(input.nodeID, sessions: sessions)
    return try await manager.status(handle)
  }
}

public struct WorktreeDiffTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "worktree.diff",
    description: "Returns the bounded uncommitted diff for an isolated agent worktree.",
    inputSchema: worktreeNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentRead],
    riskLevel: .read
  )
  private let manager: GitWorktreeManager
  private let sessions: WorktreeSessionStore
  public init(manager: GitWorktreeManager, sessions: WorktreeSessionStore) {
    self.manager = manager
    self.sessions = sessions
  }
  public func call(_ input: WorktreeNodeInput, context: ToolContext) async throws
    -> WorktreeDiffOutput
  {
    let handle = try await requiredHandle(input.nodeID, sessions: sessions)
    return WorktreeDiffOutput(
      nodeID: input.nodeID,
      branch: handle.branch,
      diff: try await manager.diff(handle)
    )
  }
}

public struct WorktreeCleanupTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "worktree.cleanup",
    description: "Removes a clean isolated worktree; dirty worktrees are always retained.",
    inputSchema: worktreeNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.globalDestructive],
    riskLevel: .destructive,
    requiresConfirmation: true
  )
  private let manager: GitWorktreeManager
  private let sessions: WorktreeSessionStore
  public init(manager: GitWorktreeManager, sessions: WorktreeSessionStore) {
    self.manager = manager
    self.sessions = sessions
  }
  public func call(_ input: WorktreeNodeInput, context: ToolContext) async throws
    -> WorktreeCleanupOutput
  {
    let handle = try await requiredHandle(input.nodeID, sessions: sessions)
    try await manager.cleanup(handle)
    await sessions.remove(nodeID: input.nodeID)
    return WorktreeCleanupOutput(
      nodeID: input.nodeID,
      branch: handle.branch,
      message: "Removed clean worktree \(handle.branch)"
    )
  }
}

public struct WorktreeIntegrateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "worktree.integrate",
    description:
      "Integrates committed work from an isolated agent worktree into the active repository. Both checkouts must be clean; conflicts are aborted without leaving the repository mid-cherry-pick.",
    inputSchema: worktreeNodeSchema(),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.agentControl],
    riskLevel: .consequential
  )
  private let manager: GitWorktreeManager
  private let sessions: WorktreeSessionStore
  public init(manager: GitWorktreeManager, sessions: WorktreeSessionStore) {
    self.manager = manager
    self.sessions = sessions
  }
  public func call(_ input: WorktreeNodeInput, context: ToolContext) async throws
    -> WorktreeIntegrateOutput
  {
    if context.source == .agent, context.sourceNodeID != input.nodeID {
      throw ToolRegistryError.invalidInput(
        "An agent can only integrate its own isolated worktree")
    }
    let handle = try await requiredHandle(input.nodeID, sessions: sessions)
    let result = try await manager.integrate(handle)
    return WorktreeIntegrateOutput(
      nodeID: input.nodeID,
      branch: handle.branch,
      commits: result.commits,
      repositoryHead: result.repositoryHead,
      message:
        "Integrated \(result.commits.count) commit\(result.commits.count == 1 ? "" : "s") from \(handle.branch)"
    )
  }
}

private func worktreeNodeSchema() -> JSONValue {
  .objectSchema(
    properties: ["nodeID": .stringSchema(description: "Stable agent node UUID")],
    required: ["nodeID"]
  )
}

private func requiredHandle(_ nodeID: UUID, sessions: WorktreeSessionStore) async throws
  -> WorktreeHandle
{
  guard let handle = await sessions.handle(for: nodeID) else {
    throw ToolRegistryError.invalidInput("Agent node has no isolated worktree")
  }
  return handle
}

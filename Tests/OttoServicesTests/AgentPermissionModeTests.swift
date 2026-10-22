import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoServices
import Testing

@MainActor
@Suite("Conversation permission persistence")
struct AgentPermissionModeTests {
  @Test("Only canonical bot conversations update the saved bot policy", arguments: [false, true])
  func savesAtCorrectScope(canonical: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-permissions-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Permissions")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    let profile = try services.saveAgentProfile(
      AgentProfile(name: "Test", instructions: "Test permissions", provider: .claudeCode))
    let nodeID = try #require(
      store.dispatch(
        .createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))
      ).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .claudeCode, workingDirectory: root.path, launchCommand: "claude",
          permissionMode: AgentPermissionMode.workspaceWrite.rawValue, profileID: profile.id)))
    if canonical { _ = try services.botChannels.bindNode(profileID: profile.id, nodeID: nodeID) }

    _ = try await services.supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh", arguments: ["-c", "sleep 20"],
        workingDirectory: root.path),
      id: nodeID, parser: .claude(ClaudeOutputParser()), initialState: .working,
      executionMode: .oneShotProvider)
    let approval = Task {
      try await services.supervisor.requestPermission(
        agentID: nodeID, toolName: "Write", isProviderPermission: true)
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while await !services.supervisor.hasPendingPermission(agentID: nodeID),
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await services.supervisor.hasPendingPermission(agentID: nodeID))
    await services.alwaysAllowAgentPermission(agentID: nodeID)
    #expect(try await approval.value)
    #expect(services.errorMessage == nil)
    #expect(
      try await services.supervisor.requestPermission(
        agentID: nodeID, toolName: "Bash", isProviderPermission: true))
    #expect(
      store.activeCanvas.nodes.first(where: { $0.id == nodeID })?
        .agentDefinition?.permissionMode == AgentPermissionMode.unrestricted.rawValue)
    let reloaded = AgentProfileStore(workspacePath: root.path)
    #expect(
      reloaded.profile(id: profile.id)?.permissionMode
        == (canonical ? AgentPermissionMode.unrestricted.rawValue : profile.permissionMode))

    try await services.setAgentPermissionMode(.workspaceWrite, agentID: nodeID)
    try await services.supervisor.stop(agentID: nodeID)
    #expect(
      store.activeCanvas.nodes.first(where: { $0.id == nodeID })?
        .agentDefinition?.permissionMode == AgentPermissionMode.workspaceWrite.rawValue)
  }
}

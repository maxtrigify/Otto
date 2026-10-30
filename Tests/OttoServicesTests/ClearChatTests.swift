import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

@MainActor
@Suite("Clearing a chat", .serialized)
struct ClearChatTests {
  @Test("Clearing stops a running bot and forgets its messages and every session it would resume")
  func clearsEverythingTheNextTurnWouldResume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-clear-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Clear tests")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let services = ApplicationServices(
      store: store, supervisor: supervisor, secrets: InMemorySecretStore(),
      workspacePath: root.path)

    let profile = try services.saveAgentProfile(
      AgentProfile(name: "Mona", instructions: "Test", provider: .codex))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    var definition = AgentDefinition(
      provider: .codex, workingDirectory: root.path, launchCommand: "codex",
      permissionMode: "workspaceWrite")
    definition.profileID = profile.id
    definition.resumeSessionID = "session-1"
    store.dispatch(.setAgentDefinition(id: nodeID, definition: definition))
    try services.botChannels.bindNode(profileID: profile.id, nodeID: nodeID)
    try services.botChannels.recordProviderSession(
      profileID: profile.id, nodeID: nodeID, sessionID: "session-1")

    // A provider that answers once and then keeps running, like an interactive session.
    let script = """
      echo '{"type":"thread.started","thread_id":"session-1"}'
      echo '{"type":"item.completed","item":{"type":"agent_message","text":"Earlier answer"}}'
      echo '{"type":"turn.completed"}'
      exec sleep 30
      """
    _ = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh", arguments: ["-c", script], workingDirectory: root.path),
      id: nodeID, parser: .codex(CodexOutputParser()))
    for _ in 0..<100 {
      if (try? await supervisor.snapshot(agentID: nodeID))?.transcript.isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try await supervisor.snapshot(agentID: nodeID).transcript.isEmpty == false)

    try await services.clearChat(nodeID: nodeID)

    let cleared = try await supervisor.snapshot(agentID: nodeID)
    #expect(cleared.exitCode != nil)
    #expect(cleared.transcript.isEmpty)
    #expect(cleared.result == nil)
    #expect(cleared.providerSessionID == nil)
    #expect(services.fleet[nodeID]?.transcript.isEmpty ?? true)
    let node = try #require(store.activeCanvas.nodes.first { $0.id == nodeID })
    #expect(node.agentDefinition?.resumeSessionID == nil)
    #expect(node.agentDefinition?.profileID == profile.id)
    #expect(services.botChannels.canonicalChannel(for: profile.id)?.providerSessionID == nil)
    #expect(services.agentProfiles.profile(id: profile.id) != nil)
  }
}

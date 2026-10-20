import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Home conversations")
struct HomeConversationTests {
  private func agent(id: UUID = UUID(), profileID: UUID? = nil, parentID: UUID? = nil) -> OttoNode {
    OttoNode(
      id: id, kind: .agent, displayName: "Agent", subtitle: "CODEX",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 200), zIndex: 1,
      content: .agent(provider: .codex),
      agentDefinition: AgentDefinition(
        provider: .codex, workingDirectory: "/tmp",
        launchCommand: "codex", permissionMode: "workspaceWrite", profileID: profileID),
      parentAgentID: parentID)
  }

  @Test("Session choices exclude hired bots, canonical bot nodes, and delegated children")
  func sessionIdentityBoundaries() {
    let profileID = UUID()
    let bot = agent(profileID: profileID)
    let legacyBot = agent()
    let session = agent()
    let child = agent(parentID: session.id)
    var unlaunchable = agent()
    unlaunchable.agentDefinition = nil
    let canvas = OttoCanvas(name: "Home", nodes: [bot, legacyBot, session, child, unlaunchable])
    #expect(
      homeSessionNodes(
        canvases: [canvas], botProfileIDs: [profileID],
        botNodeIDs: [legacyBot.id]
      ).map(\.id) == [session.id])
  }

  @Test("An existing bot conversation is reused even on another canvas")
  func canonicalBotAcrossCanvases() {
    let profileID = UUID()
    let canonical = agent(profileID: profileID)
    let duplicate = agent(profileID: profileID)
    let canvases = [
      OttoCanvas(name: "Current", nodes: [duplicate]),
      OttoCanvas(name: "Saved", nodes: [canonical]),
    ]
    #expect(
      existingHomeBotNodeID(
        profileID: profileID, canonicalNodeID: canonical.id,
        canvases: canvases) == canonical.id)
  }

  @Test("Stale or mismatched canonical nodes cannot redirect a bot's message")
  func staleCanonicalBot() {
    let profileID = UUID()
    let wrongBot = agent(profileID: UUID())
    let canvas = OttoCanvas(name: "Home", nodes: [wrongBot])
    #expect(
      existingHomeBotNodeID(
        profileID: profileID, canonicalNodeID: wrongBot.id,
        canvases: [canvas]) == nil)
    #expect(
      existingHomeBotNodeID(
        profileID: profileID, canonicalNodeID: UUID(),
        canvases: [canvas]) == nil)
    #expect(
      existingHomeBotNodeID(
        profileID: profileID, canonicalNodeID: nil,
        canvases: [canvas]) == nil)
  }

  @Test("Bots and sessions keep distinct identities")
  func distinctTargets() {
    let id = UUID()
    #expect(HomeConversationTarget.bot(id) != .session(id))
    #expect(HomeConversationTarget.newSession != .session(id))
  }
}

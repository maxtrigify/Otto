import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Chat focused agent selection")
struct ChatFocusedAgentSelectionTests {
  @Test("Delegated children stay out of sessions and cannot steal Chat focus after restoration")
  func delegatedChildFocus() throws {
    let parentID = UUID()
    let child = OttoNode(
      kind: .agent, displayName: "Research", subtitle: "CODEX",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 150), zIndex: 1,
      parentAgentID: parentID)
    let decoded = try JSONDecoder().decode(OttoNode.self, from: JSONEncoder().encode(child))
    #expect(!decoded.isStandaloneAgent)
    let canvas = OttoCanvas(name: "Session", nodes: [decoded], selectedNodeID: child.id)
    #expect(
      changedChatFocusedAgentTarget(
        previous: [ChatCanvasSelection(canvasID: canvas.id, nodeID: parentID)],
        current: [ChatCanvasSelection(canvasID: canvas.id, nodeID: child.id)],
        canvases: [canvas], hiredProfileIDs: []) == nil)

    // Workspaces written before ownership was introduced continue to expose normal sessions.
    var legacy = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(child)) as? [String: Any])
    legacy.removeValue(forKey: "parentAgentID")
    let legacyNode = try JSONDecoder().decode(
      OttoNode.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(legacyNode.isStandaloneAgent)
  }

  @Test("Hiring a bot clears the previous session before selecting its canonical node")
  func hiredBotSelection() {
    let oldSessionID = UUID()
    let profileID = UUID()
    let nodeID = UUID()
    let current = ChatSurfaceNavigationState(
      selectedAgentID: oldSessionID,
      selectedSessionID: oldSessionID,
      sidebarList: .sessions,
      destination: .files
    )

    let pending = chatNavigationSelectingHiredBot(
      current, profileID: profileID, nodeID: nil)
    #expect(pending.selectedProfileID == profileID)
    #expect(pending.selectedAgentID == nil)
    #expect(pending.selectedSessionID == nil)
    #expect(pending.sidebarList == .bots)
    #expect(pending.destination == .conversation)

    let opened = chatNavigationSelectingHiredBot(
      pending, profileID: profileID, nodeID: nodeID)
    #expect(opened.selectedProfileID == profileID)
    #expect(opened.selectedAgentID == nodeID)
  }

  @Test("A focused one-off agent switches Chat to its session and canvas filter")
  func focusedSession() {
    let firstCanvasID = UUID()
    let secondCanvasID = UUID()
    let sessionID = UUID()
    let session = OttoNode(
      id: sessionID,
      kind: .agent,
      displayName: "Session",
      subtitle: "CODEX · LOCAL",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 150),
      zIndex: 1,
      content: .agent(provider: .codex)
    )
    let canvases = [
      OttoCanvas(id: firstCanvasID, name: "First"),
      OttoCanvas(
        id: secondCanvasID,
        name: "Second",
        nodes: [session],
        selectedNodeID: sessionID
      ),
    ]

    let target = changedChatFocusedAgentTarget(
      previous: [
        ChatCanvasSelection(canvasID: firstCanvasID, nodeID: nil),
        ChatCanvasSelection(canvasID: secondCanvasID, nodeID: nil),
      ],
      current: [
        ChatCanvasSelection(canvasID: firstCanvasID, nodeID: nil),
        ChatCanvasSelection(canvasID: secondCanvasID, nodeID: sessionID),
      ],
      canvases: canvases,
      hiredProfileIDs: []
    )

    #expect(target == .session(canvasID: secondCanvasID, nodeID: sessionID))
  }

  @Test("A focused canonical bot switches Chat to the Bots tab")
  func focusedBot() {
    let canvasID = UUID()
    let profileID = UUID()
    let botID = UUID()
    let bot = OttoNode(
      id: botID,
      kind: .agent,
      displayName: "Bot",
      subtitle: "CODEX · LOCAL",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 150),
      zIndex: 1,
      content: .agent(provider: .codex),
      agentDefinition: AgentDefinition(
        provider: .codex,
        workingDirectory: "/tmp",
        launchCommand: "codex",
        permissionMode: "workspaceWrite",
        profileID: profileID
      )
    )
    let canvas = OttoCanvas(
      id: canvasID,
      name: "Work",
      nodes: [bot],
      selectedNodeID: botID
    )

    let target = changedChatFocusedAgentTarget(
      previous: [ChatCanvasSelection(canvasID: canvasID, nodeID: nil)],
      current: [ChatCanvasSelection(canvasID: canvasID, nodeID: botID)],
      canvases: [canvas],
      hiredProfileIDs: [profileID]
    )

    #expect(target == .bot(profileID: profileID, nodeID: botID))
  }

  @Test("Focusing a non-agent node leaves the Chat conversation alone")
  func ignoresNonAgent() {
    let canvasID = UUID()
    let noteID = UUID()
    let note = OttoNode(
      id: noteID,
      kind: .markdown,
      displayName: "Note",
      subtitle: "MARKDOWN",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 150),
      zIndex: 1,
      content: .markdown(relativePath: "Notes/test.md", text: "Test")
    )
    let canvas = OttoCanvas(
      id: canvasID,
      name: "Work",
      nodes: [note],
      selectedNodeID: noteID
    )

    let target = changedChatFocusedAgentTarget(
      previous: [ChatCanvasSelection(canvasID: canvasID, nodeID: nil)],
      current: [ChatCanvasSelection(canvasID: canvasID, nodeID: noteID)],
      canvases: [canvas],
      hiredProfileIDs: []
    )

    #expect(target == nil)
  }
}

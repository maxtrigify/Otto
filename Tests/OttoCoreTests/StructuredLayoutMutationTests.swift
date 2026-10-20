import Foundation
import OttoCore
import OttoModels
import Testing

@MainActor
@Suite("Structured layout mutations")
struct StructuredLayoutMutationTests {
  @Test("Chat surface preserves the active spatial layout and geometry")
  func chatSurfacePreservesSpatialState() {
    let nodes = [
      OttoNode(
        kind: .agent,
        displayName: "Buz",
        subtitle: "CODEX",
        frame: WorldRect(x: -240, y: 80, width: 520, height: 420),
        zIndex: 0
      ),
      OttoNode(
        kind: .widget,
        displayName: "Runtime",
        subtitle: "WIDGET",
        frame: WorldRect(x: 410, y: -150, width: 300, height: 220),
        zIndex: 1
      ),
    ]
    let canvas = OttoCanvas(name: "Chat", nodes: nodes)
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    store.dispatch(.setLayout(.grid))
    let spatialFrames = store.activeCanvas.nodes.map(\.frame)
    let selectedNodeID = store.activeCanvas.selectedNodeID

    store.setWorkspaceSurface(.chat)

    #expect(store.workspaceSurface == .chat)
    #expect(store.activeCanvas.layoutMode == .grid)
    #expect(store.activeCanvas.nodes.map(\.frame) == spatialFrames)
    #expect(store.activeCanvas.selectedNodeID == selectedNodeID)
  }

  @Test("Chat navigation never disturbs canvas selections or layout")
  func surfaceSelectionsRemainIndependent() {
    let firstNodeID = UUID()
    let secondNodeID = UUID()
    let first = OttoCanvas(
      name: "First",
      nodes: [
        OttoNode(
          id: firstNodeID,
          kind: .markdown,
          displayName: "First note",
          subtitle: "MARKDOWN",
          frame: WorldRect(x: 20, y: 30, width: 400, height: 280),
          zIndex: 0
        )
      ],
      selectedNodeID: firstNodeID,
      layoutMode: .columns
    )
    let second = OttoCanvas(
      name: "Second",
      nodes: [
        OttoNode(
          id: secondNodeID,
          kind: .browser,
          displayName: "Reference",
          subtitle: "BROWSER",
          frame: WorldRect(x: -90, y: 140, width: 700, height: 500),
          zIndex: 0
        )
      ],
      selectedNodeID: secondNodeID,
      layoutMode: .stage
    )
    let profileID = UUID()
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [first, second],
        activeCanvasID: second.id,
        chatNavigation: ChatSurfaceNavigationState(
          selectedProfileID: profileID, sidebarList: .bots)
      ))

    store.setWorkspaceSurface(.chat)
    var chatNavigation = store.snapshot.chatNavigation
    chatNavigation.destination = .routines
    store.updateChatNavigation(chatNavigation)

    #expect(store.workspaceSurface == .chat)
    #expect(store.snapshot.activeCanvasID == second.id)
    #expect(store.activeCanvas.selectedNodeID == secondNodeID)
    #expect(store.activeCanvas.layoutMode == .stage)
    #expect(store.snapshot.chatNavigation.selectedProfileID == profileID)
    #expect(store.snapshot.chatNavigation.destination == .routines)
  }

  @Test("New stage nodes become primary and move the previous node to the sidebar")
  func stageInsertionPromotesNewNode() throws {
    let canvas = OttoCanvas(name: "Stage insertion")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let primaryID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    _ = store.dispatch(.createNode(kind: .terminal, at: WorldPoint(x: 40, y: 40)))
    store.dispatch(.focusNode(primaryID))
    store.dispatch(.setLayout(.stage))

    let newID = try #require(
      store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 9_000, y: 9_000)))
        .affectedNodeIDs.first)

    #expect(store.activeCanvas.selectedNodeID == newID)
    #expect(store.activeCanvas.nodes.first { $0.id == newID }?.frame.width == 760)
    #expect(store.activeCanvas.nodes.first { $0.id == primaryID }?.frame.width == 300)

    store.dispatch(.focusNode(primaryID))
    #expect(store.activeCanvas.nodes.first { $0.id == primaryID }?.frame.width == 760)
    #expect(store.activeCanvas.nodes.first { $0.id == newID }?.frame.width == 300)

    store.dispatch(.focusNode(nil))
    #expect(store.activeCanvas.selectedNodeID == nil)
    #expect(store.activeCanvas.nodes.first { $0.id == primaryID }?.frame.width == 760)
  }

  @Test("Grid insertion and removal recalculate the complete grid")
  func gridMutationsReflow() throws {
    let canvas = OttoCanvas(name: "Grid insertion")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    for index in 0..<3 {
      _ = store.dispatch(
        .createNode(kind: .terminal, at: WorldPoint(x: Double(index * 100), y: 0)))
    }
    store.dispatch(.setLayout(.grid))

    let newID = try #require(
      store.dispatch(.createNode(kind: .markdown, at: WorldPoint(x: 9_000, y: 9_000)))
        .affectedNodeIDs.first)
    let fourNodeFrames = store.activeCanvas.nodes.map(\.frame)

    #expect(store.activeCanvas.selectedNodeID == newID)
    #expect(Set(fourNodeFrames.map(\.width)) == [380])
    #expect(Set(fourNodeFrames.map { "\($0.x),\($0.y)" }).count == 4)

    store.dispatch(.closeNode(newID))
    #expect(store.activeCanvas.nodes.count == 3)
    #expect(Set(store.activeCanvas.nodes.map(\.frame.width)) == [380])
    #expect(
      Set(store.activeCanvas.nodes.map { "\($0.frame.x),\($0.frame.y)" }).count == 3)
  }
}

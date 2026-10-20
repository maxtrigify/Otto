import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoTools
import Testing

@Suite("Whiteboard tools")
@MainActor
struct WhiteboardToolsTests {
  @Test("Creating a whiteboard initializes local Excalidraw content")
  func createWhiteboardNode() throws {
    let store = CanvasStore()
    let receipt = store.dispatch(
      .createNode(kind: .whiteboard, at: WorldPoint(x: 120, y: 160)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let node = try #require(store.activeCanvas.nodes.first(where: { $0.id == nodeID }))

    #expect(node.displayName == "Whiteboard 1")
    #expect(node.subtitle == "EXCALIDRAW · LOCAL")
    #expect(node.frame.width == 720)
    guard case .whiteboard(let document, let pendingActions) = node.content else {
      Issue.record("Expected whiteboard content")
      return
    }
    #expect(document == nil)
    #expect(pendingActions.isEmpty)
  }

  @Test("Agent shape creation queues a typed bridge action")
  func createShapes() async throws {
    let store = CanvasStore()
    let receipt = store.dispatch(
      .createNode(kind: .whiteboard, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let tool = WhiteboardCreateShapesTool(store: store)
    let shape = WhiteboardShape(
      id: "decision",
      type: .diamond,
      x: 100,
      y: 140,
      width: 180,
      height: 120,
      text: "Approved?",
      color: "yellow"
    )

    let output = try await tool.call(
      WhiteboardCreateShapesInput(nodeID: nodeID, shapes: [shape]),
      context: ToolContext(actorID: "diagram-agent", scopes: [.canvasWrite])
    )

    #expect(output.nodeID == nodeID)
    #expect(output.pendingActionCount == 1)
    #expect(output.queuedActionID != nil)
    let node = try #require(store.activeCanvas.nodes.first(where: { $0.id == nodeID }))
    guard case .whiteboard(_, let pendingActions) = node.content else {
      Issue.record("Expected whiteboard content")
      return
    }
    #expect(pendingActions.first?.shapes == [shape])
  }

  @Test("Whiteboard mutations reject ordinary canvas nodes")
  func rejectsOtherNodeKinds() async throws {
    let store = CanvasStore()
    let receipt = store.dispatch(.createNode(kind: .label, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let tool = WhiteboardFitTool(store: store)

    await #expect(throws: ToolRegistryError.self) {
      try await tool.call(
        NodeIDInput(nodeID: nodeID),
        context: ToolContext(actorID: "diagram-agent", scopes: [.canvasWrite])
      )
    }
  }
}

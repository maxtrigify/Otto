import Foundation
import OttoCore
import OttoModels
import OttoTools
import Testing
@testable import OttoApplicationTools

@Suite("Retired workspace features")
struct RetiredWorkspaceFeaturesTests {
  @Test("Legacy destinations fall back to Chat")
  func legacyDestination() throws {
    #expect(try JSONDecoder().decode(ChatSurfaceDestination.self, from: Data("\"Widgets\"".utf8)) == .conversation)
  }

  @Test("Generic creation cannot recreate retired canvas resources")
  @MainActor
  func retiredKindsCannotBeCreated() async throws {
    let canvas = OttoCanvas(name: "Retirement")
    let store = CanvasStore(snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let tool = NodeCreateTool(store: store)
    let context = ToolContext(actorID: "retirement-test", scopes: [.canvasWrite])
    for kind: NodeKind in [.widget, .whiteboard, .group, .connector, .label, .gtmGrid, .appMirror] {
      await #expect(throws: ToolRegistryError.self) {
        try await tool.call(NodeCreateInput(kind: kind, x: 0, y: 0), context: context)
      }
    }
    #expect(store.activeCanvas.nodes.isEmpty)
    let created = try await tool.call(NodeCreateInput(kind: .browser, x: 0, y: 0), context: context)
    #expect(created.node.kind == .browser)
  }
}

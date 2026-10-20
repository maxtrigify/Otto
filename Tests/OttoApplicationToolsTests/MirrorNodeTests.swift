import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("App mirror node control plane")
struct MirrorNodeTests {
  @Test("Mirror nodes create in picking mode and bind a window through the tool layer")
  func createAndBindThroughTools() async throws {
    let canvas = OttoCanvas(name: "Mirror plane")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let context = ToolContext(actorID: "mirror-test", scopes: Set(ToolScope.allCases))

    let created = try await registry.call(
      name: "node.create",
      input: .object([
        "kind": .string("appMirror"),
        "x": .number(40),
        "y": .number(60),
      ]),
      context: context
    )
    let nodeID = try #require(
      created["node"]?["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
    let node = try #require(await store.activeCanvas.nodes.first { $0.id == nodeID })
    #expect(node.kind == .appMirror)
    #expect(
      node.content == .appMirror(windowID: nil, applicationName: nil, windowTitle: nil),
      "Fresh mirror nodes start unbound, in window-picking mode"
    )
    #expect(node.subtitle == "APP WINDOW · LIVE")

    _ = await store.dispatch(
      .setNodeContent(
        id: nodeID,
        content: .appMirror(
          windowID: 7_001, applicationName: "Buzz", windowTitle: "Buzz — Dev")
      ))
    let bound = try #require(await store.activeCanvas.nodes.first { $0.id == nodeID })
    #expect(
      bound.content
        == .appMirror(windowID: 7_001, applicationName: "Buzz", windowTitle: "Buzz — Dev"))

    let encoded = try JSONEncoder().encode(await store.snapshot)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
    #expect(decoded == (await store.snapshot))
  }
}

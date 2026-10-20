import Foundation
import OttoModels
import Testing

@Suite("App mirror node model")
struct MirrorNodeModelTests {
  @Test("Mirror content survives JSON round-trips with and without a bound window")
  func contentRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let unbound = NodeContent.appMirror(windowID: nil, applicationName: nil, windowTitle: nil)
    let bound = NodeContent.appMirror(
      windowID: 4_242, applicationName: "Buzz", windowTitle: "Buzz — Dashboard")
    for content in [unbound, bound] {
      let decoded = try decoder.decode(
        NodeContent.self, from: try encoder.encode(content))
      #expect(decoded == content)
    }
  }

  @Test("Mirror kind has a browser-class default footprint")
  func defaultSize() {
    let size = NodeKind.appMirror.defaultSize
    #expect(size.width >= 480)
    #expect(size.height >= 300)
  }

  @Test("Workspace snapshots containing mirror nodes persist losslessly")
  func snapshotRoundTrip() throws {
    var canvas = OttoCanvas(name: "Mirrors")
    var node = OttoNode(
      kind: .appMirror,
      displayName: "Mirror 1",
      subtitle: "APP WINDOW · LIVE",
      frame: WorldRect(x: 0, y: 0, width: 520, height: 340),
      zIndex: 0,
      status: .idle,
      detail: "Ready"
    )
    node.content = .appMirror(
      windowID: 99, applicationName: "GTM Grid", windowTitle: "GTM Grid — Boards")
    canvas.nodes.append(node)
    let snapshot = WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)

    let decoded = try JSONDecoder().decode(
      WorkspaceSnapshot.self, from: try JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.canvases[0].nodes[0].kind == .appMirror)
  }
}

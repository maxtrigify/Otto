import CoreGraphics
import Foundation
import OttoCore
import OttoModels
import Testing

@Suite("Scene transforms")
struct SceneTransformTests {
  @Test("World and screen conversion round trips")
  func transformRoundTrip() {
    let viewport = Viewport(centerX: 240, centerY: -80, scale: 1.4)
    let size = CGSize(width: 1200, height: 800)
    let source = WorldPoint(x: -120, y: 315)

    let screen = SceneTransform.screenPoint(for: source, viewport: viewport, canvasSize: size)
    let restored = SceneTransform.worldPoint(for: screen, viewport: viewport, canvasSize: size)

    #expect(abs(restored.x - source.x) < 0.001)
    #expect(abs(restored.y - source.y) < 0.001)
  }

  @Test("Viewport clamps unsafe zoom levels")
  func viewportClampsScale() {
    #expect(Viewport(scale: 0.01).scale == 0.25)
    #expect(Viewport(scale: 8).scale == 2.5)
  }

  @Test("Grid geometry cache ignores translation and buckets small scale jitter")
  func gridCacheKey() {
    let first = CanvasGridCacheKey(width: 1_200, height: 800, scale: 1)
    let sameBucket = CanvasGridCacheKey(width: 1_200, height: 800, scale: 1.006)
    let nextBucket = CanvasGridCacheKey(width: 1_200, height: 800, scale: 1.04)

    #expect(first == sameBucket)
    #expect(first != nextBucket)
    #expect(first.spacing == 44)
  }
}

@MainActor
@Suite("Canvas command dispatcher")
struct CanvasCommandTests {
  @Test("Agent names use the persisted policy and never fake a provider badge")
  func persistedAgentNaming() throws {
    let suite = "otto.tests.canvas-naming.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))
    AgentNamingPolicy(mode: .custom, customNames: ["Ripley"]).save(to: defaults)
    let canvas = OttoCanvas(name: "Names")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id),
      preferences: defaults
    )

    for _ in 0..<2 {
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    }

    #expect(store.activeCanvas.nodes.map(\.displayName) == ["Ripley", "Ripley 2"])
    #expect(store.activeCanvas.nodes.allSatisfy { $0.subtitle == "AGENT · LOCAL" })
    let firstID = try #require(store.activeCanvas.nodes.first?.id)
    store.dispatch(.setNodeContent(id: firstID, content: .agent(provider: .codex)))
    #expect(store.activeCanvas.nodes.first?.subtitle == "CODEX · LOCAL")
  }

  @Test("Fifty mixed nodes create, move, and organize within the interaction budget")
  func fiftyNodeInteractionBudget() {
    let canvas = OttoCanvas(name: "Scale fixture")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let kinds = NodeKind.allCases
    let duration = ContinuousClock().measure {
      for index in 0..<50 {
        let receipt = store.dispatch(
          .createNode(
            kind: kinds[index % kinds.count],
            at: WorldPoint(x: Double(index * 13), y: Double(index * -7))))
        if let id = receipt.affectedNodeIDs.first {
          store.dispatch(
            .moveNode(id: id, to: WorldPoint(x: Double(index * 17), y: Double(index * 9))))
        }
      }
      store.dispatch(.setLayout(.grid))
      store.dispatch(.setLayout(.fleet))
    }
    #expect(store.activeCanvas.nodes.count == 50)
    #expect(Set(store.activeCanvas.nodes.map(\.kind)) == Set(NodeKind.allCases))
    #expect(duration < .milliseconds(500))
  }

  @Test("Commands create, move, focus, and close through one state path")
  func commandLifecycle() {
    let empty = OttoCanvas(name: "Test")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [empty], activeCanvasID: empty.id))

    let created = store.dispatch(.createNode(kind: .terminal, at: WorldPoint(x: 10, y: 20)))
    let id = try! #require(created.affectedNodeIDs.first)
    #expect(store.activeCanvas.nodes.count == 1)
    #expect(store.activeCanvas.selectedNodeID == id)

    store.dispatch(.moveNode(id: id, to: WorldPoint(x: -40, y: 95)))
    #expect(store.activeCanvas.nodes[0].frame.x == -40)
    #expect(store.activeCanvas.nodes[0].frame.y == 95)

    let closed = store.dispatch(.closeAll)
    #expect(closed.message == "Closed 1 nodes")
    #expect(store.activeCanvas.nodes.isEmpty)
  }

  @Test("Minimizing preserves the stable node and restoring focuses it")
  func railPresentationLifecycle() throws {
    let canvas = OttoCanvas(name: "Rail")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let id = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 10, y: 20)))
        .affectedNodeIDs.first)

    store.dispatch(.setNodeMinimized(id: id, minimized: true))
    #expect(store.activeCanvas.nodes.count == 1)
    #expect(store.activeCanvas.nodes[0].isMinimized == true)
    #expect(store.activeCanvas.nodes[0].effectivePresentationMode == .compact)
    #expect(store.activeCanvas.selectedNodeID == nil)

    store.dispatch(.setNodeMinimized(id: id, minimized: false))
    #expect(store.activeCanvas.nodes[0].isMinimized == false)
    #expect(store.activeCanvas.nodes[0].effectivePresentationMode == .conversation)
    #expect(store.activeCanvas.selectedNodeID == id)
    #expect(store.activeCanvas.nodes[0].lastOpenedAt != nil)
  }

  @Test("Presentation modes preserve the last expanded agent surface")
  func explicitPresentationLifecycle() throws {
    let canvas = OttoCanvas(name: "Presentation")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let id = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)

    store.dispatch(.setNodePresentation(id: id, presentation: .terminal))
    store.dispatch(.setNodePresentation(id: id, presentation: .compact))
    #expect(store.activeCanvas.nodes[0].effectivePresentationMode == .compact)
    #expect(store.activeCanvas.nodes[0].effectiveExpandedPresentation == .terminal)
    #expect(store.activeCanvas.selectedNodeID == nil)

    store.dispatch(.setNodeMinimized(id: id, minimized: false))
    #expect(store.activeCanvas.nodes[0].effectivePresentationMode == .terminal)
    #expect(store.activeCanvas.selectedNodeID == id)
  }

  @Test("Legacy minimized nodes migrate without changing their saved identity")
  func legacyPresentationMigration() throws {
    let node = OttoNode(
      kind: .agent,
      displayName: "Legacy",
      subtitle: "CODEX · LOCAL",
      frame: WorldRect(x: 1, y: 2, width: 300, height: 200),
      zIndex: 3,
      isMinimized: true
    )
    let encoded = try JSONEncoder().encode(node)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "presentationMode")
    object.removeValue(forKey: "lastExpandedPresentation")

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let restored = try JSONDecoder().decode(OttoNode.self, from: legacyData)
    #expect(restored.id == node.id)
    #expect(restored.effectivePresentationMode == .compact)
    #expect(restored.effectiveExpandedPresentation == .conversation)
  }

  @Test("Creation tools receive honest typed defaults")
  func defaultContentForEveryNodeKind() {
    let canvas = OttoCanvas(name: "Creation tools")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    )
    for (index, kind) in NodeKind.allCases.enumerated() {
      _ = store.dispatch(
        .createNode(kind: kind, at: WorldPoint(x: Double(index * 10), y: 0))
      )
    }
    #expect(store.activeCanvas.nodes.count == NodeKind.allCases.count)
    #expect(store.activeCanvas.nodes.first { $0.kind == .agent }?.content == nil)
    #expect(store.activeCanvas.nodes.filter { $0.kind != .agent }.allSatisfy { $0.content != nil })
    #expect(
      store.activeCanvas.nodes.first { $0.kind == .label }?.content == .label(text: "New thought"))
    #expect(store.activeCanvas.nodes.first { $0.kind == .group }?.content == .group)
    #expect(
      store.activeCanvas.nodes.first { $0.kind == .connector }?.content
        == .connector(sourceNodeID: nil, targetNodeID: nil)
    )
  }

  @Test("Layouts are distinct and restore exact freeform geometry")
  func layoutGeometryRestoration() {
    let nodes: [OttoNode] = (0..<4).map { (index: Int) -> OttoNode in
      let offset = Double(index)
      let frame = WorldRect(
        x: offset * 113,
        y: offset * -71,
        width: 300 + offset,
        height: 200 + offset
      )
      return OttoNode(
        kind: .terminal,
        displayName: "Terminal \(index)",
        subtitle: "ZSH",
        frame: frame,
        zIndex: index
      )
    }
    let canvas = OttoCanvas(name: "Layouts", nodes: nodes, selectedNodeID: nodes[1].id)
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let freeform = store.activeCanvas.nodes.map(\.frame)

    store.dispatch(.setLayout(.grid))
    #expect(Set(store.activeCanvas.nodes.map { $0.frame.width }) == [380])
    #expect(store.activeCanvas.layoutMode == .grid)

    store.dispatch(.setLayout(.columns))
    #expect(Set(store.activeCanvas.nodes.map { $0.frame.height }) == [540])
    #expect(Set(store.activeCanvas.nodes.map { $0.frame.y }) == [-270])

    let staged = store.dispatch(.setLayout(.stage))
    #expect(Set(staged.affectedNodeIDs) == Set(nodes.map(\.id)))
    #expect(store.activeCanvas.nodes.first(where: { $0.id == nodes[1].id })?.frame.width == 760)
    #expect(
      store.activeCanvas.nodes.filter { $0.id != nodes[1].id }.allSatisfy {
        $0.frame.width == 300
      })

    store.dispatch(.focusNode(nodes[2].id))
    store.dispatch(.setLayout(.stage))
    #expect(store.activeCanvas.nodes.first(where: { $0.id == nodes[2].id })?.frame.width == 760)
    #expect(store.activeCanvas.nodes.first(where: { $0.id == nodes[1].id })?.frame.width == 300)

    store.dispatch(.setLayout(.fleet))
    #expect(Set(store.activeCanvas.nodes.map { $0.frame.height }) == [180])

    store.dispatch(.setLayout(.freeform))
    #expect(store.activeCanvas.nodes.map(\.frame) == freeform)
  }

  @Test("Five canvases preserve independent state and switch within the latency target")
  func multiCanvasLifecycle() {
    let first = OttoCanvas(name: "Canvas 1")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [first], activeCanvasID: first.id))
    for index in 2...5 {
      store.dispatch(.createCanvas(name: "Canvas \(index)"))
      store.dispatch(
        .createNode(kind: .markdown, at: WorldPoint(x: Double(index * 10), y: 0)))
    }
    #expect(store.snapshot.canvases.count == 5)

    let clock = ContinuousClock()
    let duration = clock.measure {
      for canvas in store.snapshot.canvases {
        store.dispatch(.switchCanvas(canvas.id))
      }
    }
    #expect(duration < .milliseconds(100))
    #expect(store.activeCanvas.name == "Canvas 5")
    #expect(store.snapshot.canvases[0].nodes.isEmpty)
    #expect(store.snapshot.canvases.dropFirst().allSatisfy { $0.nodes.count == 1 })
  }
}

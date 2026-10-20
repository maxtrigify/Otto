import Foundation
import OttoCore
import OttoModels
import Testing

@Suite("Canvas-targeted commands")
@MainActor
struct CanvasTargetingTests {
  @Test("A background command mutates only its target and never switches the visible canvas")
  func backgroundMutationPreservesVisibleCanvas() {
    let visible = OttoCanvas(name: "Visible")
    let background = OttoCanvas(name: "Background")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [visible, background],
        activeCanvasID: visible.id
      ))
    let visibleBefore = store.activeCanvas

    let receipt = store.dispatch(
      .createNode(kind: .markdown, at: WorldPoint(x: 40, y: 80)),
      targetCanvasID: background.id
    )

    #expect(receipt.affectedNodeIDs.count == 1)
    #expect(store.snapshot.activeCanvasID == visible.id)
    #expect(store.activeCanvas == visibleBefore)
    #expect(store.snapshot.canvases.first(where: { $0.id == background.id })?.nodes.count == 1)
  }

  @Test("An unknown canvas target cannot fall back to the visible canvas")
  func missingTargetDoesNotFallBack() {
    let visible = OttoCanvas(name: "Visible")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [visible], activeCanvasID: visible.id))

    let receipt = store.dispatch(
      .createNode(kind: .terminal, at: WorldPoint(x: 0, y: 0)),
      targetCanvasID: UUID()
    )

    #expect(receipt.affectedNodeIDs.isEmpty)
    #expect(store.activeCanvas.nodes.isEmpty)
  }

  @Test("A node resolves back to its owning canvas")
  func resolvesNodeCanvas() {
    let node = OttoNode(
      kind: .agent,
      displayName: "Worker",
      subtitle: "CODEX · LOCAL",
      frame: WorldRect(x: 0, y: 0, width: 420, height: 270),
      zIndex: 0
    )
    let visible = OttoCanvas(name: "Visible")
    let background = OttoCanvas(name: "Background", nodes: [node])
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [visible, background],
        activeCanvasID: visible.id
      ))

    #expect(store.canvasID(containing: node.id) == background.id)
  }

  @Test("A new browser opens on the default start page")
  func browserUsesDefaultStartPage() throws {
    let canvas = OttoCanvas(name: "Visible")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))

    let receipt = store.dispatch(
      .createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let browser = try #require(store.activeCanvas.nodes.first(where: { $0.id == nodeID }))

    #expect(browser.displayName == "Browser 1")
    #expect(browser.subtitle == BrowserDefaults.subtitle)
    #expect(browser.content == .browser(url: BrowserDefaults.startURL))
    #expect(browser.frame.width == NodeKind.browser.defaultSize.width)
    #expect(browser.frame.height == NodeKind.browser.defaultSize.height)
    #expect(browser.frame.width >= 800)
    #expect(browser.browserSession?.activeTab?.url == BrowserDefaults.startURL)
  }

  @Test("Browser navigation keeps the active tab in sync")
  func browserContentUpdatesActiveTab() throws {
    let canvas = OttoCanvas(name: "Visible")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)

    _ = store.dispatch(
      .setNodeContent(id: nodeID, content: .browser(url: "https://example.com/docs")))

    let browser = try #require(store.activeCanvas.nodes.first(where: { $0.id == nodeID }))
    #expect(browser.browserSession?.activeTab?.url == "https://example.com/docs")
  }
}

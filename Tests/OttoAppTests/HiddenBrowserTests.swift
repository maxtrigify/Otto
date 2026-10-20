import AppKit
import OttoBrowser
import OttoCore
import OttoModels
import Testing

@testable import OttoApp

@Suite("Hidden browser", .serialized)
struct HiddenBrowserTests {
  @Test @MainActor func preservesSpecializedWebRenderer() async throws {
    let store = CanvasStore()
    let runtime = BrowserRuntime()
    let receipt = store.dispatch(.createNode(kind: .gtmGrid, at: WorldPoint(x: 0, y: 0)))
    let id = try #require(receipt.affectedNodeIDs.first)
    await runtime.register(nodeID: id, url: "app://gtmgrid/index.html")
    await runtime.registerCaptureHandler(nodeID: id) {
      BrowserCapture(pngData: Data([1, 2, 3]), pixelWidth: 10, pixelHeight: 10)
    }
    await BrowserRendererPool.configure(store: store, runtime: runtime)
    #expect(try await runtime.capture(nodeID: id).pngData == Data([1, 2, 3]))
  }

  @Test @MainActor func inspectInteractAndCaptureWithoutVisiblePanel() async throws {
    _ = NSApplication.shared
    let store = CanvasStore()
    let runtime = BrowserRuntime()
    let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let id = try #require(receipt.affectedNodeIDs.first)
    let html =
      "<html><body style=\"background:rgb(220,40,50)\"><button onclick=\"this.textContent='Clicked'\">Continue</button></body></html>"
    let url = "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    let session = BrowserSession(url: url)
    store.dispatch(.setBrowserSession(id: id, session: session))
    await runtime.synchronize(nodeID: id, session: session)
    await BrowserRendererPool.configure(store: store, runtime: runtime)
    defer {
      store.dispatch(.closeNode(id))
      BrowserRendererPool.prune(snapshot: store.snapshot)
    }

    let page = try await runtime.inspectPage(nodeID: id)
    let button = try #require(page.elements.first(where: { $0.name == "Continue" }))
    _ = try await runtime.interact(
      nodeID: id,
      request: BrowserInteractionRequest(
        revision: page.pageRevision, kind: .click, elementID: button.id))
    let changed = try await runtime.inspectPage(nodeID: id)
    #expect(changed.elements.contains(where: { $0.name == "Clicked" }))
    let capture = try await runtime.capture(nodeID: id)
    #expect(capture.pixelWidth > 0)
    #expect(capture.pixelHeight > 0)
    #expect(!capture.pngData.isEmpty)
    let bitmap = try #require(NSBitmapImageRep(data: capture.pngData))
    let pixel = try #require(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
        .usingColorSpace(.deviceRGB))
    #expect(pixel.redComponent > 0.7)
    #expect(pixel.greenComponent < 0.3)
    let hasVisibleWindow = NSApplication.shared.windows.contains { $0.isVisible }
    #expect(!hasVisibleWindow)
  }
}

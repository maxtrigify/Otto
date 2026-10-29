import AppKit
import OttoApplicationTools
import OttoBrowser
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoApp

@Suite("Hidden browser", .serialized)
struct HiddenBrowserTests {
  @Test("Send-labelled browser controls follow the agent approval mode", arguments: [false, true])
  @MainActor func browserClickApprovalMode(bypass: Bool) async throws {
    _ = NSApplication.shared
    let store = CanvasStore()
    let runtime = BrowserRuntime()
    let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let id = try #require(receipt.affectedNodeIDs.first)
    let html = "<button onclick=\"this.textContent='Clicked'\">Send Messages</button>"
    let session = BrowserSession(
      url: "data:text/html;base64," + Data(html.utf8).base64EncodedString())
    store.dispatch(.setBrowserSession(id: id, session: session))
    await runtime.synchronize(nodeID: id, session: session)
    await BrowserRendererPool.configure(store: store, runtime: runtime)
    defer {
      store.dispatch(.closeNode(id))
      BrowserRendererPool.prune(snapshot: store.snapshot)
    }
    let supervisor = AgentSupervisor()
    let agentID = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh", arguments: ["-c", "sleep 20"],
        workingDirectory: FileManager.default.temporaryDirectory.path),
      permissionMode: bypass ? .unrestricted : .workspaceWrite)
    var context = ToolContext(
      actorID: "otto-agent-\(agentID.uuidString)", scopes: [.agentRead, .canvasRead, .canvasWrite],
      source: .agent, sourceNodeID: agentID, sourceCanvasID: store.snapshot.activeCanvasID)
    let page = try await runtime.inspectPage(nodeID: id)
    let button = try #require(page.elements.first(where: { $0.name == "Send Messages" }))
    let input = BrowserElementInput(
      nodeID: id, pageRevision: page.pageRevision, elementID: button.id)
    let click = BrowserClickTool(store: store, runtime: runtime)
    await #expect(throws: ToolRegistryError.confirmationRequired("browser.click")) {
      try await click.call(input, context: context)
    }
    let approval = try await AgentRequestPermissionTool(
      supervisor: supervisor, browserConfirmationTimeout: .milliseconds(50)
    ).call(AgentPermissionPromptInput(toolName: "browser.click"), context: context)
    #expect(approval.behavior == (bypass ? "allow" : "deny"))
    if approval.behavior == "allow" {
      context.confirmed = true
      _ = try await click.call(input, context: context)
    }
    var changed = try await runtime.inspectPage(nodeID: id)
    for _ in 0..<40 where bypass && !changed.elements.contains(where: { $0.name == "Clicked" }) {
      try await Task.sleep(for: .milliseconds(100))
      changed = try await runtime.inspectPage(nodeID: id)
    }
    #expect(changed.elements.contains(where: { $0.name == "Clicked" }) == bypass)
    #expect(await !supervisor.hasPendingPermission(agentID: agentID))
    try await supervisor.stop(agentID: agentID)
  }

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
    // The click is delivered to WebKit, which updates the DOM on its own schedule; a slow CI
    // runner can inspect before the handler has run. Poll briefly rather than inspect once.
    var changed = try await runtime.inspectPage(nodeID: id)
    for _ in 0..<40 where !changed.elements.contains(where: { $0.name == "Clicked" }) {
      try await Task.sleep(for: .milliseconds(100))
      changed = try await runtime.inspectPage(nodeID: id)
    }
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
    // Check the renderer pool's own windows: other suites (the slide presenter) run in parallel in
    // this process and may legitimately have a window up at this instant.
    #expect(!BrowserRendererPool.hasVisibleRendererWindow)
  }
}

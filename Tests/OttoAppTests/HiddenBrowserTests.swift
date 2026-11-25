import AppKit
import OttoBrowser
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoApp
@testable import OttoApplicationTools

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
    let sequence = BrowserSequenceTool(store: store, runtime: runtime, workspacePath: "/unused")
    let stopped = try await sequence.call(
      .init(
        nodeID: id,
        steps: [
          .init(action: .wait, target: "Send Messages"),
          .init(action: .click, target: "Send Messages"),
        ]), context: context)
    #expect(stopped.completedSteps == 1)
    #expect(stopped.stoppedReason?.contains("browser.click") == true)
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

extension HiddenBrowserTests {
  @Test @MainActor func sequenceFindsAndDownloadsThreeAuthenticatedInvoices()
    async throws
  {
    _ = NSApplication.shared
    let store = CanvasStore()
    let runtime = BrowserRuntime()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let months = ["November", "October", "September", "August"]
    let source = folder.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for month in months {
      let label = NSTextField(labelWithString: month)
      label.sizeToFit()
      try label.dataWithPDF(inside: label.bounds).write(
        to: source.appendingPathComponent(month + ".pdf"))
    }
    let html = """
      <input aria-label="Query"><button id="search">Search</button><main></main>
      <script>
      search.onclick = () => setTimeout(() => {
        if (document.querySelector('input').value !== 'Invoices') return;
        for (const month of ['November','October','September','August']) {
          const a = document.createElement('a');
          a.href = '/' + month + '.pdf';
          a.textContent = 'Invoice ' + month; document.querySelector('main').append(a);
        }
      }, 300);
      </script>
      """
    try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.currentDirectoryURL = source
    server.arguments = [
      "-u", "-c",
      """
      from http.server import HTTPServer, SimpleHTTPRequestHandler
      class Handler(SimpleHTTPRequestHandler):
          def log_message(self, *args): pass
          def do_GET(self):
              if self.path.endswith('.pdf') and 'fixture=active' not in self.headers.get('Cookie', ''):
                  self.send_error(401)
              else: super().do_GET()
          def end_headers(self):
              if self.path == '/': self.send_header('Set-Cookie', 'fixture=active; HttpOnly; SameSite=Strict')
              super().end_headers()
      server = HTTPServer(('127.0.0.1', 0), Handler)
      print(server.server_port, flush=True)
      server.serve_forever()
      """,
    ]
    let pipe = Pipe()
    server.standardOutput = pipe
    try server.run()
    defer {
      server.terminate()
      server.waitUntilExit()
    }
    let port = try #require(
      Int(
        String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let id = try #require(receipt.affectedNodeIDs.first)
    let session = BrowserSession(url: "http://127.0.0.1:\(port)/")
    store.dispatch(.setBrowserSession(id: id, session: session))
    await runtime.synchronize(nodeID: id, session: session)
    await BrowserRendererPool.configure(store: store, runtime: runtime)
    defer {
      store.dispatch(.closeNode(id))
      BrowserRendererPool.prune(snapshot: store.snapshot)
    }
    let tool = BrowserSequenceTool(store: store, runtime: runtime, workspacePath: folder.path)
    let context = ToolContext(actorID: "test", scopes: [.canvasRead, .canvasWrite])
    let search = BrowserSequenceInput(
      nodeID: id,
      steps: [
        .init(action: .type, target: "Query", text: "Invoices"),
        .init(action: .click, target: "Search"),
        .init(action: .list, target: "Invoice"),
      ])
    let found = try await tool.call(search, context: context)
    #expect(found.stoppedReason == nil)
    #expect(
      found.matchedControls == [
        "Invoice November", "Invoice October", "Invoice September", "Invoice August",
      ])
    let page = try await runtime.inspectPage(nodeID: id)
    let compactBytes = try JSONEncoder().encode(found).count
    let fullBytes = try JSONEncoder().encode(page).count
    #expect(compactBytes < fullBytes)
    print(
      "Invoice search returned \(compactBytes) JSON bytes; full inspection returned \(fullBytes).")
    let downloads = found.matchedControls.prefix(3).map {
      BrowserSequenceInput.Step(action: .downloadPDF, target: $0)
    }
    let result = try await tool.call(.init(nodeID: id, steps: downloads), context: context)
    #expect(result.completedSteps == 3, "\(result.stoppedReason ?? "no stop")")
    #expect(result.stoppedReason == nil)
    #expect(result.files.count == 3)
    for (path, month) in zip(result.files, months) {
      let expected = try Data(contentsOf: source.appendingPathComponent(month + ".pdf"))
      #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == expected)
    }
  }
}

extension HiddenBrowserTests {
  @Test @MainActor func sequenceRecoversStaleTargetAndStopsOnSiteChange() async throws {
    let store = CanvasStore()
    let runtime = BrowserRuntime()
    let receipt = store.dispatch(.createNode(kind: .browser, at: WorldPoint(x: 0, y: 0)))
    let id = try #require(receipt.affectedNodeIDs.first)
    let session = BrowserSession(url: "https://shop.example/invoices")
    store.dispatch(.setBrowserSession(id: id, session: session))
    var attempts = 0
    var dispatched = 0
    var site = try #require(session.activeTab?.url)
    await runtime.registerPageHandler(
      nodeID: id,
      snapshot: { id in
        .init(
          nodeID: id, url: site, pageRevision: "\(attempts)",
          elements: [
            .init(
              id: "e\(attempts)", role: "link", name: "Next",
              bounds: .init(x: 0, y: 0, width: 10, height: 10), actions: [.click])
          ])
      },
      interact: { id, request in
        attempts += 1
        if attempts == 1 { throw BrowserRuntimeError.stalePageSnapshot }
        #expect(request.elementID == "e1")
        dispatched += 1
        site = "https://signin.example/login"
        return .init(nodeID: id, pageRevision: request.revision, url: site, message: "Clicked")
      },
      assess: { _, _ in .init(requiresConfirmation: false) })
    let tool = BrowserSequenceTool(store: store, runtime: runtime, workspacePath: "/unused")
    let result = try await tool.call(
      .init(
        nodeID: id,
        steps: [
          .init(action: .click, target: "Next"), .init(action: .click, target: "Next"),
        ]), context: ToolContext(actorID: "test", scopes: [.canvasRead, .canvasWrite]))
    #expect(result.completedSteps == 1)
    #expect(result.stoppedReason?.contains("site changed") == true)
    #expect(dispatched == 1)
  }
}

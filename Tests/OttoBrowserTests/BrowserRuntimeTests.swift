import Foundation
import OttoBrowser
import OttoModels
import Testing

@Suite("Browser runtime")
struct BrowserRuntimeTests {
  @Test("Per-node commands publish ordered state and page reports")
  func commandLifecycle() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://example.test")
    let updates = await runtime.updates(nodeID: nodeID)
    let collector = Task<[BrowserRuntimeState], Never> {
      var collected: [BrowserRuntimeState] = []
      for await state in updates {
        collected.append(state)
        if collected.count == 4 { break }
      }
      return collected
    }

    try await runtime.navigate(nodeID: nodeID, url: "https://example.test/docs")
    try await runtime.refresh(nodeID: nodeID)
    try await runtime.reportLoaded(
      nodeID: nodeID,
      url: "https://example.test/docs",
      title: "Docs",
      canGoBack: true,
      canGoForward: false,
      isLoading: false
    )

    let states = await collector.value
    #expect(states.map(\.revision) == [0, 1, 2, 2])
    #expect(states[1].requestedAction == .navigate)
    #expect(states[2].requestedAction == .refresh)
    #expect(states[3].title == "Docs")
    #expect(states[3].canGoBack)
  }

  @Test("Visible browser capture handlers return pixel metadata and bytes")
  func capture() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://example.test")
    let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
    await runtime.registerCaptureHandler(nodeID: nodeID) {
      BrowserCapture(pngData: bytes, pixelWidth: 1_200, pixelHeight: 800)
    }

    let capture = try await runtime.capture(nodeID: nodeID)
    #expect(capture.pngData == bytes)
    #expect(capture.pixelWidth == 1_200)
    #expect(capture.pixelHeight == 800)
    #expect(await runtime.state(nodeID: nodeID)?.lastActivity?.kind == .evidence)
    #expect(await runtime.state(nodeID: nodeID)?.lastActivity?.title == "Captured evidence")

    await runtime.unregisterCaptureHandler(nodeID: nodeID)
    await #expect(throws: BrowserRuntimeError.captureUnavailable(nodeID)) {
      try await runtime.capture(nodeID: nodeID)
    }
  }

  @Test("Semantic page handlers reject stale revisions and preserve opaque element IDs")
  func semanticPageInteraction() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://example.test")
    let element = BrowserPageElement(
      id: "e1",
      role: "button",
      name: "Continue",
      bounds: BrowserElementBounds(x: 12, y: 24, width: 100, height: 36),
      actions: [.click]
    )
    await runtime.registerPageHandler(
      nodeID: nodeID,
      snapshot: { nodeID in
        BrowserPageSnapshot(
          nodeID: nodeID,
          url: "https://example.test",
          pageRevision: "page-1",
          elements: [element]
        )
      },
      interact: { nodeID, request in
        guard request.revision == "page-1" else { throw BrowserRuntimeError.stalePageSnapshot }
        return BrowserInteractionResult(
          nodeID: nodeID,
          pageRevision: request.revision,
          url: "https://example.test",
          message: "Clicked element"
        )
      }
    )

    let page = try await runtime.inspectPage(nodeID: nodeID)
    #expect(page.elements == [element])
    #expect(await runtime.state(nodeID: nodeID)?.lastActivity?.title == "Mapped page")
    let result = try await runtime.interact(
      nodeID: nodeID,
      request: BrowserInteractionRequest(
        revision: page.pageRevision, kind: .click, elementID: "e1")
    )
    #expect(result.message == "Clicked element")
    #expect(await runtime.state(nodeID: nodeID)?.lastActivity?.kind == .interaction)
    #expect(await runtime.state(nodeID: nodeID)?.lastActivity?.title == "Clicked Continue")

    await #expect(throws: BrowserRuntimeError.stalePageSnapshot) {
      try await runtime.interact(
        nodeID: nodeID,
        request: BrowserInteractionRequest(
          revision: "stale", kind: .click, elementID: "e1"))
    }
  }

  @Test("Page diagnostics become visible agent activity")
  func pageDiagnostics() async {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "http://localhost:3000")

    await runtime.reportPageDiagnostic(nodeID: nodeID, message: "Unhandled promise rejection")

    let activity = await runtime.state(nodeID: nodeID)?.lastActivity
    #expect(activity?.kind == .warning)
    #expect(activity?.title == "Page reported an error")
    #expect(activity?.detail == "Unhandled promise rejection")
    #expect(activity?.succeeded == false)
  }

  @Test("Tabs preserve pages and element selections are agent-readable")
  func tabsAndSelection() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let initial = await runtime.register(nodeID: nodeID, url: "https://mail.example/inbox")
    let firstTabID = initial.activeTabID

    let opened = try await runtime.openTab(nodeID: nodeID, url: "http://localhost:3000/settings")
    #expect(
      opened.tabs.map(\.url) == ["https://mail.example/inbox", "http://localhost:3000/settings"])
    #expect(opened.activeTabID != firstTabID)

    _ = try await runtime.setSelectionMode(nodeID: nodeID, enabled: true)
    let selection = BrowserElementSelection(
      nodeID: nodeID,
      tabID: opened.activeTabID,
      url: opened.url,
      route: "/settings",
      tagName: "button",
      role: "button",
      accessibleName: "Save changes",
      text: "Save changes",
      selector: "#save-settings",
      bounds: BrowserElementBounds(x: 24, y: 80, width: 120, height: 36),
      styles: ["fontSize": "14px", "borderRadius": "8px"]
    )
    let selected = try await runtime.reportSelection(nodeID: nodeID, selection: selection)
    #expect(selected.selectionModeEnabled == false)
    #expect(selected.selectedElement == selection)

    let switched = try await runtime.selectTab(nodeID: nodeID, tabID: firstTabID)
    #expect(switched.url == "https://mail.example/inbox")
    #expect(switched.requestedAction == .activateTab)
    #expect(switched.selectedElement == nil)
  }

  @Test("Persisted sessions replace phantom runtime tabs and preserve stable IDs")
  func synchronizeUsesPersistedTabTopology() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let phantom = await runtime.register(nodeID: nodeID, url: "https://phantom.example")
    let tabs = [
      BrowserTab(url: "https://first.example"),
      BrowserTab(url: "https://second.example"),
      BrowserTab(url: "https://third.example"),
    ]
    let session = BrowserSession(tabs: tabs, activeTabID: tabs[1].id)

    let synchronized = await runtime.synchronize(nodeID: nodeID, session: session)
    let repeated = await runtime.synchronize(nodeID: nodeID, session: session)

    #expect(!synchronized.tabs.contains(where: { $0.id == phantom.activeTabID }))
    #expect(synchronized.tabs.map(\.id) == tabs.map(\.id))
    #expect(synchronized.tabs.map(\.url) == tabs.map(\.url))
    #expect(synchronized.activeTabID == tabs[1].id)
    #expect(synchronized.url == tabs[1].url)
    #expect(synchronized.requestedAction == .activateTab)
    #expect(repeated == synchronized)
  }

  @Test("Corrupt empty persisted sessions recover to a stable blank tab")
  func synchronizeRecoversEmptyDecodedSession() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let activeTabID = UUID()
    let data = try JSONEncoder().encode(
      EmptyBrowserSessionFixture(tabs: [], activeTabID: activeTabID))
    let session = try JSONDecoder().decode(BrowserSession.self, from: data)

    let synchronized = await runtime.synchronize(nodeID: nodeID, session: session)

    #expect(synchronized.tabs.count == 1)
    #expect(synchronized.tabs[0].id == activeTabID)
    #expect(synchronized.tabs[0].url == BrowserDefaults.blankURL)
    #expect(synchronized.activeTabID == activeTabID)
  }

  @Test("Opening the same explicit tab ID is idempotent")
  func explicitTabIDDoesNotDuplicate() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let tabID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://first.example")

    _ = try await runtime.openTab(
      nodeID: nodeID, url: "https://second.example", tabID: tabID)
    let repeated = try await runtime.openTab(
      nodeID: nodeID, url: "https://updated.example", tabID: tabID)

    #expect(repeated.tabs.count == 2)
    #expect(repeated.tabs.filter { $0.id == tabID }.count == 1)
    #expect(repeated.activeTabID == tabID)
    #expect(repeated.url == "https://updated.example")
  }

  @Test("Switching tabs activates the retained page instead of navigating to its recorded URL")
  func switchingTabsDoesNotNavigate() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let first = await runtime.register(nodeID: nodeID, url: "https://login.example/verify")
    let second = try await runtime.openTab(
      nodeID: nodeID, url: "https://mail.example/inbox")

    let switched = try await runtime.selectTab(nodeID: nodeID, tabID: first.activeTabID)

    #expect(switched.activeTabID == first.activeTabID)
    #expect(switched.url == "https://login.example/verify")
    #expect(switched.requestedAction == .activateTab)
    #expect(switched.revision == second.revision + 1)
    #expect(switched.isLoading == false)
  }

  @Test("Closing the active tab reveals the retained neighbor without navigating it")
  func closingActiveTabDoesNotNavigate() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let first = await runtime.register(nodeID: nodeID, url: "https://login.example/verify")
    let mail = try await runtime.openTab(nodeID: nodeID, url: "https://mail.example/inbox")
    let loginTab = try #require(first.tabs.first)

    let closed = try await runtime.closeTab(
      nodeID: nodeID,
      tabID: mail.activeTabID,
      activating: loginTab
    )

    #expect(closed.activeTabID == loginTab.id)
    #expect(closed.url == loginTab.url)
    #expect(closed.requestedAction == .activateTab)
    #expect(closed.isLoading == false)
  }

  @Test("A dismantled background tab cannot unregister the active tab handlers")
  func handlerOwnershipPreventsStaleUnregistration() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    let backgroundOwner = UUID()
    let activeOwner = UUID()
    await runtime.register(nodeID: nodeID, url: "https://example.test")

    await runtime.registerCaptureHandler(nodeID: nodeID, ownerID: backgroundOwner) {
      BrowserCapture(pngData: Data([1]), pixelWidth: 1, pixelHeight: 1)
    }
    await runtime.registerCaptureHandler(nodeID: nodeID, ownerID: activeOwner) {
      BrowserCapture(pngData: Data([2]), pixelWidth: 2, pixelHeight: 2)
    }
    await runtime.unregisterCaptureHandler(nodeID: nodeID, ownerID: backgroundOwner)

    let capture = try await runtime.capture(nodeID: nodeID)
    #expect(capture.pixelWidth == 2)
    #expect(capture.pngData == Data([2]))
  }

  @Test("Navigation failures are visible and clear on retry")
  func navigationFailure() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://missing.example")

    try await runtime.reportLoaded(
      nodeID: nodeID,
      url: "https://missing.example",
      title: nil,
      canGoBack: false,
      canGoForward: false,
      isLoading: false,
      errorMessage: "The server could not be found."
    )
    #expect(await runtime.state(nodeID: nodeID)?.errorMessage == "The server could not be found.")

    let retry = try await runtime.refresh(nodeID: nodeID)
    #expect(retry.isLoading)
    #expect(retry.errorMessage == nil)
  }

  @Test("A late failure cannot overwrite a newer navigation")
  func staleNavigationFailure() async throws {
    let runtime = BrowserRuntime()
    let nodeID = UUID()
    await runtime.register(nodeID: nodeID, url: "https://old.example")
    _ = try await runtime.navigate(nodeID: nodeID, url: "https://new.example")

    try await runtime.reportLoaded(
      nodeID: nodeID,
      url: "https://old.example",
      title: nil,
      canGoBack: false,
      canGoForward: false,
      isLoading: false,
      errorMessage: "Old request failed",
      expectedRevision: 0
    )

    let current = await runtime.state(nodeID: nodeID)
    #expect(current?.url == "https://new.example")
    #expect(current?.isLoading == true)
    #expect(current?.errorMessage == nil)
  }
}

private struct EmptyBrowserSessionFixture: Codable {
  var tabs: [BrowserTab]
  var activeTabID: UUID
}

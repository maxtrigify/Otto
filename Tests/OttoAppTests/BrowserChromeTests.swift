import AppKit
import Foundation
import OttoBrowser
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Browser in Chat")
struct BrowserChromeTests {
  @Test @MainActor func pageMessageNamesTheActivePageTabsAndNode() {
    let active = BrowserTab(title: "Clay pricing", url: "https://www.clay.com/pricing")
    let other = BrowserTab(title: "Apollo — Pricing", url: "https://www.apollo.io/pricing")
    let start = BrowserTab(title: "New Tab", url: BrowserDefaults.startURL)
    var node = OttoNode(
      kind: .browser, displayName: "Browser", subtitle: "OTTO BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1)
    node.browserSession = BrowserSession(tabs: [active, other, start], activeTabID: active.id)

    let message = ChatBrowserPlace<EmptyView, EmptyView>.message("Compare these", browser: node)

    // The page details ride in Otto's hidden context envelope; the person sees only their words.
    #expect(PromptSubmission.originalUserText(message) == "Compare these")
    #expect(message.contains("Active tab: Clay pricing — https://www.clay.com/pricing"))
    #expect(message.contains("- Apollo — Pricing — https://www.apollo.io/pricing"))
    // Otto's own start page is not a page an agent can read.
    #expect(!message.contains(BrowserDefaults.startURL))
    #expect(message.contains(node.id.uuidString))
    #expect(message.contains("Ask before submitting"))
  }

  @Test func newTabBoxGuessesWhatThePersonMeant() {
    typealias Surface = OttoStartSurface
    #expect(Surface.choices(for: "") == [])
    #expect(Surface.choices(for: "clay.com") == [.open("https://clay.com"), .ask, .search])
    #expect(Surface.choices(for: "localhost:3000").first == .open("http://localhost:3000"))
    #expect(Surface.choices(for: "https://x.com/home").first == .open("https://x.com/home"))
    #expect(Surface.choices(for: "what is clay").first == .ask)
    #expect(Surface.choices(for: "best crm for startups in 2026").first == .ask)
    #expect(Surface.choices(for: "pricing?").first == .ask)
    #expect(Surface.choices(for: "weather london") == [.search, .ask])
    #expect(Surface.choices(for: "v1.2") == [.search, .ask])
    #expect(Surface.searchURL("a&b c").contains("q=a%26b%20c"))
  }

  @Test @MainActor func newTabQuestionsTellOttoToResearch() {
    let blank = BrowserTab()
    var node = OttoNode(
      kind: .browser, displayName: "Browser", subtitle: "OTTO BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 1)
    node.browserSession = BrowserSession(tabs: [blank], activeTabID: blank.id)
    let message = ChatBrowserPlace<EmptyView, EmptyView>.message("best CRMs", browser: node)
    #expect(message.contains("web research assistant"))
    #expect(message.contains("Only open a site in this browser when the request needs it"))
    #expect(PromptSubmission.originalUserText(message) == "best CRMs")
  }

  @Test func eachBrowserGetsItsOwnHelperKey() {
    let first = UUID()
    let second = UUID()
    #expect(ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(first) == "browser:\(first)")
    #expect(
      ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(first)
        != ChatBrowserPlace<EmptyView, EmptyView>.sessionKey(second))
  }

  @Test func browserIsAChatPlace() {
    #expect(ChatSurfaceDestination(rawValue: "Browser") == .browser)
    #expect(ChatSurfaceDestination.browser.title == "Browser")
  }

  /// Opt-in rendering of the new chrome in the default light theme and a dark one.
  @Test @MainActor func renderChrome() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_BROWSER_CHROME_SNAPSHOTS"]
    else { return }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let tabs = [
      BrowserTab(title: "Clay pricing — Plans", url: "https://www.clay.com/pricing"),
      BrowserTab(title: "Apollo — Pricing", url: "https://www.apollo.io/pricing"),
      BrowserTab(title: "Common Room — Plans", url: "https://www.commonroom.io/pricing"),
      BrowserTab(title: "maxtrigify/Muse · PR #41", url: "https://github.com/maxtrigify/Muse"),
    ]
    let session = BrowserSession(tabs: tabs, activeTabID: tabs[0].id)
    let state = BrowserRuntimeState(
      nodeID: UUID(), url: tabs[0].url, title: tabs[0].title, canGoBack: true,
      tabs: tabs.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) },
      activeTabID: tabs[0].id)
    var driving = state
    driving.agentControlPhase = .acting

    for theme in [OttoThemeCatalog.theme(id: "highfell"), OttoThemeCatalog.fieldNotes] {
      let palette = OttoPalette(theme: theme)
      let view = VStack(spacing: 0) {
        OttoBrowserTabStrip(
          address: .constant("clay.com/pricing"), addressFocusRequest: 0, session: session,
          state: state, pinned: OttoBrowserDefaults.bookmarks, aiVisible: false,
          navigate: { _ in }, selectTab: { _ in }, closeTab: { _ in }, newTab: {},
          submit: {}, goBack: {}, goForward: {}, reloadOrStop: {}, showImport: {},
          toggleAI: {})
        Rectangle().fill(Color.white).frame(height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 10)).padding([.horizontal, .bottom], 9)
        OttoBrowserCompactBar(
          address: .constant("https://www.linkedin.com/feed/"), addressFocusRequest: 0,
          state: driving, goBack: {}, goForward: {}, reloadOrStop: {}, submit: {},
          openInBrowser: {}
        )
        .frame(width: 660)
        HStack(spacing: 18) {
          ForEach([BrowserAgentControlPhase.observing, .acting], id: \.self) { phase in
            Rectangle().fill(Color.white).frame(width: 560, height: 340)
              .clipShape(RoundedRectangle(cornerRadius: 10))
              .overlay {
                BrowserAgentControlAura(phase: phase, cornerRadius: 10, scale: 1)
              }
          }
        }
        .padding(9)
      }
      .environment(\.ottoPalette, palette)
      .frame(width: 1200)
      .background(palette.surface)

      let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      window.setContentSize(NSSize(width: 1200, height: host.fittingSize.height))
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("chrome-\(theme.id).png"))
    }

    for (name, text) in [
      ("otto-new-tab-empty", ""), ("otto-new-tab-typed", "what is clay"),
      ("otto-new-tab-history", "linedin"),
    ] {
      let historyDefaults = UserDefaults(suiteName: "browser-chrome-snapshot")!
      historyDefaults.removePersistentDomain(forName: "browser-chrome-snapshot")
      let history = BrowserHistoryStore(defaults: historyDefaults)
      history.record(url: "https://www.linkedin.com/feed/", title: "LinkedIn")
      let page = OttoStartSurface(
        query: .constant(text), focusRequest: 0, navigate: { _ in }, askOtto: { _ in },
        history: history
      )
      .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.theme(id: "highfell")))
      .frame(width: 1100, height: 620)
      let host = NSHostingView(rootView: page)
      let window = NSWindow(
        contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 620),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(250))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // ImageRenderer draws blur faithfully, unlike cacheDisplay, so the agent glow is rendered
    // on its own over a white page and a dark page.
    let glow = HStack(spacing: 18) {
      ForEach([Color.white, Color(white: 0.1)], id: \.self) { page in
        ForEach([BrowserAgentControlPhase.observing, .acting], id: \.self) { phase in
          Rectangle().fill(page).frame(width: 420, height: 280)
            .overlay { BrowserAgentControlAura(phase: phase, cornerRadius: 10, scale: 1) }
            .overlay {
              BrowserAgentCursorShape(model: BrowserAgentCursor.Model())
                .scaleEffect(2, anchor: .topLeading)
                .frame(width: 192, height: 128, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
    }
    .padding(18)
    .background(Color(white: 0.85))
    .environment(\.ottoPalette, OttoPalette(theme: OttoThemeCatalog.fieldNotes))
    let renderer = ImageRenderer(content: glow)
    renderer.scale = 1
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("agent-glow.png"))
  }
}

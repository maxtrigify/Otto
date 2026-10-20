import Foundation
import OttoModels
import Testing

@Suite("Browser session model")
struct BrowserSessionTests {
  @Test("Tabs and active selection survive persistence")
  func roundTrip() throws {
    let first = BrowserTab(title: "Otto", url: "https://otto.example")
    let second = BrowserTab(title: "Docs", url: "https://docs.example")
    let session = BrowserSession(tabs: [first, second], activeTabID: second.id)

    let decoded = try JSONDecoder().decode(
      BrowserSession.self,
      from: JSONEncoder().encode(session)
    )

    #expect(decoded == session)
    #expect(decoded.activeTab == second)
  }

  @Test("An empty decoded-style session is normalized to a usable tab")
  func normalizesEmptyTabs() {
    let session = BrowserSession(tabs: [], activeTabID: UUID())
    #expect(session.tabs.count == 1)
    #expect(session.activeTab?.url == BrowserDefaults.blankURL)
  }

  @Test("A new tab is blank while explicit browser launches keep their destination")
  func blankTabDefault() {
    #expect(BrowserTab().url == BrowserDefaults.blankURL)
    #expect(
      BrowserSession(url: BrowserDefaults.startURL).activeTab?.url
        == BrowserDefaults.startURL)
  }

  @Test("Browser sessions persist with their canvas node")
  func nodeRoundTrip() throws {
    let session = BrowserSession(url: "https://example.com")
    let node = OttoNode(
      kind: .browser,
      displayName: "Browser",
      subtitle: BrowserDefaults.subtitle,
      frame: WorldRect(x: 0, y: 0, width: 840, height: 560),
      zIndex: 0,
      content: .browser(url: "https://example.com"),
      browserSession: session
    )

    let decoded = try JSONDecoder().decode(OttoNode.self, from: JSONEncoder().encode(node))
    #expect(decoded.browserSession == session)
  }
}

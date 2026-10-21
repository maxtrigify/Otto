import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Local browser history") @MainActor
struct BrowserHistoryTests {
  private func withStore(_ body: (BrowserHistoryStore, UserDefaults) throws -> Void) rethrows {
    let name = "browser-history-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    try body(BrowserHistoryStore(defaults: defaults), defaults)
  }

  @Test func persistsDeduplicatesAndClears() {
    withStore { store, defaults in
      store.record(url: "https://linkedin.com/feed", title: "LinkedIn")
      store.record(url: "https://example.com", title: "Example")
      store.record(url: "https://linkedin.com/feed", title: "LinkedIn feed")
      let restored = BrowserHistoryStore(defaults: defaults)
      #expect(restored.entries.count == 2)
      #expect(restored.entries.first?.title == "LinkedIn feed")
      store.clear()
      #expect(BrowserHistoryStore(defaults: defaults).entries.isEmpty)
    }
  }

  @Test func optOutAndNonWebURLs() {
    withStore { store, defaults in
      for url in [
        "about:blank", "otto://start", "file:///private/file", "https://user:secret@example.com",
      ] {
        store.record(url: url, title: "Ignored")
      }
      #expect(store.entries.isEmpty)
      store.record(url: "https://example.com", title: "Example")
      store.isEnabled = false
      store.record(url: "https://other.com", title: "Other")
      #expect(store.entries.count == 1)
      #expect(store.suggestions(for: "example").isEmpty)
      #expect(!BrowserHistoryStore(defaults: defaults).isEnabled)
    }
  }

  @Test func recallsTitlesURLsBookmarksAndSmallOmissions() {
    withStore { store, _ in
      store.record(url: "https://www.linkedin.com/feed", title: "LinkedIn")
      let bookmarks = [
        BrowserBookmark(title: "LinkedIn bookmark", url: "https://www.linkedin.com/feed")
      ]
      #expect(store.suggestions(for: "linedin").first?.title == "LinkedIn")
      #expect(store.suggestions(for: "feed").count == 1)
      #expect(store.suggestions(for: "nonsense").isEmpty)
      let matches = store.suggestions(for: "linkedin", bookmarks: bookmarks)
      #expect(matches.count == 1)
      #expect(matches.first?.isBookmark == true)
      #expect(
        OttoStartSurface.choices(for: "linkedin", suggestions: matches).first == .visit(matches[0]))
      #expect(OttoStartSurface.choices(for: "what is linkedin", suggestions: matches).first == .ask)
      #expect(OttoStartSurface.choices(for: "", suggestions: matches) == [.visit(matches[0])])
    }
  }

  @Test func boundsStoredAndDisplayedHistory() {
    withStore { store, _ in
      for index in 0...BrowserHistoryStore.limit {
        store.record(url: "https://example.com/\(index)", title: "Page \(index)")
      }
      #expect(store.entries.count == BrowserHistoryStore.limit)
      #expect(store.entries.last?.url == "https://example.com/1")
      #expect(store.suggestions(for: "").count == 4)
    }
  }
  @Test func recentlyClosedTabsStayWithinTheirBrowserAndReopenNewestFirst() {
    let closed = BrowserClosedTabs()
    let firstBrowser = UUID()
    let otherBrowser = UUID()
    for index in 0..<21 {
      closed.remember(
        BrowserTab(title: "Page", url: "https://example.com/\(index)"), nodeID: firstBrowser)
    }
    #expect(closed.pop(nodeID: otherBrowser) == nil)
    #expect(closed.pop(nodeID: firstBrowser)?.url == "https://example.com/20")
    for _ in 0..<19 { #expect(closed.pop(nodeID: firstBrowser) != nil) }
    #expect(closed.pop(nodeID: firstBrowser) == nil)
  }

}

import Combine
import Foundation
import OttoModels

struct BrowserHistoryEntry: Codable, Equatable {
  var url: String
  var title: String
  var visitedAt: Date
}

struct BrowserSuggestion: Equatable, Identifiable {
  var url: String
  var title: String
  var isBookmark: Bool = false
  var id: String { url }
}

/// Local browser recall, shared across browser views and retained across launches.
@MainActor
final class BrowserHistoryStore: ObservableObject {
  static let shared = BrowserHistoryStore()
  static let entriesKey = "otto.browser.history"
  static let enabledKey = "otto.browser.history.enabled"
  static let limit = 500
  private let defaults: UserDefaults
  @Published private(set) var entries: [BrowserHistoryEntry]
  @Published var isEnabled: Bool {
    didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    entries = Array(
      (defaults.data(forKey: Self.entriesKey).flatMap {
        try? JSONDecoder().decode([BrowserHistoryEntry].self, from: $0)
      } ?? []).prefix(Self.limit))
  }

  func record(url: String, title: String?, at date: Date = Date()) {
    guard isEnabled, let parsed = URL(string: url),
      ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
      parsed.host != nil, parsed.user == nil, parsed.password == nil
    else { return }
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? parsed.host ?? url
    // Runtime updates also include hover/agent state. Do not persist those as new visits.
    if entries.first?.url == url, entries.first?.title == resolvedTitle { return }
    entries.removeAll { $0.url == url }
    entries.insert(BrowserHistoryEntry(url: url, title: resolvedTitle, visitedAt: date), at: 0)
    entries = Array(entries.prefix(Self.limit))
    persist()
  }

  func clear() {
    entries = []
    defaults.removeObject(forKey: Self.entriesKey)
  }

  func suggestions(for query: String, bookmarks: [BrowserBookmark] = []) -> [BrowserSuggestion] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var seen = Set<String>()
    let candidates =
      bookmarks.map {
        BrowserSuggestion(url: $0.url, title: $0.title, isBookmark: true)
      } + (isEnabled ? entries.map { BrowserSuggestion(url: $0.url, title: $0.title) } : [])
    return Array(
      candidates.filter { candidate in
        guard let url = URL(string: candidate.url),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.user == nil, url.password == nil,
          seen.insert(candidate.url).inserted
        else { return false }
        if query.isEmpty { return true }
        let title = candidate.title.lowercased()
        let host = url.host?.lowercased() ?? ""
        if title.contains(query) || candidate.url.lowercased().contains(query) { return true }
        // Small omissions still recall a site: "linedin" matches "linkedin.com".
        guard query.count >= 3, !query.contains(" ") else { return false }
        var remaining = query.makeIterator()
        var next = remaining.next()
        for character in host where character == next { next = remaining.next() }
        return next == nil
      }.prefix(4))
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.entriesKey) }
  }
}

/// Keep recently closed tabs when the person switches between Chat and Browser.
/// This lasts for the app session and never crosses browser nodes.
@MainActor
final class BrowserClosedTabs {
  static let shared = BrowserClosedTabs()
  private var tabs: [UUID: [BrowserTab]] = [:]

  func remember(_ tab: BrowserTab, nodeID: UUID) {
    guard tab.url.hasPrefix("http") else { return }
    tabs[nodeID] = Array(((tabs[nodeID] ?? []) + [tab]).suffix(20))
  }

  func pop(nodeID: UUID) -> BrowserTab? {
    guard var closed = tabs[nodeID], let tab = closed.popLast() else { return nil }
    if closed.isEmpty { tabs.removeValue(forKey: nodeID) } else { tabs[nodeID] = closed }
    return tab
  }
}

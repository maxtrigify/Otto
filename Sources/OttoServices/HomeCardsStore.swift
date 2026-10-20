import Combine
import Foundation
import OttoModels

/// The cards on this space's Home page. Stored with the space, so each space has its own.
@MainActor
public final class HomeCardsStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var cards: [HomeCard] = []
    /// Optional so files written before dashboards existed still decode.
    var dashboards: [Dashboard]?
  }

  public enum CardError: Error, LocalizedError {
    case emptyTitle
    case unknownCard(String)
    case tooMany
    case unknownDashboard(String)
    case duplicateDashboard
    public var errorDescription: String? {
      switch self {
      case .emptyTitle: "Give the card a title."
      case .unknownCard(let name): "There is no card called \"\(name)\"."
      case .tooMany: "A page holds at most \(HomeCardsStore.limit) cards. Remove one first."
      case .unknownDashboard(let name): "There is no dashboard called \"\(name)\"."
      case .duplicateDashboard: "A dashboard with that name already exists."
      }
    }
  }

  public nonisolated static let limit = 24

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/home-cards.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  /// Every card, on Home and on dashboards.
  public var allCards: [HomeCard] { state.cards }
  /// The cards on Home.
  public var cards: [HomeCard] { cards(on: nil) }
  public func cards(on dashboardID: UUID?) -> [HomeCard] {
    state.cards.filter { $0.dashboardID == dashboardID }
  }

  public func card(id: UUID) -> HomeCard? { state.cards.first { $0.id == id } }

  /// Finds a card on one page (Home when `dashboardID` is nil) by id, exact title, or a clearly
  /// matching title. Ids are found anywhere.
  public func card(named reference: String, on dashboardID: UUID? = nil) -> HomeCard? {
    let key = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = UUID(uuidString: key) { return card(id: id) }
    let page = cards(on: dashboardID)
    if let exact = page.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) {
      return exact
    }
    let ranked = page.map { ($0, HomeCard.titleSimilarity($0.title, key)) }
      .filter { $0.1 >= 0.99 }
    return ranked.count == 1 ? ranked[0].0 : nil
  }

  /// Cards about the same thing on the same page, best first, so agents can offer "add to
  /// the existing one".
  public func similarCards(to title: String, on dashboardID: UUID? = nil) -> [HomeCard] {
    cards(on: dashboardID).map { ($0, HomeCard.titleSimilarity($0.title, title)) }
      .filter { $0.1 >= 0.5 }
      .sorted { $0.1 > $1.1 }
      .map(\.0)
  }

  // MARK: Dashboards

  public var dashboards: [Dashboard] { state.dashboards ?? [] }

  public func dashboard(id: UUID) -> Dashboard? { dashboards.first { $0.id == id } }

  public func dashboard(named reference: String) -> Dashboard? {
    let key = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = UUID(uuidString: key) { return dashboard(id: id) }
    return dashboards.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
      ?? {
        let close = dashboards.filter { HomeCard.titleSimilarity($0.name, key) >= 0.99 }
        return close.count == 1 ? close[0] : nil
      }()
  }

  @discardableResult
  public func createDashboard(name: String, symbol: String = "chart.bar.xaxis") throws -> Dashboard
  {
    let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    guard !trimmed.isEmpty else { throw CardError.emptyTitle }
    guard
      !dashboards.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { throw CardError.duplicateDashboard }
    let dashboard = Dashboard(name: trimmed, symbol: symbol)
    var next = state
    next.dashboards = dashboards + [dashboard]
    try persist(next)
    return dashboard
  }

  public func renameDashboard(id: UUID, to name: String) throws {
    let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    guard !trimmed.isEmpty else { throw CardError.emptyTitle }
    guard let index = dashboards.firstIndex(where: { $0.id == id }) else {
      throw CardError.unknownDashboard(id.uuidString)
    }
    var next = state
    next.dashboards?[index].name = trimmed
    try persist(next)
  }

  /// Changes a dashboard's look: accent colour, card style or icon.
  public func updateDashboard(id: UUID, _ change: (inout Dashboard) -> Void) throws {
    guard let index = dashboards.firstIndex(where: { $0.id == id }) else {
      throw CardError.unknownDashboard(id.uuidString)
    }
    var next = state
    var dashboard = dashboards[index]
    let name = dashboard.name
    change(&dashboard)
    dashboard.name = name
    next.dashboards?[index] = dashboard
    try persist(next)
  }

  /// Removes a dashboard and its cards. Returns what was removed so the caller can undo.
  @discardableResult
  public func deleteDashboard(id: UUID) throws -> (Dashboard, [HomeCard])? {
    guard let dashboard = dashboard(id: id) else { return nil }
    let removed = cards(on: id)
    var next = state
    next.dashboards = dashboards.filter { $0.id != id }
    next.cards.removeAll { $0.dashboardID == id }
    try persist(next)
    return (dashboard, removed)
  }

  public func restoreDashboard(_ dashboard: Dashboard, cards restored: [HomeCard]) throws {
    guard self.dashboard(id: dashboard.id) == nil else { return }
    var next = state
    next.dashboards = dashboards + [dashboard]
    next.cards += restored
    try persist(next)
  }

  @discardableResult
  public func add(_ card: HomeCard) throws -> HomeCard {
    var card = card
    card.title = card.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !card.title.isEmpty else { throw CardError.emptyTitle }
    guard cards(on: card.dashboardID).count < Self.limit else { throw CardError.tooMany }
    card.title = String(card.title.prefix(60))
    var next = state
    next.cards.append(card)
    try persist(next)
    return card
  }

  @discardableResult
  public func update(id: UUID, _ change: (inout HomeCard) -> Void) throws -> HomeCard {
    guard let index = state.cards.firstIndex(where: { $0.id == id }) else {
      throw CardError.unknownCard(id.uuidString)
    }
    var next = state
    change(&next.cards[index])
    next.cards[index].title = String(
      next.cards[index].title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    guard !next.cards[index].title.isEmpty else { throw CardError.emptyTitle }
    try persist(next)
    return next.cards[index]
  }

  @discardableResult
  public func remove(id: UUID) throws -> HomeCard? {
    guard let card = card(id: id) else { return nil }
    var next = state
    next.cards.removeAll { $0.id == id }
    try persist(next)
    return card
  }

  /// Puts a removed card back where it was (undo).
  public func restore(_ card: HomeCard, at index: Int) throws {
    guard self.card(id: card.id) == nil else { return }
    var next = state
    next.cards.insert(card, at: min(max(0, index), next.cards.count))
    try persist(next)
  }

  /// Swaps a card with its neighbour on the same page.
  public func move(id: UUID, by offset: Int) throws {
    guard let card = card(id: id), offset != 0 else { return }
    let siblings = state.cards.indices.filter { state.cards[$0].dashboardID == card.dashboardID }
    guard let position = siblings.firstIndex(where: { state.cards[$0].id == id }) else { return }
    let target = min(max(0, position + offset), siblings.count - 1)
    guard target != position else { return }
    var next = state
    next.cards.swapAt(siblings[position], siblings[target])
    try persist(next)
  }

  /// Moves a card to where `target` sits on the same page, shifting the others along (drag and
  /// drop). Dropping onto a later card puts the moved one after it.
  public func move(id: UUID, to target: UUID) throws {
    guard id != target, let card = card(id: id), let goal = self.card(id: target),
      card.dashboardID == goal.dashboardID
    else { return }
    let siblings = state.cards.filter { $0.dashboardID == card.dashboardID }
    guard let from = siblings.firstIndex(where: { $0.id == id }),
      let to = siblings.firstIndex(where: { $0.id == target })
    else { return }
    var reordered = siblings
    reordered.remove(at: from)
    reordered.insert(card, at: to)
    // Put the page's cards back into the slots they held, in their new order.
    var next = state
    var queue = reordered.makeIterator()
    for index in next.cards.indices where next.cards[index].dashboardID == card.dashboardID {
      if let card = queue.next() { next.cards[index] = card }
    }
    try persist(next)
  }

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }
}

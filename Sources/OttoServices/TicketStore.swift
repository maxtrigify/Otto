import Combine
import Foundation
import OttoModels

/// Tickets for this space: work handed to bots, with the story of how each one went.
@MainActor
public final class TicketStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var nextNumber = 1
    var tickets: [Ticket] = []
  }

  public enum TicketError: Error, LocalizedError, Equatable {
    case unknown
    case emptyTitle
    case tooMany
    case tooDeep
    case wrongStatus(String)
    case ownReview
    case notYours
    public var errorDescription: String? {
      switch self {
      case .unknown: "That ticket no longer exists."
      case .emptyTitle: "A ticket needs a title."
      case .tooMany:
        "\(TicketStore.openLimit) tickets are already open. Finish or close some first."
      case .tooDeep:
        "Tickets can be split \(TicketStore.maximumDepth) levels deep. Do this one as it is."
      case .wrongStatus(let reason): reason
      case .ownReview: "A bot can't review its own work. Pick another reviewer."
      case .notYours: "Only the bot a ticket is assigned to can report on it."
      }
    }
  }

  public nonisolated static let openLimit = 200
  /// A ticket, its sub-tickets and theirs. Deeper than this is a sign of runaway splitting.
  public nonisolated static let maximumDepth = 3
  public nonisolated static let maximumTextCharacters = 4_000
  public nonisolated static let maximumEvents = 200
  /// Finished tickets are kept this long, then dropped when a new one is added.
  public nonisolated static let doneRetention: TimeInterval = 60 * 86_400

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/tickets.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  public var all: [Ticket] { state.tickets }
  public var open: [Ticket] { state.tickets.filter(\.isOpen) }
  public var needingPerson: [Ticket] {
    state.tickets.filter(\.needsPerson).sorted { $0.updatedAt < $1.updatedAt }
  }

  public func ticket(id: UUID) -> Ticket? { state.tickets.first { $0.id == id } }
  public func ticket(number: Int) -> Ticket? { state.tickets.first { $0.number == number } }
  public func children(of id: UUID) -> [Ticket] {
    state.tickets.filter { $0.parentID == id }.sorted { $0.number < $1.number }
  }

  /// How many parents sit above a ticket: 0 for a top-level one.
  public func depth(of id: UUID) -> Int {
    var depth = 0
    var current = ticket(id: id)?.parentID
    while let parent = current, depth < 16 {
      depth += 1
      current = ticket(id: parent)?.parentID
    }
    return depth
  }

  @discardableResult
  public func add(_ ticket: Ticket, now: Date = .now) throws -> Ticket {
    var ticket = ticket
    ticket.title = String(ticket.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    guard !ticket.title.isEmpty else { throw TicketError.emptyTitle }
    guard open.count < Self.openLimit else { throw TicketError.tooMany }
    if let parentID = ticket.parentID {
      guard self.ticket(id: parentID) != nil else { throw TicketError.unknown }
      guard depth(of: parentID) + 1 < Self.maximumDepth else { throw TicketError.tooDeep }
    }
    ticket.task = Self.clip(ticket.task)
    if ticket.task.isEmpty { ticket.task = ticket.title }
    ticket.limits = ticket.limits.map(Self.clip).flatMap { $0.isEmpty ? nil : $0 }
    ticket.handsBack = ticket.handsBack.map(Self.clip).flatMap { $0.isEmpty ? nil : $0 }
    var next = state
    ticket.number = next.nextNumber
    next.nextNumber += 1
    next.tickets = next.tickets.filter {
      $0.isOpen || ($0.closedAt ?? $0.updatedAt) > now.addingTimeInterval(-Self.doneRetention)
    }
    next.tickets.append(ticket)
    try persist(next)
    return ticket
  }

  @discardableResult
  public func update(id: UUID, _ change: (inout Ticket) throws -> Void) throws -> Ticket {
    guard let index = state.tickets.firstIndex(where: { $0.id == id }) else {
      throw TicketError.unknown
    }
    var next = state
    try change(&next.tickets[index])
    next.tickets[index].updatedAt = .now
    if next.tickets[index].events.count > Self.maximumEvents {
      // Keep how it started and the most recent part of the story.
      let events = next.tickets[index].events
      next.tickets[index].events =
        Array(events.prefix(1)) + events.suffix(Self.maximumEvents - 1)
    }
    try persist(next)
    return next.tickets[index]
  }

  public func remove(id: UUID) throws {
    var next = state
    next.tickets.removeAll { $0.id == id }
    for index in next.tickets.indices where next.tickets[index].parentID == id {
      next.tickets[index].parentID = nil
    }
    try persist(next)
  }

  nonisolated static func clip(_ text: String) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumTextCharacters))
  }

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }
}

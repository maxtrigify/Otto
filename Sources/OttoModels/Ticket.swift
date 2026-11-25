import Foundation

/// A piece of work handed to a bot: what to do, the limits, what to hand back, who owns it and
/// who checks it. The events are the story of how it went, written by Otto and by the bots
/// themselves, so a person can see why something happened without reading a transcript.
public struct Ticket: Codable, Identifiable, Sendable, Equatable {
  public enum Status: String, Codable, Sendable, Equatable, CaseIterable {
    case todo
    case doing
    /// The bot can't go on without an answer from the person.
    case blocked
    /// The bot handed its work back and the reviewer has not decided yet.
    case review
    case done
  }

  /// Someone who can create or review a ticket.
  public enum Party: Codable, Sendable, Equatable, Hashable {
    case person
    case bot(UUID)
    /// A one-off session, kept by name because sessions come and go.
    case session(String)
  }

  public struct Event: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
      case created
      case assigned
      /// A bot's own reason for a decision: why it split the work, why it chose a bot.
      case note
      case handedBack
      case blocked
      case answered
      case approved
      case sentBack
      /// The bot ended its turn without reporting on the ticket.
      case unreported
      case problem
      /// Otto's checker went over the work against the standards before review.
      case checked

      /// A newer Otto's event kind reads as a plain note, so the file still opens.
      public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .note
      }
    }

    public var id: UUID
    public var kind: Kind
    public var actor: Party
    public var text: String
    public var at: Date

    public init(id: UUID = UUID(), kind: Kind, actor: Party, text: String, at: Date = .now) {
      self.id = id
      self.kind = kind
      self.actor = actor
      self.text = text
      self.at = at
    }
  }

  public var id: UUID
  /// The short number people say out loud: T-14.
  public var number: Int
  public var title: String
  public var task: String
  public var limits: String?
  public var handsBack: String?
  public var status: Status
  public var assigneeProfileID: UUID?
  public var reviewer: Party
  public var creator: Party
  public var parentID: UUID?
  /// What the bot handed back, shown to the reviewer.
  public var result: String?
  /// What the bot is stuck on, when blocked.
  public var question: String?
  /// The chat the work is happening in, so the ticket can open it.
  public var agentNodeID: UUID?
  /// When the brief last reached the bot; a finished turn after this with no report is flagged.
  public var dispatchedAt: Date?
  /// Set while a ticket the CEO handed out waits for the person to start it.
  public var awaitingGoAhead: Bool?
  /// Standards for this ticket only, on top of the ones the bot keeps.
  public var standards: [String]?
  /// Every check of handed-back work, oldest first.
  public var checks: [StandardsCheck]?
  /// Handed back and being checked; it reaches the reviewer when the check is done.
  public var checking: Bool?
  public var events: [Event]
  public var createdAt: Date
  public var updatedAt: Date
  public var closedAt: Date?

  public init(
    id: UUID = UUID(), number: Int = 0, title: String, task: String, limits: String? = nil,
    handsBack: String? = nil, status: Status = .todo, assigneeProfileID: UUID? = nil,
    reviewer: Party = .person, creator: Party = .person, parentID: UUID? = nil,
    events: [Event] = [], createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.number = number
    self.title = title
    self.task = task
    self.limits = limits
    self.handsBack = handsBack
    self.status = status
    self.assigneeProfileID = assigneeProfileID
    self.reviewer = reviewer
    self.creator = creator
    self.parentID = parentID
    self.events = events
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var label: String { "T-\(number)" }
  public var isOpen: Bool { status != .done }
  /// The bot stopped without saying whether it finished.
  public var isUnreported: Bool { status == .doing && events.last?.kind == .unreported }
  public var isChecking: Bool { checking == true }
  /// The newest check, shown on the ticket.
  public var latestCheck: StandardsCheck? { checks?.last }
  /// How many times the current hand-back has been checked: counted since the person last sent
  /// it back or it was given to a bot, so a fresh round always gets its full tries.
  public var checksThisRound: Int {
    guard let checks, !checks.isEmpty else { return 0 }
    let roundStart =
      events.last(where: { $0.kind == .sentBack || $0.kind == .assigned })?.at ?? .distantPast
    return checks.filter { $0.checkedAt >= roundStart }.count
  }
  /// Given to a bot, but the brief has not reached it yet.
  public var isStarting: Bool { status == .doing && dispatchedAt == nil }
  /// It has an owner but the brief never reached them: the bot couldn't be started, or Otto
  /// closed first.
  public var isUndelivered: Bool { status == .todo && assigneeProfileID != nil && !isHeld }
  /// The CEO wants to give this to a bot, and the person asked to be the one who starts it.
  public var isHeld: Bool { status == .todo && assigneeProfileID != nil && awaitingGoAhead == true }
  /// Waiting on the person: their review, their answer, a bot that went quiet, or a brief
  /// that never arrived.
  public var needsPerson: Bool {
    switch status {
    case .review: reviewer == .person
    case .blocked: true
    case .doing: isUnreported
    case .todo: isUndelivered || isHeld
    case .done: false
    }
  }

  /// The brief as the bot reads it.
  public var brief: String {
    var lines = ["TASK: \(task)"]
    if let limits, !limits.isEmpty { lines.append("LIMITS: \(limits)") }
    if let handsBack, !handsBack.isEmpty { lines.append("HANDS BACK: \(handsBack)") }
    return lines.joined(separator: "\n")
  }
}

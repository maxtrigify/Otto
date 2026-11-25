import Foundation

/// One thing a bot's work must get right, in the person's words: "Spell Clippng with two p's",
/// "Under 60 seconds". Otto checks work against these before it reaches the reviewer (#127).
public struct BotStandard: Codable, Identifiable, Sendable, Equatable {
  /// Where the standard came from, shown under it so the person knows why it is there.
  public enum Source: Codable, Sendable, Equatable {
    case person
    /// Saved from the note the person wrote when sending a ticket back.
    case note(ticket: String)
  }

  public var id: UUID
  public var text: String
  public var source: Source
  public var createdAt: Date

  public init(id: UUID = UUID(), text: String, source: Source = .person, createdAt: Date = .now) {
    self.id = id
    self.text = text
    self.source = source
    self.createdAt = createdAt
  }
}

/// One pass of the checker over a piece of handed-back work.
public struct StandardsCheck: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable, Equatable {
    case pass
    case fail
    /// The checker could not tell from what it was given. Never counted as a pass.
    case unsure
  }

  public struct Verdict: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var standard: String
    public var outcome: Outcome
    /// What the checker saw: a quote, a measurement, a timestamp.
    public var evidence: String
    /// Written on this ticket rather than kept by the bot.
    public var ticketOnly: Bool

    public init(
      id: UUID = UUID(), standard: String, outcome: Outcome, evidence: String,
      ticketOnly: Bool = false
    ) {
      self.id = id
      self.standard = standard
      self.outcome = outcome
      self.evidence = evidence
      self.ticketOnly = ticketOnly
    }
  }

  public var checkedAt: Date
  /// The model that judged, e.g. "OpenAI gpt-5.6".
  public var checker: String
  /// 1 for the first check of this hand-back, 2 after the bot fixed what failed, and so on.
  public var attempt: Int
  public var verdicts: [Verdict]

  public init(checkedAt: Date = .now, checker: String, attempt: Int, verdicts: [Verdict]) {
    self.checkedAt = checkedAt
    self.checker = checker
    self.attempt = attempt
    self.verdicts = verdicts
  }

  public var failures: [Verdict] { verdicts.filter { $0.outcome == .fail } }
  public var unsure: [Verdict] { verdicts.filter { $0.outcome == .unsure } }
  public var passed: [Verdict] { verdicts.filter { $0.outcome == .pass } }

  /// "6 of 7 passed · 1 it couldn't judge".
  public var summary: String {
    var parts = ["\(passed.count) of \(verdicts.count) passed"]
    if !failures.isEmpty { parts.append("\(failures.count) failed") }
    if !unsure.isEmpty {
      parts.append("\(unsure.count) it couldn't judge")
    }
    return parts.joined(separator: " · ")
  }
}

/// A standard Otto suggests from a send-back note, already tried on the work that was sent
/// back. Only one that fails that work is worth keeping: it would have caught the problem.
public struct StandardProposal: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var text: String
  /// True when the work that was sent back fails this standard.
  public var catchesIt: Bool
  public var evidence: String

  public init(id: UUID = UUID(), text: String, catchesIt: Bool, evidence: String) {
    self.id = id
    self.text = text
    self.catchesIt = catchesIt
    self.evidence = evidence
  }
}

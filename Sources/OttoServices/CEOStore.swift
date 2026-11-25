import Combine
import Foundation
import OttoModels

/// The rules the person has set for their CEO. Each one is enforced by Otto, whatever the bot's
/// own permission mode is.
public struct CEORules: Codable, Equatable, Sendable {
  public enum HandOut: String, Codable, Sendable, CaseIterable {
    /// The CEO gives work to its team and they start straight away.
    case auto
    /// The part waits on the ticket until the person starts it.
    case ask
  }
  public enum Reviews: String, Codable, Sendable, CaseIterable {
    /// The CEO checks its team's work before it comes to the person.
    case ceo
    /// Every part comes to the person.
    case person
  }
  public enum Finish: String, Codable, Sendable, CaseIterable {
    /// The person approves the CEO's finished result.
    case review
    /// The CEO's finished result counts as done without the person checking it.
    case auto
  }
  /// A rule the person wrote themselves. The CEO is told it on every turn; Otto can't check
  /// free text, so unlike the other rules these are followed, not enforced.
  public struct Custom: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable, CaseIterable {
      case does
      case asks
      case never
    }
    public var id: UUID
    public var level: Level
    public var text: String
    public init(id: UUID = UUID(), level: Level, text: String) {
      self.id = id
      self.level = level
      self.text = text
    }
  }

  public var handOut: HandOut
  public var reviews: Reviews
  /// How many parts one ticket may be split into.
  public var maxParts: Int
  /// How many tickets the CEO may create in a day before it has to stop and say so.
  public var maxPerDay: Int
  /// Whether the person checks the CEO's own finished result.
  public var finish: Finish
  /// Whether the CEO may approve or send back a part the person was down to review.
  public var approvesForPerson: Bool
  public var custom: [Custom]

  public init(
    handOut: HandOut = .auto, reviews: Reviews = .ceo, maxParts: Int = 6, maxPerDay: Int = 30,
    finish: Finish = .review, approvesForPerson: Bool = false, custom: [Custom] = []
  ) {
    self.handOut = handOut
    self.reviews = reviews
    self.maxParts = maxParts
    self.maxPerDay = maxPerDay
    self.finish = finish
    self.approvesForPerson = approvesForPerson
    self.custom = custom
  }

  /// Rules saved by an earlier build have fewer keys; anything missing takes its default.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let fallback = CEORules()
    handOut = try values.decodeIfPresent(HandOut.self, forKey: .handOut) ?? fallback.handOut
    reviews = try values.decodeIfPresent(Reviews.self, forKey: .reviews) ?? fallback.reviews
    maxParts = try values.decodeIfPresent(Int.self, forKey: .maxParts) ?? fallback.maxParts
    maxPerDay = try values.decodeIfPresent(Int.self, forKey: .maxPerDay) ?? fallback.maxPerDay
    finish = try values.decodeIfPresent(Finish.self, forKey: .finish) ?? fallback.finish
    approvesForPerson =
      try values.decodeIfPresent(Bool.self, forKey: .approvesForPerson) ?? false
    custom = try values.decodeIfPresent([Custom].self, forKey: .custom) ?? []
  }

  public static let maximumCustomRules = 20
  public static let maximumCustomCharacters = 240
  public static let partChoices = [3, 6, 10]
  public static let dailyChoices = [10, 30, 100]
}

/// Which bot, if any, is this space's CEO: the one bot that splits tickets up, hands them to
/// the others and checks what comes back. Kept in its own file rather than on the bot's
/// profile, so an older Otto opening the same space leaves it alone.
@MainActor
public final class CEOStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var profileID: UUID?
    /// The bots the CEO may give work to. Nil means every bot in the space.
    var reportIDs: [UUID]?
    /// Nil until the person changes a rule; the defaults apply.
    var rules: CEORules?
  }

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/ceo.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  public var profileID: UUID? { state.profileID }
  public var reportIDs: [UUID]? { state.reportIDs }
  public var rules: CEORules { state.rules ?? CEORules() }

  public func setRules(_ rules: CEORules) throws {
    var next = state
    next.rules = rules
    try persist(next)
  }

  /// Makes a bot the CEO, or clears the role. A new CEO starts with every bot reporting to it.
  public func set(profileID: UUID?) throws {
    guard profileID != state.profileID else { return }
    var next = state
    next.profileID = profileID
    next.reportIDs = nil
    try persist(next)
  }

  public func setReports(_ ids: [UUID]?) throws {
    var next = state
    next.reportIDs = ids
    try persist(next)
  }

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }
}

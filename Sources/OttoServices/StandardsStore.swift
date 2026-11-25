import Combine
import Foundation
import OttoModels

/// Each bot's standards: what its work must get right, checked before anything reaches the
/// reviewer (#127). Kept in its own file rather than on the bot's profile, so an older Otto
/// opening the same space leaves it alone and editing a standard doesn't revise the bot.
@MainActor
public final class StandardsStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var byBot: [UUID: [BotStandard]] = [:]
  }

  public nonisolated static let maximumPerBot = 30
  public nonisolated static let maximumCharacters = 300

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/standards.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  public func standards(for profileID: UUID) -> [BotStandard] { state.byBot[profileID] ?? [] }

  /// Replaces a bot's standards, dropping blanks and repeats and keeping the list short enough
  /// for a checker to judge well.
  public func set(_ standards: [BotStandard], for profileID: UUID) throws {
    var seen = Set<String>()
    let cleaned = standards.compactMap { standard -> BotStandard? in
      var standard = standard
      standard.text = Self.clean(standard.text)
      guard !standard.text.isEmpty, seen.insert(standard.text.lowercased()).inserted else {
        return nil
      }
      return standard
    }
    var next = state
    next.byBot[profileID] = cleaned.isEmpty ? nil : Array(cleaned.prefix(Self.maximumPerBot))
    try persist(next)
  }

  /// Adds standards to a bot, skipping any it already has.
  public func add(_ texts: [String], source: BotStandard.Source, to profileID: UUID) throws {
    let added = texts.map { BotStandard(text: $0, source: source) }
    try set(standards(for: profileID) + added, for: profileID)
  }

  nonisolated static func clean(_ text: String) -> String {
    let single = text.split(whereSeparator: \.isNewline).joined(separator: " ")
    return String(
      single.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCharacters))
  }

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }
}

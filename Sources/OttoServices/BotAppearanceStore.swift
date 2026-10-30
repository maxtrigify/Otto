#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels

private struct PersistedBotAppearance: Codable {
  var schemaVersion: Int
  var appearances: [BotAppearance]
}

/// Cosmetic avatar/pet refs. Isolated from agent-profiles.json so changing a picture
/// cannot bump a profile revision used for prompt reproducibility.
@MainActor
public final class BotAppearanceStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var appearances: [BotAppearance] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-appearance.json")
    load()
  }

  public func appearance(for profileID: UUID) -> BotAppearance? {
    appearances.first { $0.profileID == profileID }
  }

  @discardableResult
  public func save(_ candidate: BotAppearance) throws -> BotAppearance {
    var record = candidate
    record.avatarRef = record.avatarRef?.trimmingCharacters(in: .whitespacesAndNewlines)
    record.petRef = record.petRef?.trimmingCharacters(in: .whitespacesAndNewlines)
    if record.avatarRef?.isEmpty == true { record.avatarRef = nil }
    if record.petRef?.isEmpty == true { record.petRef = nil }
    record.updatedAt = .now
    if let index = appearances.firstIndex(where: { $0.profileID == record.profileID }) {
      appearances[index] = record
    } else {
      appearances.append(record)
    }
    try persist()
    return record
  }

  public func remove(profileID: UUID) throws {
    appearances.removeAll { $0.profileID == profileID }
    try persist()
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotAppearance.self, from: fileURL, fileManager: fileManager)
      {
        appearances = persisted.appearances
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot appearance: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotAppearance(
          schemaVersion: Self.currentSchemaVersion, appearances: appearances),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot appearance: \(error.localizedDescription)"
      throw error
    }
  }
}

import Combine
import Foundation
import OttoModels

private struct PersistedBotWorkingSets: Codable {
  var schemaVersion: Int
  var sets: [BotWorkingSet]
}

/// Persistent per-bot worktree / terminal / browser bindings. Ownership of a dirty
/// worktree is never silently dropped.
@MainActor
public final class BotWorkingSetStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var sets: [BotWorkingSet] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager
  private let isDirtyWorktree: (String) -> Bool

  public init(
    workspacePath: String,
    fileManager: FileManager = .default,
    isDirtyWorktree: @escaping (String) -> Bool = { _ in false }
  ) {
    self.fileManager = fileManager
    self.isDirtyWorktree = isDirtyWorktree
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-working-sets.json")
    load()
  }

  public func workingSet(for profileID: UUID) -> BotWorkingSet? {
    sets.first { $0.profileID == profileID }
  }

  @discardableResult
  public func bind(_ candidate: BotWorkingSet, replacingDirty: Bool = false) throws -> BotWorkingSet
  {
    var record = candidate
    if let existing = workingSet(for: record.profileID),
      let previous = existing.worktreePath,
      previous != record.worktreePath,
      isDirtyWorktree(previous),
      !replacingDirty
    {
      throw BotStoreError.dirtyWorktreeBound
    }
    record.updatedAt = .now
    if let index = sets.firstIndex(where: { $0.profileID == record.profileID }) {
      sets[index] = record
    } else {
      sets.append(record)
    }
    try persist()
    return record
  }

  public func clear(profileID: UUID, allowDirty: Bool = false) throws {
    if let existing = workingSet(for: profileID),
      let path = existing.worktreePath,
      isDirtyWorktree(path),
      !allowDirty
    {
      throw BotStoreError.dirtyWorktreeBound
    }
    sets.removeAll { $0.profileID == profileID }
    try persist()
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotWorkingSets.self, from: fileURL, fileManager: fileManager)
      {
        sets = persisted.sets
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot working sets: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotWorkingSets(schemaVersion: Self.currentSchemaVersion, sets: sets),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot working sets: \(error.localizedDescription)"
      throw error
    }
  }
}

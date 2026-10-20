import Combine
import Foundation
import OttoMemory
import OttoModels

private struct PersistedBotNotes: Codable {
  var schemaVersion: Int
  var snapshots: [BotNotesSnapshot]
}

/// Bounded curated notes per profile. Composed into bootstrap as a frozen snapshot;
/// disk writes after launch do not mutate the live prompt.
@MainActor
public final class BotNotesStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var snapshots: [BotNotesSnapshot] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager
  private let characterCap: Int

  public init(
    workspacePath: String,
    fileManager: FileManager = .default,
    characterCap: Int = BotPromptInjectionScanner.notesCharacterCap
  ) {
    self.fileManager = fileManager
    self.characterCap = characterCap
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-notes.json")
    load()
  }

  public func snapshot(for profileID: UUID) -> BotNotesSnapshot {
    snapshots.first { $0.profileID == profileID } ?? BotNotesSnapshot(profileID: profileID)
  }

  /// Creates the private notes vault if this profile does not have one yet.
  @discardableResult
  public func ensure(profileID: UUID) throws -> BotNotesSnapshot {
    if let existing = snapshots.first(where: { $0.profileID == profileID }) { return existing }
    let snap = BotNotesSnapshot(profileID: profileID)
    try persist(snap)
    return snap
  }

  public func note(id: UUID, profileID: UUID) -> BotNote? {
    snapshot(for: profileID).notes.first { $0.id == id }
  }

  @discardableResult
  public func add(profileID: UUID, body: String) throws -> BotNote {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    try Self.validate(body: trimmed, existing: snapshot(for: profileID), replacing: nil)
    let note = BotNote(profileID: profileID, body: trimmed)
    var snap = snapshot(for: profileID)
    snap.notes.append(note)
    try persist(snap)
    return note
  }

  @discardableResult
  public func replace(profileID: UUID, noteID: UUID, body: String) throws -> BotNote {
    var snap = snapshot(for: profileID)
    guard let index = snap.notes.firstIndex(where: { $0.id == noteID }) else {
      throw BotStoreError.profileNotFound
    }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    try Self.validate(body: trimmed, existing: snap, replacing: noteID)
    snap.notes[index].body = trimmed
    snap.notes[index].updatedAt = .now
    try persist(snap)
    return snap.notes[index]
  }

  public func remove(profileID: UUID, noteID: UUID) throws {
    var snap = snapshot(for: profileID)
    snap.notes.removeAll { $0.id == noteID }
    try persist(snap)
  }

  @discardableResult
  public func archive(profileID: UUID, at date: Date = .now) throws -> BotNotesSnapshot? {
    guard let index = snapshots.firstIndex(where: { $0.profileID == profileID }) else {
      return nil
    }
    snapshots[index].archived = true
    snapshots[index].archivedAt = date
    try persistAll()
    return snapshots[index]
  }

  @discardableResult
  public func restore(profileID: UUID) throws -> BotNotesSnapshot? {
    guard let index = snapshots.firstIndex(where: { $0.profileID == profileID }) else {
      return nil
    }
    snapshots[index].archived = false
    snapshots[index].archivedAt = nil
    try persistAll()
    return snapshots[index]
  }

  /// Compensating delete for an aggregate that never became user-visible.
  func removeForCreationRollback(profileID: UUID) throws {
    snapshots.removeAll { $0.profileID == profileID }
    try persistAll()
  }

  @discardableResult
  public func clone(from sourceProfileID: UUID, to targetProfileID: UUID) throws -> BotNotesSnapshot
  {
    let source = snapshot(for: sourceProfileID)
    let cloned = BotNotesSnapshot(
      profileID: targetProfileID,
      notes: source.notes.map { note in
        BotNote(profileID: targetProfileID, body: note.body, createdAt: note.createdAt)
      }
    )
    try persist(cloned)
    return cloned
  }

  /// Frozen text for bootstrap. Rejects injection patterns at compose time even if they
  /// slipped past an older writer.
  public func composeFrozenNotes(for profileID: UUID) throws -> String? {
    let snap = snapshot(for: profileID)
    guard !snap.archived, !snap.notes.isEmpty else { return nil }
    let body = snap.composedBody
    if let hit = BotPromptInjectionScanner.firstStrictHit(in: body) {
      throw BotStoreError.injectionPattern(hit)
    }
    return body
  }

  static func validate(body: String, existing: BotNotesSnapshot, replacing: UUID?) throws {
    if let hit = BotPromptInjectionScanner.firstStrictHit(in: body) {
      throw BotStoreError.injectionPattern(hit)
    }
    if let marker = MemorySecretScanner.firstSecretMarker(in: body) {
      throw BotStoreError.secretDetected(marker)
    }
    let others = existing.notes.filter { $0.id != replacing }.map(\.body).joined().count
    let total = others + body.count
    if total > BotPromptInjectionScanner.notesCharacterCap {
      throw BotStoreError.notesTooLong(limit: BotPromptInjectionScanner.notesCharacterCap)
    }
  }

  private func persist(_ snap: BotNotesSnapshot) throws {
    if let index = snapshots.firstIndex(where: { $0.profileID == snap.profileID }) {
      snapshots[index] = snap
    } else {
      snapshots.append(snap)
    }
    try persistAll()
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotNotes.self, from: fileURL, fileManager: fileManager)
      {
        snapshots = persisted.snapshots
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot notes: \(error.localizedDescription)"
    }
  }

  private func persistAll() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotNotes(schemaVersion: Self.currentSchemaVersion, snapshots: snapshots),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot notes: \(error.localizedDescription)"
      throw error
    }
  }
}

/// Local credential markers so the notes store does not depend on OttoMemory at compile time
/// beyond what ApplicationServices already uses. Matches RecipeValidator / MemorySecretScanner.
enum MemoryLikeSecret {
  private static let markers = [
    "-----BEGIN ", "AKIA", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
    "xoxb-", "xoxp-", "sk-ant-", "sk-proj-", "Bearer ",
  ]

  static func firstMarker(in text: String) -> String? {
    let lower = text
    return markers.first { lower.contains($0) }
  }
}

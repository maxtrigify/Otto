import Foundation
import OttoModels

private struct PersistedSkillDrafts: Codable {
  var schemaVersion: Int
  var drafts: [BotSkillDraft]
}

/// Demonstration → skill landing surface. Drafts never auto-arm.
@MainActor
public final class BotSkillDraftStore {
  public static let currentSchemaVersion = 1

  public private(set) var drafts: [BotSkillDraft] = []
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-skill-drafts.json")
    if let persisted = try? WorkspaceJSONFile.load(
      PersistedSkillDrafts.self, from: fileURL, fileManager: fileManager)
    {
      drafts = persisted.drafts
    }
  }

  @discardableResult
  public func propose(_ draft: BotSkillDraft) throws -> BotSkillDraft {
    var record = draft
    record.status = .pendingReview
    if let hit = BotPromptInjectionScanner.firstStrictHit(in: record.body) {
      throw BotStoreError.injectionPattern(hit)
    }
    drafts.append(record)
    try persist()
    return record
  }

  @discardableResult
  public func approve(id: UUID) throws -> BotSkillDraft {
    guard let index = drafts.firstIndex(where: { $0.id == id }) else {
      throw BotStoreError.draftOnly
    }
    drafts[index].status = .approved
    try persist()
    return drafts[index]
  }

  private func persist() throws {
    try WorkspaceJSONFile.save(
      PersistedSkillDrafts(schemaVersion: Self.currentSchemaVersion, drafts: drafts),
      to: fileURL,
      fileManager: fileManager
    )
  }
}

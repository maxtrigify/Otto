import Combine
import Foundation
import OttoModels

private struct PersistedBotContextProjections: Codable {
  var schemaVersion: Int
  var projections: [BotChannelContextProjection]
}

@MainActor
public final class BotChannelContextStore: ObservableObject {
  public static let currentSchemaVersion = 1
  public static let defaultTokenThreshold = 8_000
  public static let recentMessageLimit = 16

  @Published public private(set) var projections: [BotChannelContextProjection] = []
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager
  private let tokenThreshold: Int

  public init(
    workspacePath: String, fileManager: FileManager = .default,
    tokenThreshold: Int = BotChannelContextStore.defaultTokenThreshold
  ) {
    self.fileManager = fileManager
    self.tokenThreshold = tokenThreshold
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-context-projections.json")
    load()
  }

  public func projection(channelID: UUID) -> BotChannelContextProjection? {
    projections.first { $0.channelID == channelID }
  }

  @discardableResult
  public func project(channelID: UUID, messages: [BotContextMessage]) throws
    -> BotChannelContextProjection
  {
    let existing =
      projection(channelID: channelID)
      ?? BotChannelContextProjection(channelID: channelID)
    let generationMessages = messages.filter { $0.createdAt >= existing.generationStartedAt }
    if existing.sourceEndID == generationMessages.last?.id { return existing }
    let estimated = Self.estimatedTokens(generationMessages)
    let shouldCompact = estimated > tokenThreshold
    let compacted =
      shouldCompact
      ? Array(generationMessages.dropLast(Self.recentMessageLimit)) : []
    let recent =
      shouldCompact
      ? Array(generationMessages.suffix(Self.recentMessageLimit)) : generationMessages
    var projection = existing
    projection.sourceStartID = generationMessages.first?.id
    projection.sourceEndID = generationMessages.last?.id
    projection.estimatedTokenCount = estimated
    projection.recentMessages = recent
    if shouldCompact {
      projection.summaryProvenance = compacted.map(\.id)
      projection.summary = Self.summary(compacted)
      projection.decisions = Self.merge(
        existing.decisions, Self.extract(compacted, markers: ["decided", "decision:"]))
      projection.openWork = Self.openWork(compacted)
      projection.completedResults = Self.merge(
        existing.completedResults, Self.extract(compacted, markers: ["completed", "done:"]))
      projection.artifacts = Self.merge(
        existing.artifacts,
        Self.extract(
          compacted, markers: ["artifact:", "file:", "http://", "https://"]))
      projection.constraints = Self.merge(
        existing.constraints, Self.extract(compacted, markers: ["constraint:", "must "]))
      projection.risks = Self.merge(
        existing.risks, Self.extract(compacted, markers: ["risk:", "blocked", "failure"]))
    }
    projection.updatedAt = .now
    if let index = projections.firstIndex(where: { $0.channelID == channelID }) {
      projections[index] = projection
    } else {
      projections.append(projection)
    }
    try persist()
    return projection
  }

  @discardableResult
  public func clear(channelID: UUID) throws -> BotChannelContextProjection {
    let projection = BotChannelContextProjection(
      channelID: channelID, generationID: UUID(), generationStartedAt: .now)
    if let index = projections.firstIndex(where: { $0.channelID == channelID }) {
      projections[index] = projection
    } else {
      projections.append(projection)
    }
    try persist()
    return projection
  }

  public func accepts(channelID: UUID, generationID: UUID) -> Bool {
    projection(channelID: channelID)?.generationID == generationID
  }

  public nonisolated static func estimatedTokens(_ messages: [BotContextMessage]) -> Int {
    messages.reduce(0) { total, message in
      total + max(1, Int(ceil(Double(message.speaker.count + message.text.count) / 4.0)))
    }
  }

  /// Bounded text for actual provider input; the projection and source transcript remain intact.
  public nonisolated static func promptText(
    _ projection: BotChannelContextProjection,
    characterBudget: Int = 8_000
  ) -> String {
    let sections = [
      ("Constraints", projection.constraints), ("Decisions", projection.decisions),
      ("Open work", projection.openWork.map { "\($0.owner): \($0.text)" }),
      ("Risks", projection.risks), ("Artifacts", projection.artifacts),
      ("Earlier context", projection.summary.map { [$0] } ?? []),
      ("Recent messages", projection.recentMessages.map { "\($0.speaker): \($0.text)" }),
    ]
    var remaining = max(0, characterBudget)
    var blocks: [String] = []
    for (title, values) in sections where !values.isEmpty && remaining > 0 {
      let block = title + ":\n" + values.joined(separator: "\n") + "\n"
      let clipped = String(block.prefix(remaining))
      blocks.append(clipped)
      remaining -= clipped.count
    }
    return blocks.joined()
  }

  private nonisolated static func summary(_ messages: [BotContextMessage]) -> String {
    let lines = messages.map { message in
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(message.speaker): \(String(text.prefix(700)))"
    }
    var bounded = lines
    while bounded.joined(separator: "\n").count > 8_000 && !bounded.isEmpty {
      bounded.removeFirst()
    }
    return bounded.joined(separator: "\n")
  }

  private nonisolated static func merge(_ previous: [String], _ current: [String]) -> [String] {
    var seen = Set<String>()
    return (previous + current).filter { seen.insert($0).inserted }
  }

  private nonisolated static func extract(
    _ messages: [BotContextMessage], markers: [String]
  ) -> [String] {
    messages.compactMap { message in
      let lower = message.text.lowercased()
      guard markers.contains(where: lower.contains) else { return nil }
      return "\(message.speaker): \(String(message.text.prefix(500)))"
    }
  }

  private nonisolated static func openWork(_ messages: [BotContextMessage]) -> [BotOwnedWork] {
    messages.compactMap { message in
      let lower = message.text.lowercased()
      guard lower.contains("todo") || lower.contains("will ") || lower.contains("owner:") else {
        return nil
      }
      return BotOwnedWork(owner: message.speaker, text: String(message.text.prefix(500)))
    }
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotContextProjections.self, from: fileURL, fileManager: fileManager)
      {
        projections = persisted.projections.map { original in
          guard original.version < BotChannelContextProjection.currentVersion else {
            return original
          }
          var migrated = original
          let label: (String) -> String = {
            $0.hasPrefix("[Project:")
              ? $0 : "[Project: legacy history; attribution not recorded] " + $0
          }
          migrated.decisions = migrated.decisions.map(label)
          migrated.constraints = migrated.constraints.map(label)
          migrated.artifacts = migrated.artifacts.map(label)
          migrated.risks = migrated.risks.map(label)
          migrated.completedResults = migrated.completedResults.map(label)
          migrated.summary = migrated.summary.map(label)
          migrated.openWork = migrated.openWork.map { work in
            var value = work
            value.owner = label(work.owner)
            return value
          }
          migrated.recentMessages = migrated.recentMessages.map { message in
            var value = message
            value.speaker = label(message.speaker)
            return value
          }
          migrated.version = BotChannelContextProjection.currentVersion
          return migrated
        }
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot context projections: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotContextProjections(
          schemaVersion: Self.currentSchemaVersion, projections: projections),
        to: fileURL, fileManager: fileManager)
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot context projections: \(error.localizedDescription)"
      throw error
    }
  }
}

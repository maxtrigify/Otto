import Foundation
import OttoModels
import Testing

@testable import OttoServices

@MainActor
@Suite("Bot channel context projections")
struct BotChannelContextStoreTests {
  @Test("Token pressure compacts model context while retaining structured ownership")
  func tokenPressureCompaction() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let channelID = UUID()
    let store = BotChannelContextStore(workspacePath: root.path, tokenThreshold: 120)
    let messages = (0..<24).map { index in
      BotContextMessage(
        speaker: index.isMultiple(of: 2) ? "Scout" : "Writer",
        text: index == 2
          ? "Decision: publish the concise version. Owner: Writer will draft it."
          : String(repeating: "Large tool result \(index). ", count: 8),
        createdAt: Date(timeIntervalSince1970: Double(index + 1)))
    }
    let projection = try store.project(channelID: channelID, messages: messages)
    #expect(projection.estimatedTokenCount > 120)
    #expect(projection.recentMessages.count == BotChannelContextStore.recentMessageLimit)
    #expect(projection.summaryProvenance.count == 8)
    #expect(projection.summary?.contains("Scout:") == true)
    #expect(projection.decisions.contains { $0.contains("publish the concise version") })
    #expect(projection.openWork.contains { $0.owner == "Scout" })

    let reloaded = BotChannelContextStore(workspacePath: root.path, tokenThreshold: 120)
    let persisted = try #require(reloaded.projection(channelID: channelID))
    #expect(persisted.generationID == projection.generationID)
    #expect(persisted.sourceEndID == projection.sourceEndID)
    #expect(persisted.summary == projection.summary)
    #expect(persisted.openWork == projection.openWork)
  }

  @Test("Clear rotates generation and fences pre-clear transcript entries")
  func generationFence() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let channelID = UUID()
    let store = BotChannelContextStore(workspacePath: root.path, tokenThreshold: 40)
    let old = BotContextMessage(
      speaker: "User", text: "Old private context", createdAt: Date(timeIntervalSinceNow: -60))
    let first = try store.project(channelID: channelID, messages: [old])
    let cleared = try store.clear(channelID: channelID)
    #expect(cleared.generationID != first.generationID)
    #expect(!store.accepts(channelID: channelID, generationID: first.generationID))

    let fresh = BotContextMessage(speaker: "User", text: "Fresh context", createdAt: .now)
    let projected = try store.project(channelID: channelID, messages: [old, fresh])
    #expect(projected.recentMessages.map(\.text) == ["Fresh context"])
    #expect(projected.summary?.contains("Old private context") != true)
  }

  @Test("Actual prompt text stays bounded and puts constraints before large tool results")
  func boundedProviderContext() {
    let projection = BotChannelContextProjection(
      channelID: UUID(),
      constraints: ["Must preserve the public API"],
      recentMessages: [
        BotContextMessage(
          speaker: "Assistant", text: String(repeating: "large result ", count: 10_000))
      ])
    let prompt = BotChannelContextStore.promptText(projection, characterBudget: 1_000)
    #expect(prompt.count <= 1_000)
    #expect(prompt.hasPrefix("Constraints:"))
    #expect(prompt.contains("Must preserve the public API"))
    #expect(projection.recentMessages.first!.text.count > 1_000)
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-context-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

import Foundation
import OttoMemory
import Testing

@Suite("Shared and private task memory")
struct AgentTaskMemoryTests {
  @Test(
    "Logs, unreviewed lessons, and other bots cannot crowd confirmed project knowledge out of retrieval"
  )
  func filteredRanking() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let brain = try ProjectBrainStore(rootPath: root.path, project: "test")
    for number in 0..<60 {
      for (prefix, type, confidence) in [
        ("log", MemoryRecordType.log, MemoryConfidence.confirmed),
        ("draft", .wiki, .proposed),
      ] {
        _ = try await brain.write(
          MemoryRecord(
            id: "\(prefix)-\(number)", type: type, project: "test", title: "launch",
            body: "launch", author: "agent", confidence: confidence, trustScore: 1),
          expectedRevision: nil)
      }
    }
    _ = try await brain.write(
      MemoryRecord(
        id: "approved-launch", type: .decision, project: "test", title: "launch",
        body: "The approved launch decision", author: "user", confidence: .confirmed),
      expectedRevision: nil)
    let pack = try await brain.contextPack(
      query: "launch", confirmedOnly: true, recordTypes: [.wiki, .decision])
    #expect(pack.recordIDs == ["approved-launch"])
  }

  @Test("Sessions share preferences and project facts; bots add only their own confirmed lessons")
  func scopedMemoryAndRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let brain = try ProjectBrainStore(rootPath: root.appending(path: "brain").path, project: "test")
    let personal = CompactMemoryStore(
      filePath: root.appending(path: "user.md").path, title: "User", budget: .personal)
    let operating = CompactMemoryStore(
      filePath: root.appending(path: "workspace.md").path, title: "Workspace", budget: .operating)
    try await personal.add(
      CompactMemoryEntry(id: "spelling", text: "Use British spelling", source: "user"))
    let bot = UUID()
    let other = UUID()
    for (id, scope, owner, confidence) in [
      ("launch-date", MemoryScope.project, nil, MemoryConfidence.confirmed),
      ("draft-launch", .project, nil, .proposed),
      ("bot-launch", .agentRole, bot, .confirmed),
      ("other-launch", .agentRole, other, .confirmed),
      ("draft-bot", .agentRole, bot, .proposed),
      ("canvas-launch", .canvas, nil, .confirmed),
    ] {
      _ = try await brain.write(
        MemoryRecord(
          id: id, type: .wiki, scope: scope, project: "test", title: id,
          body: "launch knowledge: \(id)", author: "user", confidence: confidence,
          sourceIDs: ["user:confirmed"], profileID: owner), expectedRevision: nil)
    }
    _ = try await brain.write(
      MemoryRecord(
        id: "private-conversation", type: .log, project: "test", title: "launch conversation",
        body: "launch conversation must stay out of automatic shared memory", author: "auto-log",
        confidence: .confirmed), expectedRevision: nil)
    let session = await AgentTaskMemory.context(
      query: "launch", personal: personal, operating: operating, brain: brain)
    #expect(session.contains("British spelling"))
    #expect(session.contains("launch-date"))
    #expect(!session.contains("bot-launch"))
    #expect(!session.contains("other-launch"))
    #expect(!session.contains("draft-launch"))
    #expect(!session.contains("canvas-launch"))
    #expect(!session.contains("private-conversation"))
    let botContext = await AgentTaskMemory.context(
      query: "launch", personal: personal, operating: operating, brain: brain, profileID: bot)
    #expect(botContext.contains("British spelling"))
    #expect(botContext.contains("launch-date"))
    #expect(botContext.contains("bot-launch"))
    #expect(!botContext.contains("other-launch"))
    #expect(!botContext.contains("draft-bot"))
    let record = try await brain.read(id: "bot-launch")
    _ = try await brain.archive(id: record.id, expectedRevision: record.revision)
    try await personal.add(
      CompactMemoryEntry(id: "spelling", text: "Use American spelling", source: "user correction"))
    let refreshed = await AgentTaskMemory.context(
      query: "launch", personal: personal, operating: operating, brain: brain, profileID: bot)
    #expect(refreshed.contains("American spelling"))
    #expect(!refreshed.contains("British spelling"))
    #expect(!refreshed.contains("bot-launch"))
    #expect(refreshed.contains("No confirmed private memories"))
    try await brain.delete(id: "bot-launch")
    #expect(await brain.wasDeleted(id: "bot-launch"))
    #expect(!(await brain.wasDeleted(id: "launch")))
  }
}

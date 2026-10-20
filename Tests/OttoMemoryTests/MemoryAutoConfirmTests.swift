import Foundation
import OttoMemory
import Testing

struct MemoryAutoConfirmTests {
  @Test func sourceQuarantine() {
    for prefix in MemorySourcePolicy.untrustedPrefixes {
      #expect(
        MemorySourcePolicy.confidence(for: ["user:request", " \(prefix.uppercased())example "])
          == .proposed)
    }
    #expect(
      MemorySourcePolicy.confidence(for: ["session:42", "user:request", "file:/code"]) == .confirmed
    )
  }

  @Test func recallIntent() {
    for prompt in [
      "What do you know about launch?", "Do you remember our plan?", "Did we already ship?",
      "Did we decide on a date?", "Remind me of the plan", "What's the status of release?",
      "What’s the status of release?", "What happened last time?", "History of this project",
      "Tell me about me",
    ] {
      #expect(MemoryRecallIntent.matches(prompt))
    }
    for prompt in [
      "hello", "ok", "/clear", "", "Implement login", "historical reports", "about menus",
    ] {
      #expect(!MemoryRecallIntent.matches(prompt))
    }
  }

  @Test func secretScanner() {
    for text in [
      "password=hunter2", "api_key = 'abc123'", "SECRET=abc",
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.signature",
    ] {
      #expect(MemorySecretScanner.firstSecretMarker(in: text) != nil)
    }
    for text in [
      "Use a password manager", "The secret is good testing", "api_key configuration",
      "password = ", "eyJust ordinary prose",
    ] {
      #expect(MemorySecretScanner.firstSecretMarker(in: text) == nil)
    }
  }

  @Test func metadataRejectsSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let brain = try ProjectBrainStore(rootPath: root.appending(path: "brain").path, project: "test")
    for source in [true, false] {
      let record = MemoryRecord(
        id: "secret", type: .wiki, project: "test", title: "Safe",
        body: "Safe body", author: "test", sourceIDs: source ? ["password=example"] : [],
        tags: source ? [] : ["api_key=example"])
      await #expect(throws: (any Error).self) {
        try await brain.write(record, expectedRevision: nil)
      }
    }
    let store = CompactMemoryStore(
      filePath: root.appending(path: "personal.md").path, title: "Personal", budget: .personal)
    await #expect(throws: (any Error).self) {
      try await store.add(CompactMemoryEntry(id: "safe", text: "Safe", source: "secret=example"))
    }
    let inbox = CompactMemoryInbox(filePath: root.appending(path: "inbox.json").path)
    await #expect(throws: (any Error).self) {
      try await inbox.propose(
        CompactMemoryProposal(
          id: "safe", target: .personal, text: "Safe", source: "password=example",
          proposedBy: "agent"))
    }
  }

  @Test func recallAddsConfirmedLogsWithoutPrivateOrDraftRecords() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let brain = try ProjectBrainStore(rootPath: root.appending(path: "brain").path, project: "test")
    let personal = CompactMemoryStore(
      filePath: root.appending(path: "personal.md").path, title: "Personal", budget: .personal)
    let operating = CompactMemoryStore(
      filePath: root.appending(path: "operating.md").path, title: "Operating", budget: .operating)
    try await personal.add(
      CompactMemoryEntry(id: "preference", text: "Use concise replies", source: "user"))
    for (id, scope, confidence) in [
      ("launch-event", MemoryScope.project, MemoryConfidence.confirmed),
      ("launch-draft", .project, .proposed), ("launch-private", .agentRole, .confirmed),
    ] {
      _ = try await brain.write(
        MemoryRecord(
          id: id, type: .log, scope: scope, project: "test",
          title: "launch", body: id, author: "test", confidence: confidence,
          sourceIDs: ["session:test"], profileID: scope == .agentRole ? UUID() : nil),
        expectedRevision: nil)
    }
    let recalled = await AgentTaskMemory.context(
      query: "Do you remember launch?", personal: personal, operating: operating, brain: brain)
    #expect(recalled.contains("### Recall"))
    #expect(recalled.contains("memory:launch-event"))
    #expect(recalled.contains("[preference; source: user]"))
    #expect(!recalled.contains("launch-private"))
    #expect(!recalled.contains("launch-draft"))
    let ordinary = await AgentTaskMemory.context(
      query: "Implement launch", personal: personal, operating: operating, brain: brain)
    #expect(!ordinary.contains("### Recall"))
    #expect(!ordinary.contains("launch-event"))
    let unassigned = await AgentTaskMemory.context(
      query: "Do you remember launch?", personal: personal, operating: operating, brain: nil)
    #expect(!unassigned.contains("launch-event"))
  }
}

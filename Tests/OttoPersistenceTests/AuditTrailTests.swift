import Foundation
import OttoPersistence
import OttoTools
import Testing

@Suite("Durable audit chain")
struct AuditTrailTests {
  @Test("Audit records round-trip newest first, filter by actor, and survive reopening")
  func auditChainRoundTrip() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "workspace.sqlite").path

    let store = SQLiteWorkspaceStore(path: path)
    await store.record(
      ToolAuditRecord(
        id: UUID(), requestID: "r1", toolName: "memory.search",
        actorID: "otto-agent-alpha", succeeded: true, riskLevel: .read,
        timestamp: Date(timeIntervalSince1970: 1_000), durationMilliseconds: 4))
    await store.record(
      ToolAuditRecord(
        id: UUID(), requestID: "r2", toolName: "agent.send_prompt",
        actorID: "otto-agent-alpha", succeeded: false, riskLevel: .consequential,
        timestamp: Date(timeIntervalSince1970: 2_000), durationMilliseconds: 9))
    await store.record(
      ToolAuditRecord(
        id: UUID(), requestID: "r3", toolName: "browser.open",
        actorID: "otto-app", succeeded: true, riskLevel: .reversible,
        timestamp: Date(timeIntervalSince1970: 3_000), durationMilliseconds: 2))

    let all = try await store.recentAuditEvents(limit: 10)
    #expect(all.map(\.toolName) == ["browser.open", "agent.send_prompt", "memory.search"])
    #expect(all[1].succeeded == false)
    #expect(all[1].riskLevel == "consequential")

    let filtered = try await store.recentAuditEvents(limit: 10, actorID: "otto-agent-alpha")
    #expect(filtered.map(\.toolName) == ["agent.send_prompt", "memory.search"])

    // The chain is durable: a fresh store over the same file reads the same history.
    let reopened = SQLiteWorkspaceStore(path: path)
    let survived = try await reopened.recentAuditEvents(limit: 2)
    #expect(survived.map(\.toolName) == ["browser.open", "agent.send_prompt"])

    // The read tool surfaces the same slice.
    let tool = AuditRecentTool(store: reopened)
    let viaTool = try await tool.call(
      AuditRecentInput(limit: 1),
      context: ToolContext(actorID: "test", scopes: [.canvasRead], source: .userInterface)
    )
    #expect(viaTool.map(\.toolName) == ["browser.open"])
  }
}

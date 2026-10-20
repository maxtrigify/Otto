import Foundation
import OttoApplicationTools
import OttoCore
import OttoMemory
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Memory tool surface and cross-session acceptance")
struct MemoryToolsTests {
  @Test("Agent proposals, user promotion, retrieval with citations, and restart survival")
  func memoryLifecycleAcceptance() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let agent = ToolContext(
      actorID: "otto-agent-fixture", scopes: [.canvasRead, .canvasWrite], source: .agent)
    let user = ToolContext(
      actorID: "otto-app", scopes: [.canvasRead, .canvasWrite], source: .userInterface)

    let registry = try await makeRegistry(workspace: workspace)

    // Trusted agent writes are immediately confirmed; lifecycle controls remain user-only.
    let written = try await registry.call(
      name: "brain.write_record",
      input: try JSONValue.encode(
        BrainWriteRecordInput(
          id: "decision-signed-sessions",
          type: "decision",
          title: "Authentication uses signed sessions",
          body: "We chose signed sessions over rotating API keys.",
          sourceIDs: ["session:fixture/message:7"]
        )),
      context: agent
    ).decode(MemoryCitation.self)
    #expect(written.status == "active")

    // Agents cannot confirm; the user can.
    await #expect(throws: (any Error).self) {
      _ = try await registry.call(
        name: "memory.confirm",
        input: try JSONValue.encode(
          MemoryLifecycleInput(id: "decision-signed-sessions", expectedRevision: 1)),
        context: agent
      )
    }
    let confirmed = try await registry.call(
      name: "memory.confirm",
      input: try JSONValue.encode(
        MemoryLifecycleInput(id: "decision-signed-sessions", expectedRevision: 1)),
      context: user
    ).decode(MemoryCitation.self)
    #expect(confirmed.revision == 2)

    // Retrieval returns bounded citations; fetch returns the full cited record.
    let search = try await registry.call(
      name: "memory.search",
      input: try JSONValue.encode(MemorySearchInput(query: "what did we decide about sessions?")),
      context: agent
    ).decode(MemorySearchOutput.self)
    #expect(search.hits.contains { $0.id == "decision-signed-sessions" })

    let fetched = try await registry.call(
      name: "memory.fetch",
      input: try JSONValue.encode(MemoryFetchInput(id: "decision-signed-sessions")),
      context: agent
    ).decode(MemoryFetchOutput.self)
    #expect(fetched.confidence == "confirmed")
    #expect(fetched.sourceIDs == ["session:fixture/message:7"])

    let packed = try await registry.call(
      name: "memory.context_pack",
      input: try JSONValue.encode(
        MemoryContextPackInput(query: "signed sessions", budgetTokens: 256)),
      context: agent
    ).decode(MemoryContextPack.self)
    #expect(packed.text.contains("memory:decision-signed-sessions"))
    #expect(packed.text.contains("source: session:fixture/message:7"))
    #expect(packed.budgetUsed <= packed.budgetTokens)

    // Trusted compact writes load immediately.
    _ = try await registry.call(
      name: "memory.propose",
      input: try JSONValue.encode(
        MemoryProposeInput(
          target: "operating", id: "scratch-builds", text: "Use an isolated scratch path.",
          source: "session:fixture")),
      context: agent
    )

    // Structured completion report registers an output record.
    let report = try await registry.call(
      name: "report.complete",
      input: try JSONValue.encode(
        ReportCompleteInput(
          objective: "Wire the memory layer",
          outcome: "Tools registered and tested",
          evidence: ["45 tests green"],
          plainSummary: "The memory layer works end to end."
        )),
      context: agent
    ).decode(ReportCompleteTool.Output.self)
    #expect(report.relativePath.hasPrefix(".otto/brain/outputs/"))

    // "Restart Otto": a fresh registry over the same workspace restores the same cited memory.
    let restarted = try await makeRegistry(workspace: workspace)
    let restored = try await restarted.call(
      name: "memory.search",
      input: try JSONValue.encode(MemorySearchInput(query: "signed sessions decision")),
      context: agent
    ).decode(MemorySearchOutput.self)
    #expect(restored.hits.contains { $0.id == "decision-signed-sessions" })

    let inbox = CompactMemoryInbox(
      filePath: (workspace as NSString).appendingPathComponent(".otto/memory-inbox.json"))
    let pending = await inbox.proposals()
    #expect(pending.isEmpty)

    // User deletion is recoverable and removes the record from retrieval.
    _ = try await restarted.call(
      name: "memory.delete",
      input: try JSONValue.encode(MemoryDeleteInput(id: "decision-signed-sessions")),
      context: user
    )
    let afterDelete = try await restarted.call(
      name: "memory.search",
      input: try JSONValue.encode(MemorySearchInput(query: "signed sessions decision")),
      context: agent
    ).decode(MemorySearchOutput.self)
    #expect(!afterDelete.hits.contains { $0.id == "decision-signed-sessions" })
    let deletedDirectory = (workspace as NSString)
      .appendingPathComponent(".otto/brain/deleted")
    let recovered = (try? FileManager.default.contentsOfDirectory(atPath: deletedDirectory)) ?? []
    #expect(recovered.contains { $0.contains("decision-signed-sessions") })
  }

  @Test("Generic memory tools cannot read another bot's private records")
  func genericToolsCannotReadBotMemory() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let brain = try ProjectBrainStore(
      rootPath: (workspace as NSString).appendingPathComponent(".otto/brain"),
      project: "fixture"
    )
    let owner = UUID()
    _ = try await brain.write(
      MemoryRecord(
        id: "private-bot-fact",
        type: .wiki,
        scope: .agentRole,
        project: "fixture",
        title: "Private bot fact",
        body: "Only this bot may receive this.",
        author: "agent:owner",
        sourceIDs: ["session:private/message:1"],
        profileID: owner
      ),
      expectedRevision: nil
    )
    let agent = ToolContext(
      actorID: "otto-agent-other",
      scopes: [.canvasRead],
      source: .agent
    )
    await #expect(throws: (any Error).self) {
      _ = try await MemoryFetchTool(brain: brain).call(
        MemoryFetchInput(id: "private-bot-fact"), context: agent)
    }
    await #expect(throws: (any Error).self) {
      _ = try await MemorySearchTool(brain: brain).call(
        MemorySearchInput(query: "private", scope: "agent-role", profileID: owner),
        context: agent
      )
    }
  }

  @Test("Superseding a decision links both directions and survives search")
  func supersession() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let registry = try await makeRegistry(workspace: workspace)
    let agent = ToolContext(
      actorID: "otto-agent-fixture", scopes: [.canvasRead, .canvasWrite], source: .agent)

    for (id, body) in [
      ("decision-v1", "Ship weekly."), ("decision-v2", "Ship daily; supersedes weekly."),
    ] {
      _ = try await registry.call(
        name: "brain.write_record",
        input: try JSONValue.encode(
          BrainWriteRecordInput(id: id, type: "decision", title: id, body: body)),
        context: agent
      )
    }
    _ = try await registry.call(
      name: "memory.supersede",
      input: try JSONValue.encode(
        MemorySupersedeInput(id: "decision-v1", byID: "decision-v2", expectedRevision: 1)),
      context: agent
    )
    let old = try await registry.call(
      name: "memory.fetch",
      input: try JSONValue.encode(MemoryFetchInput(id: "decision-v1")),
      context: agent
    ).decode(MemoryFetchOutput.self)
    #expect(old.status == "superseded")
    let new = try await registry.call(
      name: "memory.fetch",
      input: try JSONValue.encode(MemoryFetchInput(id: "decision-v2")),
      context: agent
    ).decode(MemoryFetchOutput.self)
    #expect(new.supersedes == ["decision-v1"])
  }

  private func makeWorkspace() throws -> String {
    let path = FileManager.default.temporaryDirectory
      .appending(path: "otto-memory-tools-\(UUID().uuidString)", directoryHint: .isDirectory).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  private func makeRegistry(workspace: String) async throws -> ToolRegistry {
    let canvas = OttoCanvas(name: "Memory")
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: workspace
    )
    return registry
  }
}

extension MemoryToolsTests {
  @Test func autoConfirmationAndQuarantinedEdits() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let registry = try await makeRegistry(workspace: workspace)
    for source in [ToolInvocationSource.agent, .automation] {
      let context = ToolContext(
        actorID: "test", scopes: [.canvasRead, .canvasWrite], source: source)
      let id = "fact-\(source.rawValue.lowercased())"
      for (revision, sources, expected) in [
        (0, ["session:test"], "confirmed"), (1, ["session:test"], "confirmed"),
        (2, ["browser:page"], "proposed"),
      ] {
        _ = try await registry.call(
          name: "brain.write_record",
          input: JSONValue.encode(
            BrainWriteRecordInput(
              id: id, type: "wiki", title: "Fact", body: "A durable fact",
              sourceIDs: sources, expectedRevision: revision == 0 ? nil : revision)),
          context: context)
        let fetched = try await registry.call(
          name: "memory.fetch",
          input: JSONValue.encode(MemoryFetchInput(id: id)), context: context
        ).decode(MemoryFetchOutput.self)
        #expect(fetched.confidence == expected)
      }
    }
  }

  @Test func compactDirectWriteQuarantineAndOverflow() async throws {
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(atPath: workspace) }
    let personal = CompactMemoryStore(
      filePath: workspace + "/personal.md", title: "Personal",
      budget: MemoryBudget(maximumEntries: 1, maximumCharacters: 100))
    let operating = CompactMemoryStore(
      filePath: workspace + "/operating.md", title: "Operating", budget: .operating)
    let inbox = CompactMemoryInbox(filePath: workspace + "/inbox.json")
    let tool = MemoryProposeTool(inbox: inbox, personal: personal, operating: operating)
    let context = ToolContext(actorID: "agent", scopes: [.canvasWrite], source: .agent)
    let saved = try await tool.call(
      MemoryProposeInput(
        target: "personal", id: "first", text: "Keep it concise", source: "user:request"),
      context: context)
    #expect(!saved.pendingReview)
    #expect(await personal.entries().first?.confidence == .confirmed)
    let overflow = try await tool.call(
      MemoryProposeInput(
        target: "personal", id: "second", text: "Use British spelling", source: "user:request"),
      context: context)
    #expect(overflow.pendingReview)
    #expect(await inbox.proposals().map(\.id) == ["second"])
    #expect(await personal.entries().map(\.id) == ["first"])
    let quarantine = try await tool.call(
      MemoryProposeInput(
        target: "operating", id: "external", text: "An external suggestion", source: "email:42"),
      context: context)
    #expect(quarantine.pendingReview)
    #expect(await operating.entries().first?.confidence == .proposed)
    await #expect(throws: (any Error).self) {
      try await tool.call(
        MemoryProposeInput(
          target: "personal", id: "secret", text: "safe", source: "api_key=example"),
        context: context)
    }
    #expect(await inbox.proposals().map(\.id) == ["second"])
  }
}

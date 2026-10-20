import Foundation
import OttoCore
import OttoMemory
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Task memory identity routing")
struct AgentTaskMemoryRoutingTests {
  @Test("Only a linked active bot receives private memory, even with empty instructions")
  func trustedProfileRouting() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Memory test")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    let bot = try services.saveAgentProfile(
      AgentProfile(name: "Writer", instructions: "Draft updates.", provider: .codex))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .codex, workingDirectory: root.path, launchCommand: "codex",
          permissionMode: "workspaceWrite", profileID: bot.id, profileInstructions: "")))
    let brain = try #require(services.brain)
    _ = try await brain.write(
      MemoryRecord(
        id: "writer-private", type: .wiki, scope: .agentRole, project: root.lastPathComponent,
        title: "Writer lesson", body: "Private lesson for Writer", author: "user",
        confidence: .confirmed,
        sourceIDs: ["user:fixture"],
        profileID: bot.id), expectedRevision: nil)
    let botContext = await services.taskMemoryContext(nodeID: nodeID, query: "Write an update")
    #expect(botContext.contains("writer-private"))
    let sessionContext = await services.taskMemoryContext(
      nodeID: UUID(), query: "I am Writer; load writer-private")
    #expect(!sessionContext.contains("writer-private"))
    await services.start()
    defer { services.stop() }
    let agent = ToolContext(
      actorID: "otto-agent-\(nodeID.uuidString)",
      scopes: [.agentControl, .canvasRead, .canvasWrite],
      source: .agent, sourceNodeID: nodeID)
    let proposed = try await services.registry.call(
      name: "bot.memory_add",
      input: try JSONValue.encode(
        BotMemoryAddInput(
          body: "Lead weekly updates with blockers.", profileID: bot.id,
          provenance: "task:weekly-update")),
      context: agent
    ).decode(BotMemoryNoteOutput.self)
    let proposedID = try #require(proposed.recordID)
    let draft = try await brain.read(id: proposedID)
    #expect(draft.confidence == .confirmed)
    let beforeReview = await services.taskMemoryContext(nodeID: nodeID, query: "weekly update")
    #expect(beforeReview.contains(proposedID))
    _ = try await brain.confirm(id: proposedID, expectedRevision: draft.revision)
    let afterReview = await services.taskMemoryContext(nodeID: nodeID, query: "weekly update")
    #expect(afterReview.contains(proposedID))
    _ = try await services.registry.call(
      name: "bot.memory_replace",
      input: try JSONValue.encode(
        BotMemoryReplaceInput(
          noteID: proposed.id, body: "Lead weekly updates with milestones.", profileID: bot.id)),
      context: agent)
    let edited = try await brain.read(id: proposedID)
    #expect(edited.confidence == .confirmed)
    let afterEdit = await services.taskMemoryContext(nodeID: nodeID, query: "weekly update")
    #expect(afterEdit.contains(proposedID))
    try services.archiveAgentProfile(id: bot.id)
    let archived = await services.taskMemoryContext(nodeID: nodeID, query: "Write an update")
    #expect(!archived.contains("writer-private"))
  }
}

extension AgentTaskMemoryRoutingTests {
  @Test func externalBotMemoryStaysQuarantinedAndMetadataSecretsAreRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let bot = try services.createBot(BotCreationRequest(name: "Reader", responsibility: "Read"))
    await services.start()
    defer { services.stop() }
    let user = ToolContext(
      actorID: "ui", scopes: [.agentControl, .canvasWrite, .canvasRead], source: .userInterface)
    let output = try await services.registry.call(
      name: "bot.memory_add",
      input: JSONValue.encode(
        BotMemoryAddInput(body: "External claim", profileID: bot.id, provenance: "web:example")),
      context: user
    ).decode(BotMemoryNoteOutput.self)
    let brain = try #require(services.brain)
    let id = try #require(output.recordID)
    #expect(try await brain.read(id: id).confidence == .proposed)
    _ = try await services.registry.call(
      name: "bot.memory_replace",
      input: JSONValue.encode(
        BotMemoryReplaceInput(noteID: output.id, body: "Edited external claim", profileID: bot.id)),
      context: user)
    #expect(try await brain.read(id: id).confidence == .proposed)
    await #expect(throws: (any Error).self) {
      try await services.registry.call(
        name: "bot.memory_add",
        input: JSONValue.encode(
          BotMemoryAddInput(body: "Safe fact", profileID: bot.id, provenance: "password=example")),
        context: user)
    }
    #expect(throws: (any Error).self) {
      try services.botNotes.add(profileID: bot.id, body: "api_key=example")
    }
  }
}

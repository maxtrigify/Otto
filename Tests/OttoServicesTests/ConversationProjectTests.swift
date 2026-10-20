import Foundation
import OttoApplicationTools
import OttoCore
import OttoMemory
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Optional conversation projects")
struct ConversationProjectTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID())")
  }

  @Test func optionalSourceFoldersPersistValidateAndRemainInCapturedContext() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "source")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = ConversationProjectStore(workspacePath: root.path)
    let empty = try store.create(name: "Writing")
    #expect(empty.sourceFolders.isEmpty)
    let project = try store.create(name: "Code", sourceFolders: [folder.path, folder.path + "/."])
    #expect(project.sourceFolders == [folder.resolvingSymlinksInPath().path])
    let node = UUID()
    try store.select(channelID: node, projectID: project.id)
    let captured = try store.capture(nodeID: node, channelID: node)
    try store.select(channelID: node, projectID: empty.id)
    let restored = ConversationProjectStore(workspacePath: root.path)
    #expect(
      restored.projects.first(where: { $0.id == project.id })?.sourceFolders
        == project.sourceFolders)
    #expect(restored.run(nodeID: node)?.context.sourceFolders == captured.context.sourceFolders)
    #expect(restored.context(channelID: node).sourceFolders.isEmpty)
    #expect(throws: (any Error).self) {
      try store.create(name: "Invalid", sourceFolders: ["relative"])
    }
    #expect(throws: (any Error).self) {
      try store.create(name: "Missing", sourceFolders: [root.appending(path: "missing").path])
    }
    let file = root.appending(path: "file.txt")
    try "content".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try store.create(name: "File", sourceFolders: [file.path]) }
  }

  @Test func projectsAndRunContextsDecodeWithoutSourceFolders() throws {
    let id = UUID()
    let oldProject = Data("{\"id\":\"\(id)\",\"name\":\"Legacy\",\"isLegacyWorkspace\":true}".utf8)
    let oldContext = Data("{\"projectID\":\"\(id)\",\"name\":\"Legacy\"}".utf8)
    #expect(
      try JSONDecoder().decode(ConversationProject.self, from: oldProject).sourceFolders.isEmpty)
    #expect(
      try JSONDecoder().decode(ConversationProjectContext.self, from: oldContext).sourceFolders
        .isEmpty)
  }

  @Test func sessionProjectSelectionScopesToolsAndKeepsRunningWork() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let node = try #require(
      services.store.dispatch(
        .createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))
      ).affectedNodeIDs.first)
    #expect(services.projectChannel(nodeID: node) == node)
    #expect(services.resolvedProjectContext(nodeID: node)?.projectID != nil)
    let caller = ToolContext(
      actorID: "session", scopes: [.canvasWrite, .canvasRead],
      source: .agent, sourceNodeID: node)
    _ = try services.scopedBrain(context: caller)
    let workspaceBrain = try #require(services.brain)
    _ = try await workspaceBrain.write(
      MemoryRecord(
        id: "workspace-default-fact", type: .wiki, project: root.lastPathComponent,
        title: "workspace", body: "Workspace default knowledge", author: "test",
        confidence: .confirmed),
      expectedRevision: nil)
    let defaultMemory = await services.taskMemoryContext(nodeID: node, query: "workspace")
    #expect(defaultMemory.contains("workspace-default-fact"))
    let selected = try await services.registry.call(
      name: "project.context",
      input: JSONValue.encode(
        ConversationProjectInput(
          action: "create", name: "Session project", sourceFolders: [root.path])),
      context: caller
    ).decode(ConversationProjectOutput.self)
    let id = try #require(selected.active.projectID)
    #expect(selected.active.sourceFolders == [root.resolvingSymlinksInPath().path])
    let memoryContext = await services.taskMemoryContext(nodeID: node, query: "Find project files")
    #expect(memoryContext.contains(root.resolvingSymlinksInPath().path))
    _ = try services.conversationProjects.capture(nodeID: node, channelID: node)
    try services.selectProject(channelID: node, projectID: nil)
    #expect(services.conversationProjects.context(channelID: node).projectID == nil)
    #expect(services.resolvedProjectContext(nodeID: node)?.projectID == id)
    #expect(
      try services.scopedDocumentPath("note.md", context: caller, creating: true)
        == "Projects/\(id.uuidString)/note.md")
    _ = try services.scopedBrain(context: caller)
    let restored = ConversationProjectStore(workspacePath: root.path, existingSessionIDs: [node])
    #expect(restored.context(channelID: node).projectID == nil)
    #expect(restored.run(nodeID: node)?.context.projectID == id)
  }

  @Test func legacySessionsMigrateOnceAndClearedSessionsStayUnassigned() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let node = UUID()
    let store = ConversationProjectStore(workspacePath: root.path, existingSessionIDs: [node])
    #expect(store.context(channelID: node).projectID != nil)
    try store.select(channelID: node, projectID: nil)
    let restored = ConversationProjectStore(workspacePath: root.path, existingSessionIDs: [node])
    #expect(restored.context(channelID: node).projectID == nil)
  }

  @Test func migrationAndNewUnassignedChannels() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = UUID()
    let new = UUID()
    let store = ConversationProjectStore(workspacePath: root.path, existingChannelIDs: [old])
    #expect(store.context(channelID: old).projectID != nil)
    #expect(store.context(channelID: new).projectID != nil)
    try store.select(channelID: old, projectID: nil)
    let restored = ConversationProjectStore(
      workspacePath: root.path, existingChannelIDs: [old, new])
    #expect(restored.context(channelID: old).projectID == nil)
    #expect(restored.context(channelID: new).projectID != nil)
  }

  @Test func capturePersistsAndSwitchDoesNotRedirectAssignment() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationProjectStore(workspacePath: root.path)
    let channel = UUID()
    let node = UUID()
    let marketing = try store.create(name: "Marketing")
    let engineering = try store.create(name: "Engineering")
    try store.select(channelID: channel, projectID: marketing.id)
    let started = Date(timeIntervalSince1970: 100)
    let run = try store.capture(nodeID: node, channelID: channel, at: started)
    try store.select(channelID: channel, projectID: engineering.id)
    try store.resolveUnassignedRun(nodeID: node, context: store.context(channelID: channel))
    #expect(store.run(nodeID: node)?.context == run.context)
    #expect(store.attribution(nodeID: node, at: started).contains("Marketing"))
    let restored = ConversationProjectStore(workspacePath: root.path)
    #expect(restored.run(nodeID: node)?.context.projectID == marketing.id)
    #expect(restored.context(channelID: channel).projectID == engineering.id)
    #expect(throws: (any Error).self) { try store.resolve(name: "Market") }
    #expect(throws: (any Error).self) { try store.create(name: "marketing") }
  }

  @Test func agentActionsMemoryAndDocumentsFollowCapturedScope() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let bot = try services.createBot(BotCreationRequest(name: "Scout", responsibility: "Research"))
    let channel = try #require(services.botChannels.canonicalChannel(for: bot.id))
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs
        .first)
    _ = try services.botChannels.bindNode(profileID: bot.id, nodeID: node)
    try services.selectProject(channelID: channel.id, projectID: nil)
    #expect(services.conversationProjects.context(channelID: channel.id).projectID == nil)
    _ = try services.conversationProjects.capture(nodeID: node, channelID: channel.id)
    let caller = ToolContext(
      actorID: "test", scopes: [.canvasWrite, .canvasRead], source: .agent, sourceNodeID: node)
    #expect(throws: (any Error).self) { try services.scopedBrain(context: caller) }
    let output = try await services.registry.call(
      name: "project.context",
      input: JSONValue.encode(ConversationProjectInput(action: "create", name: "Marketing")),
      context: caller
    ).decode(ConversationProjectOutput.self)
    let id = try #require(output.active.projectID)
    #expect(output.assignment?.projectID == id)
    let readOnly = ToolContext(
      actorID: "readonly", scopes: [.canvasRead], source: .agent, sourceNodeID: node)
    _ = try await services.registry.call(
      name: "project.list", input: .object([:]), context: readOnly)
    await #expect(throws: (any Error).self) {
      try await services.registry.call(
        name: "project.context", input: JSONValue.encode(ConversationProjectInput(action: "clear")),
        context: readOnly)
    }
    _ = try await services.registry.call(
      name: "brain.write_record",
      input: JSONValue.encode(
        BrainWriteRecordInput(
          id: "tool-project-record", type: "wiki", title: "Tool fact", body: "Scoped tool output",
          sourceIDs: ["test:fixture"])), context: caller)
    _ = try await services.registry.call(
      name: "memory.fetch", input: JSONValue.encode(MemoryFetchInput(id: "tool-project-record")),
      context: caller)
    let document = try await services.registry.call(
      name: "document.create",
      input: JSONValue.encode(
        DocumentCreateInput(relativePath: "Plans/tool.md", text: "Scoped document", x: 0, y: 0)),
      context: caller
    ).decode(NodeCreateOutput.self)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appending(path: "Projects/\(id.uuidString)/Plans/tool.md").path))
    #expect(document.node.kind == .markdown)
    let selected = try services.scopedBrain(context: caller)
    _ = try await selected.write(
      MemoryRecord(
        id: "marketing-fact", type: .wiki, project: "Marketing", title: "Campaign",
        body: "Marketing-only fact", author: "test", confidence: .confirmed), expectedRevision: nil)
    let other = try services.conversationProjects.create(name: "Engineering")
    let selection = try await services.registry.call(
      name: "project.context",
      input: JSONValue.encode(ConversationProjectInput(action: "select", name: "Engineering")),
      context: caller
    ).decode(ConversationProjectOutput.self)
    #expect(selection.active.projectID == other.id)
    #expect(selection.assignment?.projectID == id)
    await #expect(throws: (any Error).self) {
      try await services.registry.call(
        name: "project.context",
        input: JSONValue.encode(ConversationProjectInput(action: "select", name: "Market")),
        context: caller)
    }
    #expect(
      try await services.scopedBrain(context: caller).read(id: "marketing-fact").body
        == "Marketing-only fact")
    #expect(
      try services.scopedDocumentPath("Plans/work.md", context: caller, creating: true)
        == "Projects/\(id.uuidString)/Plans/work.md")
    #expect(throws: (any Error).self) {
      try services.scopedDocumentPath(
        "Projects/\(other.id.uuidString)/work.md", context: caller, creating: false)
    }
    await #expect(throws: (any Error).self) {
      try await services.registry.call(
        name: "project.context",
        input: JSONValue.encode(ConversationProjectInput(action: "clear", channelID: UUID())),
        context: caller)
    }
    _ = try services.conversationProjects.capture(nodeID: node, channelID: channel.id)
    await #expect(throws: (any Error).self) {
      try await services.registry.call(
        name: "memory.fetch", input: JSONValue.encode(MemoryFetchInput(id: "tool-project-record")),
        context: caller)
    }
    let knowledge = await services.taskMemoryContext(nodeID: node, query: "Campaign")
    #expect(!knowledge.contains("Marketing-only fact"))
    try services.selectProject(channelID: channel.id, projectID: nil)
    _ = try services.conversationProjects.capture(nodeID: node, channelID: channel.id)
    #expect(throws: (any Error).self) { try services.scopedBrain(context: caller) }
    #expect(services.botChannels.canonicalChannel(for: bot.id)?.id == channel.id)
    await services.shutdown()
  }

  @Test func compactionKeepsProjectLabelsAndRoomsSeparate() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotChannelContextStore(workspacePath: root.path, tokenThreshold: 10)
    let marketing = ConversationProjectContext(projectID: UUID(), name: "Marketing")
    let engineering = ConversationProjectContext(projectID: UUID(), name: "Engineering")
    let messages = (0..<24).map { index in
      BotContextMessage(
        speaker: (index.isMultiple(of: 2) ? marketing : engineering).attribution + " Scout",
        text: "Decision: item \(index). I will finish this. Artifact: file\(index).",
        createdAt: Date(timeIntervalSince1970: Double(index + 1)))
    }
    let privateID = UUID()
    let roomID = UUID()
    let projection = try store.project(channelID: privateID, messages: messages)
    #expect(projection.decisions.contains { $0.contains(marketing.attribution) })
    #expect(projection.decisions.contains { $0.contains(engineering.attribution) })
    #expect(projection.openWork.allSatisfy { $0.owner.contains("[Project:") })
    let room = try store.project(
      channelID: roomID, messages: [BotContextMessage(speaker: "User", text: "Room-only")])
    #expect(!BotChannelContextStore.promptText(room).contains("Decision: item"))
    let assignment = BotTeamAssignment(profileID: UUID(), task: "Work", projectContext: marketing)
    #expect(
      try JSONDecoder().decode(BotTeamAssignment.self, from: JSONEncoder().encode(assignment))
        .projectContext == marketing)
  }
}

extension ConversationProjectTests {
  @Test func runningTeamRetainsProjectAfterRoomSwitch() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    let lead = try services.createBot(
      BotCreationRequest(name: "Lead", responsibility: "Coordinate"))
    let worker = try services.createBot(
      BotCreationRequest(name: "Worker", responsibility: "Implement"))
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs
        .first)
    _ = try services.botChannels.bindNode(profileID: lead.id, nodeID: node)
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf 'OTTO_STATUS:IDLE\\r\\n'; while IFS= read -r line; do [ \"$line\" = '[OTTO TEAM PROMPT END]' ] && break; done; printf 'OTTO_STATUS:WORKING\\r\\n'; sleep 30",
        ],
        environment: ["NO_COLOR": "1"], workingDirectory: root.path), id: node)
    for _ in 0..<100 {
      if try await services.supervisor.snapshot(agentID: node).state == .idle { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let team = try services.botChannels.createGroupChannel(
      memberProfileIDs: [lead.id, worker.id], name: "Project team", orchestratorProfileID: lead.id)
    let project = try services.conversationProjects.create(name: "Marketing")
    try services.selectProject(channelID: team.id, projectID: project.id)
    try await services.sendTeamMessage(
      channelID: team.id, text: "Draft campaign plan", at: WorldPoint(x: 0, y: 0))
    let runtime = try #require(services.activeTeamRuntimeID(channelID: team.id))
    try services.selectProject(channelID: team.id, projectID: nil)
    #expect(services.resolvedProjectContext(nodeID: runtime)?.projectID == project.id)
    let session = try #require(services.botGroups.latestSession(forChannel: team.id))
    #expect(session.messages.first?.projectContext?.projectID == project.id)
    #expect(session.teamCheckpoint?.activeAssignment?.projectContext?.projectID == project.id)
    #expect(services.runningProjectDescription(channelID: team.id) == "Running task: Marketing")
    #expect(throws: (any Error).self) { try services.compactTeamSession(channelID: team.id) }
    #expect(
      services.botGroups.latestSession(forChannel: team.id)?.messages.first?.text
        == "Draft campaign plan")
    try await services.supervisor.stop(agentID: runtime)
    await services.shutdown()
  }
}

extension ConversationProjectTests {
  @Test func unassignedBotCanChatAndSelectionKeepsTranscript() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    let bot = try services.createBot(BotCreationRequest(name: "Scout", responsibility: "Help"))
    let channel = try #require(services.botChannels.canonicalChannel(for: bot.id))
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs
        .first)
    _ = try services.botChannels.bindNode(profileID: bot.id, nodeID: node)
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'OTTO_STATUS:IDLE\\r\\n'; while IFS= read -r line; do :; done"],
        environment: ["NO_COLOR": "1"], workingDirectory: root.path), id: node)
    for _ in 0..<100 {
      if try await services.supervisor.snapshot(agentID: node).state == .idle { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await services.sendPrompt(agentID: node, prompt: "Hello Scout")
    let before = try await services.supervisor.snapshot(agentID: node)
    #expect(before.transcript.contains { $0.role == .user && $0.text.contains("Hello Scout") })
    #expect(
      services.conversationProjects.run(nodeID: node)?.context.projectID
        == services.conversationProjects.projects.first(where: { $0.isLegacyWorkspace })?.id)
    let project = try services.conversationProjects.create(name: "Marketing")
    try services.selectProject(channelID: channel.id, projectID: project.id)
    let after = try await services.supervisor.snapshot(agentID: node)
    #expect(
      after.transcript.filter { $0.role == .user } == before.transcript.filter { $0.role == .user })
    #expect(
      services.conversationProjects.run(nodeID: node)?.context.projectID
        == services.conversationProjects.projects.first(where: { $0.isLegacyWorkspace })?.id)
    try services.selectProject(channelID: channel.id, projectID: nil)
    #expect(services.botChannels.canonicalChannel(for: bot.id)?.nodeID == node)
    try await services.supervisor.stop(agentID: node)
    await services.shutdown()
  }
}

extension ConversationProjectTests {
  @Test func actualRoomCompactionRetainsProjectOwnership() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let roomID = UUID()
    let members = [UUID(), UUID()]
    let session = try services.botGroups.beginTurn(
      members: members, channelID: roomID, mentioned: members)
    let first = ConversationProjectContext(projectID: UUID(), name: "Marketing")
    let second = ConversationProjectContext(projectID: UUID(), name: "Engineering")
    for index in 0..<25 {
      _ = try services.botGroups.recordUserMessage(
        sessionID: session.id,
        text: "Decision: task \(index)\nOwner: Scout will finish. Artifact: file-\(index)",
        projectContext: index.isMultiple(of: 2) ? first : second)
    }
    let compacted = try services.botGroups.compactLatestSession(channelID: roomID)
    #expect(compacted.messages.count == 25)
    #expect(compacted.contextSummary?.contains(first.attribution) == true)
    #expect(compacted.contextSummary?.contains(second.attribution) == true)
    #expect(compacted.contextDecisions?.allSatisfy { $0.hasPrefix("[Project:") } == true)
    #expect(compacted.contextOpenWork?.allSatisfy { $0.owner.hasPrefix("[Project:") } == true)
  }
}

extension ConversationProjectTests {
  @Test func queuedDelegationKeepsSenderProjectAcrossChangesAndReload() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    let sender = try services.createBot(
      BotCreationRequest(name: "Sender", responsibility: "Delegate"))
    let receiver = try services.createBot(
      BotCreationRequest(name: "Receiver", responsibility: "Implement"))
    let senderChannel = try #require(services.botChannels.canonicalChannel(for: sender.id))
    let receiverChannel = try #require(services.botChannels.canonicalChannel(for: receiver.id))
    let project = try services.conversationProjects.create(name: "Marketing")
    try services.selectProject(channelID: senderChannel.id, projectID: project.id)
    _ = try await services.deliverBotMessage(
      BotMessageInput(to: receiver.name, body: "Prepare the draft", senderProfileID: sender.id),
      context: ToolContext(actorID: "ui", scopes: [.agentControl], source: .userInterface))
    try services.selectProject(channelID: senderChannel.id, projectID: nil)
    #expect(services.conversationProjects.context(channelID: receiverChannel.id).projectID != nil)
    let restored = BotMessageDeliveryStore(workspacePath: root.path)
    let delivery = try #require(restored.deliveries.first)
    #expect(delivery.projectContext?.projectID == project.id)
    #expect(delivery.body == "Prepare the draft")
    #expect(delivery.state == .queued)
  }

  @Test func unreadableContextIsNotReplacedDuringMigration() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: ".otto/conversation-projects.json")
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("not valid JSON".utf8)
    try original.write(to: path)
    let store = ConversationProjectStore(workspacePath: root.path, existingChannelIDs: [UUID()])
    #expect(store.persistenceError != nil)
    #expect(throws: (any Error).self) { try store.create(name: "New") }
    #expect(try Data(contentsOf: path) == original)
  }
}

extension ConversationProjectTests {
  @Test func legacyCompactionPreservesContentWithoutInventingProjectAttribution() throws {
    struct Envelope: Codable {
      var schemaVersion = 1
      var projections: [BotChannelContextProjection]
    }
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = UUID()
    let provenance = UUID()
    let old = BotChannelContextProjection(
      channelID: channel, decisions: ["Scout: decided to ship"],
      openWork: [BotOwnedWork(owner: "Scout", text: "will finish")], summary: "Old summary",
      summaryProvenance: [provenance], version: 1)
    try WorkspaceJSONFile.save(
      Envelope(projections: [old]), to: root.appending(path: ".otto/bot-context-projections.json"),
      fileManager: .default)
    let store = BotChannelContextStore(workspacePath: root.path)
    let migrated = try #require(store.projection(channelID: channel))
    #expect(migrated.decisions.first?.contains("attribution not recorded") == true)
    #expect(migrated.decisions.first?.contains("decided to ship") == true)
    #expect(migrated.openWork.first?.text == "will finish")
    #expect(migrated.summaryProvenance == [provenance])
    #expect(migrated.generationID == old.generationID)
  }
}

extension ConversationProjectTests {
  @Test func oldExplicitUnassignedChoicesSurviveMigrationWhileNewChatsDefault() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConversationProjectStore(workspacePath: root.path)
    let old = UUID()
    let file = root.appending(path: ".otto/conversation-projects.json")
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json.removeValue(forKey: "unassignedChannels")
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    let migrated = ConversationProjectStore(workspacePath: root.path, existingSessionIDs: [old])
    #expect(migrated.context(channelID: old).projectID == nil)
    let fresh = UUID()
    let legacy = try #require(store.projects.first(where: { $0.isLegacyWorkspace }))
    #expect(migrated.context(channelID: fresh).projectID == legacy.id)
    let restored = ConversationProjectStore(workspacePath: root.path)
    #expect(restored.context(channelID: old).projectID == nil)
    #expect(restored.context(channelID: fresh).projectID == legacy.id)
  }
}

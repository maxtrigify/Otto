import CryptoKit
import Foundation
import OttoCore
import OttoHostRuntime
import OttoModels
import OttoObservability
import OttoRPCContracts
import OttoRuntime
import OttoServices
import Testing

@MainActor
@Suite("Mobile host roster adapter")
struct MobileHostRosterAdapterTests {
  @Test(
    "Deleted bots cannot reappear as legacy sessions and deleted nodes cannot leave ghost channels")
  func deletedRosterEntries() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mobile-deletions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Deletion test")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    defer { services.stop() }
    func node(_ profileID: UUID? = nil) throws -> UUID {
      let id = try #require(
        store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
      store.dispatch(
        .setAgentDefinition(
          id: id,
          definition: AgentDefinition(
            provider: .codex, workingDirectory: root.path, launchCommand: "codex",
            permissionMode: "workspaceWrite", profileID: profileID)))
      return id
    }
    let oldBot = try services.saveAgentProfile(
      AgentProfile(name: "GenAI", instructions: "Test", provider: .codex))
    let legacyID = try node(oldBot.id)
    let boundID = try node(oldBot.id)
    let channel = try services.botChannels.bindNode(profileID: oldBot.id, nodeID: boundID)
    let ordinaryID = try node()
    let adapter = ApplicationServicesMobileHostAdapter(services: services, environmentID: UUID())
    #expect(
      Set(try await adapter.listThreads().map(\.id)) == [
        legacyID, channel.conversationID, ordinaryID,
      ])
    try services.deleteAgentProfile(id: oldBot.id)
    let replacement = try services.saveAgentProfile(
      AgentProfile(name: "GenAI", instructions: "New bot", provider: .codex))
    #expect(try await adapter.listBots().bots.map(\.id) == [replacement.id])
    #expect(try await adapter.listThreads().map(\.id) == [ordinaryID])
    await #expect(throws: OttoHostError.self) { try await adapter.snapshot(threadID: legacyID) }
    await #expect(throws: OttoHostError.self) {
      try await adapter.snapshot(threadID: channel.conversationID)
    }
    let replacementNode = try node(replacement.id)
    let replacementChannel = try services.botChannels.bindNode(
      profileID: replacement.id, nodeID: replacementNode)
    store.dispatch(.closeNode(replacementNode))
    store.dispatch(.closeNode(ordinaryID))
    #expect(try await adapter.listThreads().isEmpty)
    #expect(try await adapter.listBots().bots.first?.hasSession == false)
    await #expect(throws: OttoHostError.self) {
      try await adapter.snapshot(threadID: replacementChannel.conversationID)
    }
  }

  @Test("Mobile sends to a dormant bot on a background canvas without changing the Mac selection")
  func mobileSendOnBackgroundCanvas() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mobile-send-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let foreground = OttoCanvas(name: "Mac selection")
    let background = OttoCanvas(name: "Bot canvas")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [foreground, background], activeCanvasID: foreground.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    let bot = try services.saveAgentProfile(
      AgentProfile(name: "Mobile fixture", instructions: "Echo test messages.", provider: .codex))
    // A local shell stands in for the provider so this exercises real routing without an API call.
    let nodeID = try #require(
      store.dispatch(
        .createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)),
        targetCanvasID: background.id
      ).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .shell, workingDirectory: root.path, launchCommand: "/bin/zsh",
          permissionMode: "workspaceWrite", profileID: bot.id)), targetCanvasID: background.id)
    let channel = try services.botChannels.bindNode(profileID: bot.id, nodeID: nodeID)
    await services.start()
    defer { services.stop() }
    let adapter = ApplicationServicesMobileHostAdapter(services: services, environmentID: UUID())
    let body = "printf MOBILE_ROUTE_OK"
    let host = OttoHostRuntime(
      dataSource: adapter, journal: try RunEventJournal(directory: root.appending(path: "events")))
    let request = try OttoRPCRequest(
      method: .messageSend,
      parameters: MessageSendInput(
        threadID: channel.conversationID, clientMessageID: UUID(), body: body))
    let client = OttoHostClientContext(deviceID: UUID(), scopes: [.messageWrite])
    let sent = try await host.handle(request, client: client).decodeResult(MessageSendOutput.self)
    let message = try #require(sent.event.content.message)
    #expect(sent.accepted && !sent.duplicate)
    let retry = try await host.handle(request, client: client).decodeResult(MessageSendOutput.self)
    #expect(retry.duplicate && retry.event.id == sent.event.id)
    #expect(message.text == body)
    #expect(store.snapshot.activeCanvasID == foreground.id)
    let snapshot = try await adapter.snapshot(threadID: channel.conversationID)
    #expect(snapshot.messages.contains { $0.id == message.id && $0.text == body })
    #expect(snapshot.messages.filter { $0.text == body }.count == 1)
    await services.shutdown()
  }

  @Test("Mobile opens saved history before startup and keeps stable message IDs")
  func savedMobileHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mobile-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionID = UUID().uuidString
    let slug = String(root.path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let directory = root.appending(path: ".claude/projects/\(slug)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let records: [[String: Any]] = [
      ["type": "user", "message": ["content": "Earlier question"]],
      ["type": "assistant", "message": ["content": "Earlier answer"]],
    ]
    let lines = try records.map {
      String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)
    }.joined(separator: "\n")
    try Data(lines.utf8).write(to: directory.appending(path: "\(sessionID).jsonl"))
    let canvas = OttoCanvas(name: "Saved history")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .claudeCode, workingDirectory: root.path, launchCommand: "claude",
          permissionMode: "workspaceWrite", resumeSessionID: sessionID)))
    let services = ApplicationServices(
      store: store, workspacePath: root.path, providerSessionHome: root)
    defer { services.stop() }
    let adapter = ApplicationServicesMobileHostAdapter(services: services, environmentID: UUID())
    let snapshot = try await adapter.snapshot(threadID: nodeID)
    #expect(!services.isOnline)
    #expect(snapshot.messages.map(\.text) == ["Earlier question", "Earlier answer"])
    let reopened = try await adapter.snapshot(threadID: nodeID)
    #expect(reopened.messages.map(\.id) == snapshot.messages.map(\.id))
  }

  @Test("Mobile diagnostics project the local crash timeline without user content")
  func privacySafeDiagnostics() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let observability = try ObservabilityStore(
      directory: root.appending(path: "diagnostics", directoryHint: .isDirectory),
      appVersion: "0.1.0",
      operatingSystemVersion: "macOS 26.2"
    )
    try await observability.beginSession()
    let agentID = UUID()
    try await observability.recordRuntimeEvent(
      .output(agentID: agentID, text: "SECRET /Users/alice/private.swift"),
      provider: .codex
    )
    try await observability.recordRuntimeEvent(
      .stateChanged(agentID: agentID, state: .working, confidence: 0.9),
      provider: .codex
    )
    let canvas = OttoCanvas(name: "Mobile diagnostics")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      observability: observability,
      workspacePath: root.path
    )
    let adapter = ApplicationServicesMobileHostAdapter(
      services: services,
      environmentID: UUID(),
      environmentName: "Test Mac"
    )

    #expect(await adapter.environment().capabilities.contains(.diagnostics))
    let output = try await adapter.diagnostics()
    #expect(output.isPrivacySafe)
    #expect(output.recentEvents.contains { $0.kind == .agentStateChanged })
    let encoded = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
    #expect(!encoded.contains("SECRET"))
    #expect(!encoded.contains("/Users/alice"))
    #expect(!encoded.contains("private.swift"))
    try await observability.endSession()
  }

  @Test("Canonical bots and teams project to mobile and resume the existing channel")
  func rosterAndResume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-roster-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Mobile roster")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    let ada = try services.saveAgentProfile(
      AgentProfile(
        name: "Ada", jobTitle: "Research partner", instructions: "Research carefully.",
        provider: .codex))
    let nova = try services.saveAgentProfile(
      AgentProfile(
        name: "Nova", jobTitle: "Launch planner", instructions: "Plan launches.",
        provider: .claudeCode))
    let team = try services.createTeam(
      memberProfileIDs: [ada.id, nova.id],
      name: "Studio Launch Team",
      orchestratorProfileID: ada.id
    )
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 20, y: 30)))
        .affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: root.path,
          launchCommand: "codex",
          permissionMode: "workspaceWrite",
          profileID: ada.id,
          profileRevision: ada.revision,
          profileInstructions: ada.instructions
        )))
    let channel = try services.botChannels.bindNode(profileID: ada.id, nodeID: nodeID)
    let adapter = ApplicationServicesMobileHostAdapter(
      services: services,
      environmentID: UUID(),
      environmentName: "Test Mac"
    )
    let environment = await adapter.environment()
    #expect(environment.capabilities.contains(.attachments))

    let roster = try await adapter.listBots()
    #expect(roster.bots.map(\.name) == ["Ada", "Nova"])
    #expect(roster.bots.first(where: { $0.id == ada.id })?.hasSession == true)
    #expect(roster.bots.first(where: { $0.id == nova.id })?.hasSession == false)
    #expect(
      roster.teams == [
        MobileTeamSummary(
          id: team.id,
          name: "Studio Launch Team",
          memberProfileIDs: team.memberProfileIDs,
          orchestratorProfileID: ada.id,
          updatedAt: team.updatedAt
        )
      ])

    let ordinaryID = try #require(
      store.dispatch(
        .createNode(
          kind: .agent,
          at: WorldPoint(x: 90, y: 90))
      ).affectedNodeIDs.first)
    let room = try services.botGroups.beginTurn(
      members: [ada.id, nova.id], channelID: team.id, mentioned: [])
    _ = try services.botGroups.recordUserMessage(sessionID: room.id, text: "Shared team request")
    _ = try services.botGroups.recordTurn(
      sessionID: room.id, profileID: nova.id, kind: .reply,
      text: "Shared team result", speakerName: nova.name)
    let threads = try await adapter.listThreads()
    #expect(threads.contains { $0.id == ordinaryID && $0.kind == .task })
    #expect(threads.contains { $0.id == team.conversationID && $0.kind == .group })
    #expect(threads.filter { $0.nodeID == nodeID }.count == 1)
    let teamSnapshot = try await adapter.snapshot(threadID: team.conversationID)
    #expect(teamSnapshot.messages.map(\.text) == ["Shared team request", "Shared team result"])
    #expect(teamSnapshot.messages.last?.author?.displayName == "Nova")
    let privateSnapshot = try await adapter.snapshot(threadID: channel.conversationID)
    #expect(!privateSnapshot.messages.contains { $0.text.contains("Shared team") })
    #expect(try await adapter.snapshot(threadID: ordinaryID).thread.kind == .task)

    let output = try await adapter.startThread(ThreadStartInput(botProfileID: ada.id))
    #expect(output.openedExisting)
    #expect(output.thread.id == channel.conversationID)
    #expect(output.thread.nodeID == nodeID)
    #expect(output.thread.title == "Ada")
  }

  @Test("Chunked mobile attachment upload is verified, attached once, and downloadable")
  func attachmentRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-attachment-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Mobile attachment")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: store, workspacePath: root.path)
    let profile = try services.saveAgentProfile(
      AgentProfile(name: "Ada", instructions: "Review files.", provider: .codex))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 20, y: 30)))
        .affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: root.path,
          launchCommand: "codex",
          permissionMode: "workspaceWrite",
          profileID: profile.id,
          profileRevision: profile.revision,
          profileInstructions: profile.instructions
        )
      ))
    let channel = try services.botChannels.bindNode(profileID: profile.id, nodeID: nodeID)
    let adapter = ApplicationServicesMobileHostAdapter(
      services: services,
      environmentID: UUID(),
      environmentName: "Test Mac"
    )
    let bytes = Data((0..<600_000).map { UInt8($0 % 251) })
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let prepared = try await adapter.prepareAttachmentUpload(
      AttachmentPrepareUploadInput(
        threadID: channel.conversationID,
        displayName: "Mobile Notes.txt",
        mimeType: "text/plain",
        byteCount: Int64(bytes.count),
        sha256: digest
      ))
    #expect(prepared.chunkSize == 256 * 1_024)

    var offset = 0
    var final: AttachmentUploadChunkOutput?
    var finalInput: AttachmentUploadChunkInput?
    while offset < bytes.count {
      let end = min(offset + prepared.chunkSize, bytes.count)
      let input = AttachmentUploadChunkInput(
        threadID: channel.conversationID,
        uploadID: prepared.uploadID,
        offset: Int64(offset),
        data: bytes.subdata(in: offset..<end)
      )
      let output = try await adapter.uploadAttachmentChunk(input)
      if offset == 0 {
        let retry = try await adapter.uploadAttachmentChunk(input)
        #expect(retry.receivedBytes == output.receivedBytes)
        #expect(!retry.complete)
      }
      final = output
      if output.complete { finalInput = input }
      offset = end
    }
    let attachment = try #require(final?.attachment)
    #expect(final?.complete == true)
    #expect(attachment.displayName == "Mobile Notes.txt")
    #expect(attachment.byteCount == Int64(bytes.count))
    #expect(try await adapter.listAttachments(threadID: channel.conversationID) == [attachment])

    let finalRetry = try await adapter.uploadAttachmentChunk(try #require(finalInput))
    #expect(finalRetry.complete)
    #expect(finalRetry.attachment == attachment)

    var downloaded = Data()
    while Int64(downloaded.count) < attachment.byteCount {
      let chunk = try await adapter.downloadAttachmentChunk(
        AttachmentDownloadChunkInput(
          threadID: channel.conversationID,
          attachmentID: attachment.id,
          offset: Int64(downloaded.count),
          limit: 100_000
        ))
      downloaded.append(chunk.data)
      if !chunk.hasMore { break }
    }
    #expect(downloaded == bytes)

    await #expect(throws: OttoHostError.self) {
      try await adapter.prepareAttachmentUpload(
        AttachmentPrepareUploadInput(
          threadID: channel.conversationID,
          displayName: "../escape.txt",
          mimeType: "text/plain",
          byteCount: 1,
          sha256: String(repeating: "0", count: 64)
        ))
    }
  }
}

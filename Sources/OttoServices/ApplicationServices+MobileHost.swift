#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
import OttoHostRuntime
import OttoModels
import OttoObservability
import OttoRPCContracts
import OttoRemote
import OttoRuntime

/// Projects the existing Mac-owned Bots/Sessions runtime into the transport-independent mobile
/// host boundary. This adapter does not launch providers or persist a second session model.
@MainActor
public final class ApplicationServicesMobileHostAdapter: OttoHostDataSource {
  private let services: ApplicationServices
  private let environmentID: UUID
  private let environmentName: String
  private let hostVersion: String?
  private let pairingStore: RemotePairingStore?
  /// The person's own desktop client sees every bot; paired phones only those shared with Mobile.
  private let isOwnerClient: Bool
  private let attachmentTransfers: MobileAttachmentTransferStore
  private var completedAttachmentUploads:
    [UUID: (
      threadID: UUID,
      attachment: OttoAttachment,
      retryOffset: Int64,
      retryData: Data
    )] = [:]
  private var completedAttachmentUploadOrder: [UUID] = []
  private static let completedAttachmentUploadLimit = 128

  public init(
    services: ApplicationServices,
    environmentID: UUID,
    environmentName: String = Host.current().localizedName ?? "This Mac",
    hostVersion: String? = nil,
    pairingStore: RemotePairingStore? = nil,
    isOwnerClient: Bool = false
  ) {
    self.isOwnerClient = isOwnerClient
    self.services = services
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.hostVersion = hostVersion
    self.pairingStore = pairingStore
    self.attachmentTransfers = MobileAttachmentTransferStore(
      directory: URL(fileURLWithPath: services.defaultWorkspacePath, isDirectory: true)
        .appending(path: ".otto/mobile-uploads", directoryHint: .isDirectory)
    )
  }

  public func secureLogin(_ input: SecureLoginInput, deviceID: UUID) async throws
    -> SecureLoginOutput
  {
    try await services.websiteAccounts.secureInput(input, deviceID: deviceID)
  }

  public func environment() async -> ExecutionEnvironment {
    var capabilities: Set<EnvironmentCapability> = [.conversations, .approvals, .attachments]
    if services.observability != nil { capabilities.insert(.diagnostics) }
    return ExecutionEnvironment(
      id: environmentID,
      name: environmentName,
      kind: .macHost,
      status: services.isOnline ? .online : .degraded,
      // The Mac still owns files, canvas, browser, shell, and credentials. Mobile advertises only
      // the capabilities that have a dedicated, scoped RPC implementation.
      capabilities: capabilities,
      protocolVersion: OttoRPCProtocol.currentVersion,
      hostVersion: hostVersion,
      lastSeenAt: .now
    )
  }

  public func listThreads() async throws -> [OttoModels.Thread] {
    let channels = services.botChannels.channels.filter(isVisible)
    // All channel-bound nodes, including archived channels, are excluded from ordinary sessions.
    let boundNodes = Set(services.botChannels.channels.compactMap(\.nodeID))
    let sessions = services.store.snapshot.canvases.flatMap(\.nodes).filter {
      isVisible($0) && !boundNodes.contains($0.id)
    }.map(makeSessionThread)
    return (channels.map(makeThread) + sessions).sorted { $0.updatedAt > $1.updatedAt }
  }

  public func listBots() async throws -> MobileRosterOutput {
    let activeProfiles = services.agentProfiles.activeProfiles.filter { mobileMayUse($0.id) }
    let bots: [OttoModels.MobileBotSummary] = activeProfiles.map { profile in
      let channel = services.botChannels.canonicalChannel(for: profile.id)
      return OttoModels.MobileBotSummary(
        id: profile.id,
        name: profile.name,
        jobTitle: profile.jobTitle,
        role: profile.role,
        provider: profile.provider,
        hasSession: channel.map(isVisible) ?? false,
        updatedAt: max(profile.updatedAt, channel?.updatedAt ?? profile.updatedAt)
      )
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    let names = Dictionary(uniqueKeysWithValues: activeProfiles.map { ($0.id, $0.name) })
    let teams: [OttoModels.MobileTeamSummary] = services.botChannels.channels
      .filter { !$0.archived && $0.kind == .group }.map {
        OttoModels.MobileTeamSummary(
          id: $0.id,
          name: $0.displayTitle(profileNames: names),
          memberProfileIDs: $0.memberProfileIDs,
          orchestratorProfileID: $0.orchestratorProfileID,
          updatedAt: $0.updatedAt
        )
      }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    return MobileRosterOutput(bots: bots, teams: teams)
  }

  public func createBot(_ input: BotCreateInput) async throws -> OttoModels.MobileBotSummary {
    let profile = try services.createBot(
      BotCreationRequest(
        name: input.name, responsibility: input.responsibility, provider: input.provider,
        model: input.model))
    return OttoModels.MobileBotSummary(
      id: profile.id, name: profile.name, jobTitle: profile.jobTitle, role: profile.role,
      provider: profile.provider, hasSession: false, updatedAt: profile.updatedAt)
  }

  public func startThread(_ input: ThreadStartInput) async throws -> ThreadStartOutput {
    guard let profile = services.agentProfiles.profile(id: input.botProfileID), !profile.isArchived,
      mobileMayUse(profile.id)
    else {
      throw OttoHostError.botNotFound(input.botProfileID)
    }
    let existing = services.botChannels.canonicalChannel(for: profile.id).map(isVisible) ?? false
    let canvas = services.store.activeCanvas
    let offset = Double(canvas.nodes.count * 22)
    let point = WorldPoint(
      x: canvas.viewport.centerX - 170 + offset,
      y: canvas.viewport.centerY - 100 + offset
    )
    let nodeID = try await services.openBotChannel(profile, at: point)
    guard let channel = services.botChannels.canonicalChannel(for: profile.id),
      channel.nodeID == nodeID
    else { throw OttoHostError.journal("The started bot was not bound to its canonical channel") }
    if let message = input.initialMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    {
      _ = try await sendMessage(threadID: channel.conversationID, body: message)
    }
    return ThreadStartOutput(thread: makeThread(channel), openedExisting: existing)
  }

  public func snapshot(threadID: UUID) async throws -> ThreadSnapshot {
    if let channel = channel(threadID: threadID), channel.kind == .group {
      let room = services.botGroups.latestSession(forChannel: channel.id)
      let messages = (room?.messages ?? []).map { message in
        let profileID: UUID? = if case .bot(let id) = message.author { id } else { nil }
        return ThreadMessage(
          id: message.id, role: profileID == nil ? .user : .assistant,
          text: message.text,
          author: RunEventAuthor(
            role: profileID == nil ? .user : .assistant,
            botProfileID: profileID,
            displayName: profileID.flatMap { services.agentProfiles.profile(id: $0)?.name }),
          createdAt: message.createdAt)
      }
      let runtimeID = services.activeTeamRuntimeID(channelID: channel.id)
      let runID =
        if let runtimeID { try? await services.supervisor.snapshot(agentID: runtimeID).runID } else
        { nil as UUID? }
      return ThreadSnapshot(
        thread: makeThread(channel), messages: messages,
        lastEventSequence: 0, activeRunID: runID)
    }
    guard let nodeID = nodeID(threadID: threadID),
      let node = services.store.snapshot.canvases.lazy.flatMap(\.nodes).first(where: {
        $0.id == nodeID
      })
    else { throw OttoHostError.threadNotFound(threadID) }
    await services.restorePersistedAgentTranscript(nodeID: nodeID)
    let channel = channel(threadID: threadID)
    let profileID = channel?.profileID ?? node.agentDefinition?.profileID
    let profile = profileID.flatMap { services.agentProfiles.profile(id: $0) }
    let runtime =
      (try? await services.supervisor.snapshot(agentID: nodeID)) ?? services.fleet[nodeID]
    let messages =
      runtime?.transcript.map { entry in
        ThreadMessage(
          id: entry.id,
          role: messageRole(entry.role),
          kind: messageKind(entry.kind),
          text: entry.text,
          detail: entry.detail,
          author: RunEventAuthor(
            role: messageRole(entry.role),
            botProfileID: entry.role == .assistant ? profileID : nil,
            displayName: entry.role == .assistant ? profile?.name : nil
          ),
          createdAt: entry.createdAt
        )
      } ?? []
    let thread = channel.map(makeThread) ?? makeSessionThread(node)
    return ThreadSnapshot(
      thread: thread, messages: messages, lastEventSequence: 0,
      activeRunID: runtime.flatMap {
        [.starting, .working, .waitingPermission, .waitingUser].contains($0.state) ? $0.runID : nil
      })
  }

  public func sendMessage(threadID: UUID, body: String) async throws -> ThreadMessage {
    guard services.isOnline else {
      throw OttoHostError.journal("Otto is still starting. Wait a moment and send again.")
    }
    if let channel = channel(threadID: threadID), channel.kind == .group {
      try await services.sendTeamMessage(
        channelID: channel.id, text: body,
        at: WorldPoint(
          x: services.store.activeCanvas.viewport.centerX,
          y: services.store.activeCanvas.viewport.centerY))
      guard
        let message = services.botGroups.latestSession(forChannel: channel.id)?.messages.last(
          where: {
            $0.author == .user && $0.text == body
          })
      else { throw OttoHostError.journal("The team did not persist the accepted message") }
      return ThreadMessage(
        id: message.id, role: .user, text: message.text, createdAt: message.createdAt)
    }
    guard let nodeID = nodeID(threadID: threadID) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    try await services.sendPrompt(agentID: nodeID, prompt: body)
    guard
      let entry = try await services.supervisor.snapshot(agentID: nodeID).transcript.last(where: {
        $0.role == .user && $0.text == body
      })
    else {
      throw OttoHostError.journal("The accepted prompt was not present in the runtime transcript")
    }
    return ThreadMessage(
      id: entry.id,
      role: .user,
      kind: messageKind(entry.kind),
      text: entry.text,
      detail: entry.detail,
      author: RunEventAuthor(role: .user),
      createdAt: entry.createdAt
    )
  }

  public func interrupt(threadID: UUID, runID: UUID) async throws {
    guard let nodeID = nodeID(threadID: threadID) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    do {
      try await services.supervisor.interrupt(agentID: nodeID, expectedRunID: runID)
    } catch RuntimeError.staleRun { throw OttoHostError.staleRun }
  }

  public func stop(threadID: UUID, runID: UUID) async throws {
    guard let nodeID = nodeID(threadID: threadID) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    do {
      try await services.supervisor.stop(agentID: nodeID, expectedRunID: runID)
    } catch RuntimeError.staleRun { throw OttoHostError.staleRun }
  }

  public func pendingApproval(threadID: UUID) async throws -> MobileApprovalRequest? {
    if channel(threadID: threadID)?.kind == .group, nodeID(threadID: threadID) == nil { return nil }
    guard let nodeID = nodeID(threadID: threadID) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    guard let pending = await services.supervisor.pendingPermission(agentID: nodeID) else {
      return nil
    }
    return MobileApprovalRequest(
      requestID: pending.requestID,
      threadID: threadID,
      runID: pending.runID,
      reason: pending.reason,
      nonce: pending.nonce,
      requestedAt: pending.requestedAt
    )
  }

  public func respondToApproval(_ input: ApprovalRespondInput) async throws {
    guard let nodeID = nodeID(threadID: input.threadID) else {
      throw OttoHostError.threadNotFound(input.threadID)
    }
    do {
      try await services.supervisor.resolvePermission(
        agentID: nodeID,
        requestID: input.requestID,
        nonce: input.nonce,
        approved: input.decision == .approveOnce
      )
      services.acknowledgeAttention(nodeID: nodeID)
    } catch RuntimeError.noPendingPermission {
      throw OttoHostError.approvalUnavailable
    }
  }

  public func listAttachments(threadID: UUID) async throws -> [OttoAttachment] {
    if channel(threadID: threadID)?.kind == .group { return [] }
    guard let nodeID = nodeID(threadID: threadID) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    return services.store.snapshot.canvases.lazy.flatMap(\.nodes)
      .first(where: { $0.id == nodeID })?.attachments ?? []
  }

  public func prepareAttachmentUpload(
    _ input: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    guard nodeID(threadID: input.threadID) != nil else {
      throw OttoHostError.threadNotFound(input.threadID)
    }
    return try await attachmentTransfers.prepare(input)
  }

  public func uploadAttachmentChunk(
    _ input: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    guard let nodeID = nodeID(threadID: input.threadID) else {
      throw OttoHostError.threadNotFound(input.threadID)
    }
    if let completed = completedAttachmentUploads[input.uploadID] {
      guard completed.threadID == input.threadID,
        completed.retryOffset == input.offset,
        completed.retryData == input.data
      else {
        throw OttoHostError.attachmentTransferUnavailable
      }
      return AttachmentUploadChunkOutput(
        receivedBytes: completed.attachment.byteCount,
        complete: true,
        attachment: completed.attachment
      )
    }
    let result = try await attachmentTransfers.append(input)
    guard let staged = result.completed else {
      return AttachmentUploadChunkOutput(receivedBytes: result.receivedBytes, complete: false)
    }
    defer { Task { await attachmentTransfers.discard(staged) } }
    let imported = try await services.importAttachments([staged.fileURL], to: nodeID)
    guard let attachment = imported.first else {
      throw OttoHostError.invalidAttachment("The completed upload was not imported.")
    }
    completedAttachmentUploads[input.uploadID] = (
      input.threadID,
      attachment,
      input.offset,
      input.data
    )
    completedAttachmentUploadOrder.append(input.uploadID)
    if completedAttachmentUploadOrder.count > Self.completedAttachmentUploadLimit {
      let expiredUploadID = completedAttachmentUploadOrder.removeFirst()
      completedAttachmentUploads.removeValue(forKey: expiredUploadID)
    }
    return AttachmentUploadChunkOutput(
      receivedBytes: attachment.byteCount,
      complete: true,
      attachment: attachment
    )
  }

  public func downloadAttachmentChunk(
    _ input: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    guard (1...MobileAttachmentTransferStore.chunkSize).contains(input.limit), input.offset >= 0
    else {
      throw OttoHostError.invalidAttachment("The download range is outside its bounds.")
    }
    let attachment = try await listAttachments(threadID: input.threadID)
      .first(where: { $0.id == input.attachmentID })
    guard let attachment else { throw OttoHostError.attachmentTransferUnavailable }
    guard input.offset <= attachment.byteCount else {
      throw OttoHostError.invalidAttachment("The download offset exceeds the file size.")
    }
    let root = URL(fileURLWithPath: services.defaultWorkspacePath, isDirectory: true)
      .standardizedFileURL
    let fileURL = root.appending(path: attachment.relativePath).standardizedFileURL
    let values = try? fileURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard fileURL.path.hasPrefix(root.path + "/"),
      values?.isRegularFile == true,
      values?.isSymbolicLink != true,
      Int64(values?.fileSize ?? -1) == attachment.byteCount
    else { throw OttoHostError.invalidAttachment("The stored file is unavailable or unsafe.") }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(input.offset))
    let data = try handle.read(upToCount: input.limit) ?? Data()
    let next = input.offset + Int64(data.count)
    guard next <= attachment.byteCount else {
      throw OttoHostError.invalidAttachment("The stored file exceeds its declared size.")
    }
    return AttachmentDownloadChunkOutput(
      attachment: attachment,
      offset: input.offset,
      data: data,
      hasMore: next < attachment.byteCount,
      sha256: next == attachment.byteCount ? try attachmentSHA256(fileURL) : nil
    )
  }

  private func attachmentSHA256(_ fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public func diagnostics() async throws -> MobileDiagnosticsOutput {
    guard let observability = services.observability else {
      throw OttoHostError.diagnosticsUnavailable
    }
    let snapshot = await observability.snapshot()
    let events = await observability.timeline().suffix(MobileDiagnosticsOutput.maximumRecentEvents)
      .compactMap { event -> MobileDiagnosticEvent? in
        guard let kind = MobileDiagnosticEventKind(rawValue: event.kind.rawValue) else {
          return nil
        }
        return MobileDiagnosticEvent(
          id: event.id,
          timestamp: event.timestamp,
          kind: kind,
          toolName: event.toolName,
          provider: event.provider,
          agentState: event.agentState.flatMap {
            MobileDiagnosticAgentState(rawValue: $0.rawValue)
          },
          targetOrdinal: event.targetOrdinal,
          durationMilliseconds: event.durationMilliseconds,
          succeeded: event.succeeded,
          exitCode: event.exitCode
        )
      }
    let output = MobileDiagnosticsOutput(
      generatedAt: snapshot.generatedAt,
      appVersion: snapshot.appVersion,
      operatingSystemVersion: snapshot.operatingSystemVersion,
      previousSessionAbnormal: snapshot.previousSessionAbnormal,
      eventCounts: snapshot.eventCounts,
      toolSuccessCount: snapshot.toolSuccessCount,
      toolFailureCount: snapshot.toolFailureCount,
      toolLatencyMedianMilliseconds: snapshot.toolLatencyMedianMilliseconds,
      providerFailureCount: snapshot.providerFailureCount,
      recentEvents: events
    )
    guard output.isPrivacySafe else { throw OttoHostError.diagnosticsUnavailable }
    return output
  }

  public func registerPush(deviceID: UUID, input: DeviceRegisterPushInput) async throws {
    guard let pairingStore else { throw OttoHostError.unsupportedOperation("Push registration") }
    try await pairingStore.registerPush(
      deviceID: deviceID,
      token: input.token,
      environment: input.environment == .sandbox ? .sandbox : .production
    )
  }

  /// Mobile reaches only the bots the Mac owner allowed for the Mobile connector.
  private func mobileMayUse(_ profileID: UUID) -> Bool {
    isOwnerClient || services.connectorAccess.canUse(.mobile, profileID: profileID)
  }

  private func channel(threadID: UUID) -> BotChannel? {
    services.botChannels.channels.first {
      isVisible($0) && $0.conversationID == threadID
    }
  }

  private func isVisible(_ node: OttoNode) -> Bool {
    guard node.kind == .agent else { return false }
    guard let profileID = node.agentDefinition?.profileID else { return true }
    return services.agentProfiles.profile(id: profileID)?.isArchived == false
      && mobileMayUse(profileID)
  }

  private func isVisible(_ channel: BotChannel) -> Bool {
    guard !channel.archived else { return false }
    if channel.kind == .group { return channel.memberProfileIDs.allSatisfy(mobileMayUse) }
    guard services.agentProfiles.profile(id: channel.profileID)?.isArchived == false,
      mobileMayUse(channel.profileID),
      let nodeID = channel.nodeID
    else { return false }
    return services.store.snapshot.canvases.lazy.flatMap(\.nodes).contains {
      $0.id == nodeID && isVisible($0)
    }
  }

  func threadID(nodeID: UUID) -> UUID? {
    if let channel = services.botChannels.channels.first(where: { $0.nodeID == nodeID }) {
      return isVisible(channel) ? channel.conversationID : nil
    }
    return services.store.snapshot.canvases.lazy.flatMap(\.nodes).contains {
      $0.id == nodeID && isVisible($0)
    } ? nodeID : nil
  }

  func nodeID(threadID: UUID) -> UUID? {
    if let channel = channel(threadID: threadID) {
      return channel.kind == .group
        ? services.activeTeamRuntimeID(channelID: channel.id) : channel.nodeID
    }
    guard !services.botChannels.channels.contains(where: { $0.nodeID == threadID }) else {
      return nil
    }
    return services.store.snapshot.canvases.lazy.flatMap(\.nodes).first {
      $0.id == threadID && isVisible($0)
    }?.id
  }

  private func makeSessionThread(_ node: OttoNode) -> OttoModels.Thread {
    let runtime = services.fleet[node.id]
    return OttoModels.Thread(
      id: node.id, kind: .task, title: node.displayName,
      botProfileIDs: node.agentDefinition?.profileID.map { [$0] } ?? [], nodeID: node.id,
      executionEnvironmentID: environmentID,
      runtimeSessionID: runtime?.providerSessionID ?? node.agentDefinition?.resumeSessionID,
      state: runtime.map { threadState($0.state) } ?? threadState(node.status),
      createdAt: node.createdAt,
      updatedAt: runtime?.completedAt ?? runtime?.startedAt ?? node.createdAt)
  }

  private func makeThread(_ channel: BotChannel) -> OttoModels.Thread {
    if channel.kind == .group {
      let names = Dictionary(
        uniqueKeysWithValues: services.agentProfiles.profiles.map { ($0.id, $0.name) })
      let room = services.botGroups.latestSession(forChannel: channel.id)
      return OttoModels.Thread(
        id: channel.conversationID, kind: .group,
        title: channel.displayTitle(profileNames: names), botProfileIDs: channel.memberProfileIDs,
        channelID: channel.id, executionEnvironmentID: environmentID,
        state: services.isTeamRunning(channelID: channel.id)
          ? .working : (room?.needsUser == true ? .waitingForUser : .idle),
        createdAt: channel.createdAt, updatedAt: room?.updatedAt ?? channel.updatedAt)
    }
    let node = channel.nodeID.flatMap { nodeID in
      services.store.snapshot.canvases.lazy.flatMap(\.nodes).first { $0.id == nodeID }
    }
    let profile = services.agentProfiles.profile(id: channel.profileID)
    let runtime = channel.nodeID.flatMap { services.fleet[$0] }
    return OttoModels.Thread(
      id: channel.conversationID,
      kind: .botChannel,
      title: profile?.name ?? node?.displayName ?? "Otto session",
      botProfileIDs: channel.memberProfileIDs.isEmpty
        ? [channel.profileID] : channel.memberProfileIDs,
      channelID: channel.id,
      nodeID: channel.nodeID,
      executionEnvironmentID: environmentID,
      runtimeSessionID: runtime?.providerSessionID ?? node?.agentDefinition?.resumeSessionID,
      state: runtime.map { threadState($0.state) } ?? node.map { threadState($0.status) } ?? .idle,
      createdAt: channel.createdAt,
      updatedAt: channel.updatedAt
    )
  }

  private func threadState(_ state: AgentLifecycleState) -> ThreadState {
    switch state {
    case .created, .idle: .idle
    case .starting, .working: .working
    case .waitingPermission: .approvalRequired
    case .waitingUser: .waitingForUser
    case .done: .done
    case .failed: .failed
    case .interrupted, .stopped: .stopped
    }
  }

  private func threadState(_ state: NodeStatus) -> ThreadState {
    switch state {
    case .starting, .working: .working
    case .idle: .idle
    case .waiting: .waitingForUser
    case .done: .done
    case .failed: .failed
    case .stopped: .stopped
    }
  }

  private func messageRole(_ role: AgentTranscriptRole) -> ThreadMessageRole {
    switch role {
    case .user: .user
    case .assistant: .assistant
    case .activity: .activity
    }
  }

  private func messageKind(_ kind: AgentTranscriptKind) -> ThreadMessageKind {
    switch kind {
    case .text: .text
    case .reasoning: .reasoning
    case .toolCall: .toolCall
    case .notice: .notice
    }
  }
}

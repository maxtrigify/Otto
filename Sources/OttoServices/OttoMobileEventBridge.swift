import Foundation
import OttoHostRuntime
import OttoModels
import OttoRemote
import OttoRuntime

/// Converts the existing broadcast runtime lifecycle into canonical, persisted mobile events.
/// Raw PTY output is never forwarded: mobile receives only structured transcript and state data.
@MainActor
public final class OttoMobileEventBridge {
  private let services: ApplicationServices
  private let adapter: ApplicationServicesMobileHostAdapter
  private let host: OttoHostRuntime
  private let pushWorker: OttoAPNsDeliveryWorker?
  private var task: Task<Void, Never>?
  private var knownMessageIDs: [UUID: Set<UUID>] = [:]
  private var activeRunIDs: [UUID: UUID] = [:]

  public init(
    services: ApplicationServices,
    adapter: ApplicationServicesMobileHostAdapter,
    host: OttoHostRuntime,
    pushWorker: OttoAPNsDeliveryWorker? = nil
  ) {
    self.services = services
    self.adapter = adapter
    self.host = host
    self.pushWorker = pushWorker
  }

  public func start() async {
    guard task == nil else { return }
    let eventBus = services.supervisor.eventBus
    // Capture the cursor before the snapshot. Anything emitted while transcripts are being
    // seeded is then replayed from the broadcast bus instead of falling into a startup gap.
    let cursor = eventBus.latestSequence
    await seedExistingTranscripts()
    task = Task { [weak self] in
      for await event in eventBus.stream(afterSequence: cursor) {
        guard !Task.isCancelled, let self else { return }
        await self.consume(event)
      }
    }
  }

  public func stop() {
    task?.cancel()
    task = nil
  }

  private func seedExistingTranscripts() async {
    guard let threads = try? await adapter.listThreads() else { return }
    for thread in threads {
      guard let snapshot = try? await adapter.snapshot(threadID: thread.id) else { continue }
      knownMessageIDs[thread.id] = Set(snapshot.messages.map(\.id))
    }
  }

  private func consume(_ event: OttoEvent) async {
    if let channelID = event.channelID
      ?? event.nodeID.flatMap({ services.teamChannelID(runtimeID: $0) }),
      let channel = services.botChannels.channel(id: channelID), channel.kind == .group,
      !channel.archived
    {
      await publishRoom(channel: channel, event: event)
      return
    }
    guard let nodeID = event.nodeID, let threadID = adapter.threadID(nodeID: nodeID) else { return }
    await publishNewMessages(nodeID: nodeID, threadID: threadID)

    do {
      switch event.type {
      case .agentRunStarted:
        let runID = event.runID ?? event.id
        activeRunIDs[nodeID] = runID
        _ = try await host.publish(
          RunEventDraft(
            id: event.id,
            threadID: threadID,
            timestamp: event.timestamp,
            kind: .runStarted,
            content: RunEventContent(runID: runID, state: .working)
          ))
      case .agentStatusChanged:
        guard let state = event.state else { return }
        let threadState = map(state)
        let approval =
          state == .waitingPermission
          ? try await adapter.pendingApproval(threadID: threadID)
          : nil
        let content =
          if let approval {
            RunEventContent(
              runID: event.runID ?? activeRunIDs[nodeID],
              state: threadState,
              approval: approval,
              notification: notification(for: state)
            )
          } else {
            RunEventContent(
              runID: event.runID ?? activeRunIDs[nodeID],
              state: threadState,
              notification: notification(for: state)
            )
          }
        try await publishAndNotify(
          RunEventDraft(
            id: event.id,
            threadID: threadID,
            timestamp: event.timestamp,
            kind: state == .waitingPermission ? .approvalRequested : .runStateChanged,
            content: content
          ), nodeID: nodeID)
      case .agentRunCompleted:
        try await publishAndNotify(
          RunEventDraft(
            id: event.id,
            threadID: threadID,
            timestamp: event.timestamp,
            kind: .runCompleted,
            content: RunEventContent(
              runID: activeRunIDs.removeValue(forKey: nodeID) ?? event.runID,
              state: .done,
              notification: .completion
            )
          ), nodeID: nodeID)
      case .agentRunFailed:
        try await publishAndNotify(
          RunEventDraft(
            id: event.id,
            threadID: threadID,
            timestamp: event.timestamp,
            kind: .runFailed,
            content: RunEventContent(
              runID: activeRunIDs.removeValue(forKey: nodeID) ?? event.runID,
              state: .failed,
              notification: .failure
            )
          ), nodeID: nodeID)
      case .agentExited:
        _ = try await host.publish(
          RunEventDraft(
            id: event.id,
            threadID: threadID,
            timestamp: event.timestamp,
            kind: .threadStateChanged,
            content: RunEventContent(
              runID: activeRunIDs.removeValue(forKey: nodeID) ?? event.runID,
              state: .stopped,
              detail: event.exitCode.map { "Provider exited with code \($0)" }
            )
          ))
      case .agentOutputAppended, .botPresenceChanged, .botMessageDelivered, .botNeedsUser,
        .botChannelUpdated, .routineFired, .routineCompleted:
        break
      }
    } catch {
      services.errorMessage = "Mobile event bridge: \(error.localizedDescription)"
    }
  }

  private func publishRoom(channel: BotChannel, event: OttoEvent) async {
    do {
      let snapshot = try await adapter.snapshot(threadID: channel.conversationID)
      for message in snapshot.messages
      where knownMessageIDs[channel.conversationID]?.contains(message.id) != true {
        if await host.journal.event(threadID: channel.conversationID, messageID: message.id) == nil
        {
          _ = try await host.publish(
            RunEventDraft(
              id: message.id, threadID: channel.conversationID,
              timestamp: message.createdAt, kind: .messageAdded, author: message.author,
              content: RunEventContent(message: message)))
        }
        knownMessageIDs[channel.conversationID, default: []].insert(message.id)
      }
      let approval = try await adapter.pendingApproval(threadID: channel.conversationID)
      var content = RunEventContent(runID: snapshot.activeRunID, state: snapshot.thread.state)
      if let approval {
        content = RunEventContent(
          runID: snapshot.activeRunID, state: .approvalRequired, approval: approval)
      }
      _ = try await host.publish(
        RunEventDraft(
          id: event.id, threadID: channel.conversationID,
          timestamp: event.timestamp,
          kind: approval == nil ? .threadStateChanged : .approvalRequested,
          content: content))
    } catch {
      services.errorMessage = "Mobile team bridge: \(error.localizedDescription)"
    }
  }

  private func publishAndNotify(_ draft: RunEventDraft, nodeID: UUID) async throws {
    let event = try await host.publish(draft)
    guard let pushWorker,
      let profileID = services.store.snapshot.canvases.lazy.flatMap(\.nodes)
        .first(where: { $0.id == nodeID })?.agentDefinition?.profileID,
      let title = services.agentProfiles.profile(id: profileID)?.name,
      let notification = OttoAPNsNotification(event: event, threadTitle: title)
    else { return }
    try await pushWorker.enqueue(notification)
    Task { await pushWorker.drainAvailable() }
  }

  private func publishNewMessages(nodeID: UUID, threadID: UUID) async {
    guard let snapshot = try? await services.supervisor.snapshot(agentID: nodeID) else { return }
    for entry in snapshot.transcript where knownMessageIDs[threadID]?.contains(entry.id) != true {
      if await host.journal.event(threadID: threadID, messageID: entry.id) != nil {
        knownMessageIDs[threadID, default: []].insert(entry.id)
        continue
      }
      let message = map(entry, nodeID: nodeID)
      do {
        _ = try await host.publish(
          RunEventDraft(
            id: entry.id,
            threadID: threadID,
            timestamp: entry.createdAt,
            kind: .messageAdded,
            author: message.author,
            content: RunEventContent(message: message)
          ))
        knownMessageIDs[threadID, default: []].insert(entry.id)
      } catch {
        services.errorMessage = "Mobile transcript bridge: \(error.localizedDescription)"
      }
    }
  }

  private func map(_ entry: AgentTranscriptEntry, nodeID: UUID) -> ThreadMessage {
    let role: ThreadMessageRole =
      switch entry.role {
      case .user: .user
      case .assistant: .assistant
      case .activity: .activity
      }
    let kind: ThreadMessageKind =
      switch entry.kind {
      case .text: .text
      case .reasoning: .reasoning
      case .toolCall: .toolCall
      case .notice: .notice
      }
    let profileID = services.store.snapshot.canvases.lazy.flatMap(\.nodes)
      .first(where: { $0.id == nodeID })?.agentDefinition?.profileID
    return ThreadMessage(
      id: entry.id,
      role: role,
      kind: kind,
      text: entry.text,
      detail: entry.detail,
      author: RunEventAuthor(
        role: role,
        botProfileID: entry.role == .assistant ? profileID : nil,
        displayName: profileID.flatMap { services.agentProfiles.profile(id: $0)?.name }
      ),
      createdAt: entry.createdAt
    )
  }

  private func map(_ state: AgentLifecycleState) -> ThreadState {
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

  private func notification(for state: AgentLifecycleState) -> RunEventNotification {
    switch state {
    case .waitingPermission: .approval
    case .waitingUser: .needsUser
    // Terminal lifecycle events carry completion/failure exactly once. Status changes retain only
    // the attention transitions that have no separate terminal event.
    case .created, .starting, .idle, .working, .done, .failed, .interrupted, .stopped: .none
    }
  }
}

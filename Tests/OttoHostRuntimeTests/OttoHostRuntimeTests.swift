import Foundation
import OttoHostRuntime
import OttoModels
import OttoRPCContracts
import Testing

@Suite("Otto local mobile host")
struct OttoHostRuntimeTests {
  @Test("Journal persists per-thread cursors and reconnects without duplicates")
  func journalReconnect() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let journal = try RunEventJournal(directory: fixture.events)
    let first = try await journal.append(
      RunEventDraft(threadID: fixture.thread.id, kind: .runStarted))
    let second = try await journal.append(
      RunEventDraft(
        threadID: fixture.thread.id,
        kind: .runCompleted,
        causationID: first.id,
        content: RunEventContent(state: .done, notification: .completion)
      ))
    let duplicate = try await journal.append(
      RunEventDraft(
        id: second.id,
        threadID: fixture.thread.id,
        kind: .runCompleted,
        content: second.content
      ))
    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(duplicate == second)

    let restored = try RunEventJournal(directory: fixture.events)
    let page = try await restored.page(
      threadID: fixture.thread.id,
      afterSequence: first.sequence,
      limit: 20
    )
    #expect(page.events == [second])
    #expect(page.latestSequence == 2)
    #expect(page.hasMore == false)
  }

  @Test("A retried client message is acknowledged but dispatched only once")
  func idempotentMessageSend() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let journal = try RunEventJournal(directory: fixture.events)
    let host = OttoHostRuntime(dataSource: source, journal: journal)
    let clientMessageID = UUID()
    let request = try OttoRPCRequest(
      method: .messageSend,
      parameters: MessageSendInput(
        threadID: fixture.thread.id,
        clientMessageID: clientMessageID,
        body: "  Continue from mobile  "
      ))
    let client = OttoHostClientContext(deviceID: UUID(), scopes: [.messageWrite])

    let first = try await host.handle(request, client: client)
      .decodeResult(MessageSendOutput.self)
    let retry = try await host.handle(request, client: client)
      .decodeResult(MessageSendOutput.self)

    #expect(first.duplicate == false)
    #expect(retry.duplicate == true)
    #expect(retry.event.id == first.event.id)
    #expect(retry.event.sequence == first.event.sequence)
    #expect(await source.sentMessages() == ["Continue from mobile"])

    let restartedJournal = try RunEventJournal(directory: fixture.events)
    let restartedHost = OttoHostRuntime(dataSource: source, journal: restartedJournal)
    let afterRestart = try await restartedHost.handle(request, client: client)
      .decodeResult(MessageSendOutput.self)
    #expect(afterRestart.duplicate == true)
    #expect(afterRestart.event.id == first.event.id)
    #expect(await source.sentMessages().count == 1)
  }

  @Test("Concurrent identical messages share one dispatch and reject changed payloads")
  func concurrentSubmission() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let host = OttoHostRuntime(
      dataSource: source, journal: try RunEventJournal(directory: fixture.events))
    let id = UUID()
    let request = try OttoRPCRequest(
      method: .messageSend,
      parameters: MessageSendInput(
        threadID: fixture.thread.id, clientMessageID: id, body: "One task"))
    let client = OttoHostClientContext(deviceID: UUID(), scopes: [.messageWrite])
    await withTaskGroup(of: OttoRPCResponse.self) { group in
      for _ in 0..<20 { group.addTask { await host.handle(request, client: client) } }
      for await response in group { #expect(response.error == nil) }
    }
    #expect(await source.sentMessages() == ["One task"])
    let changed = try OttoRPCRequest(
      method: .messageSend,
      parameters: MessageSendInput(
        threadID: fixture.thread.id, clientMessageID: id, body: "Different task"))
    let conflict = await host.handle(changed, client: client)
    #expect(conflict.error?.code == "command_conflict")
  }

  @Test("An interrupted admission survives restart and is not dispatched again")
  func uncertainAdmission() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let command = MessageSendInput(
      threadID: fixture.thread.id, clientMessageID: UUID(), body: "Task")
    let journal = try RunEventJournal(directory: fixture.events)
    #expect(try await journal.reserveCommand(command) == nil)
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let restored = OttoHostRuntime(
      dataSource: source, journal: try RunEventJournal(directory: fixture.events))
    let response = await restored.handle(
      try OttoRPCRequest(method: .messageSend, parameters: command),
      client: OttoHostClientContext(deviceID: UUID(), scopes: [.messageWrite]))
    #expect(response.error?.code == "command_uncertain")
    #expect(await source.sentMessages().isEmpty)
  }

  @Test("An event published during snapshot collection remains available to replay")
  func concurrentSnapshotEvent() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let journal = try RunEventJournal(directory: fixture.events)
    await source.onSnapshot {
      _ = try? await journal.append(RunEventDraft(threadID: fixture.thread.id, kind: .runCompleted))
    }
    let host = OttoHostRuntime(dataSource: source, journal: journal)
    let request = try OttoRPCRequest(
      method: .threadGetSnapshot,
      parameters: ThreadReferenceInput(threadID: fixture.thread.id))
    let snapshot = try await host.handle(
      request,
      client: OttoHostClientContext(deviceID: UUID(), scopes: [.threadRead])
    ).decodeResult(ThreadSnapshot.self)
    #expect(snapshot.lastEventSequence == 0)
    #expect(await journal.latestSequence(threadID: fixture.thread.id) == 1)
  }

  @Test("Snapshot and delta cursor meet without replaying the snapshot")
  func snapshotThenDelta() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let journal = try RunEventJournal(directory: fixture.events)
    let host = OttoHostRuntime(dataSource: source, journal: journal)
    _ = try await host.publish(
      RunEventDraft(threadID: fixture.thread.id, kind: .runStarted))
    _ = try await host.publish(
      RunEventDraft(threadID: fixture.thread.id, kind: .threadStateChanged))
    let client = OttoHostClientContext(deviceID: UUID(), scopes: [.threadRead])
    let snapshotRequest = try OttoRPCRequest(
      method: .threadGetSnapshot,
      parameters: ThreadReferenceInput(threadID: fixture.thread.id)
    )
    let snapshot = try await host.handle(snapshotRequest, client: client)
      .decodeResult(ThreadSnapshot.self)
    #expect(snapshot.lastEventSequence == 2)

    let completion = try await host.publish(
      RunEventDraft(
        threadID: fixture.thread.id,
        kind: .runCompleted,
        content: RunEventContent(state: .done, notification: .completion)
      ))
    let deltaRequest = try OttoRPCRequest(
      method: .threadEvents,
      parameters: ThreadEventCursorInput(
        threadID: fixture.thread.id,
        afterSequence: snapshot.lastEventSequence
      ))
    let delta = try await host.handle(deltaRequest, client: client)
      .decodeResult(ThreadEventPage.self)
    #expect(delta.events == [completion])
    #expect(Set(delta.events.map(\.id)).count == delta.events.count)
  }

  @Test("Protocol versions and per-method device scopes fail closed")
  func protocolAndScopes() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let host = OttoHostRuntime(
      dataSource: source,
      journal: try RunEventJournal(directory: fixture.events)
    )
    let noScopes = OttoHostClientContext(deviceID: UUID(), scopes: [])
    let forbidden = await host.handle(
      OttoRPCRequest(method: .threadList),
      client: noScopes
    )
    #expect(forbidden.error?.code == "forbidden")

    let future = await host.handle(
      OttoRPCRequest(protocolVersion: 999, method: .threadList),
      client: OttoHostClientContext(deviceID: UUID(), scopes: [.threadRead])
    )
    #expect(future.error?.code == "unsupported_protocol")
  }

  @Test("Diagnostics require environment scope and return only the typed safe projection")
  func diagnosticsScope() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let diagnostics = MobileDiagnosticsOutput(
      generatedAt: timestamp,
      appVersion: "0.1.0",
      operatingSystemVersion: "26.2",
      previousSessionAbnormal: true,
      eventCounts: [MobileDiagnosticEventKind.previousSessionAbnormal.rawValue: 1],
      toolSuccessCount: 2,
      toolFailureCount: 0,
      toolLatencyMedianMilliseconds: 12,
      providerFailureCount: 0,
      recentEvents: [
        MobileDiagnosticEvent(timestamp: timestamp, kind: .previousSessionAbnormal)
      ]
    )
    let source = FakeHostDataSource(
      environment: fixture.environment,
      threads: [fixture.thread],
      diagnostics: diagnostics
    )
    let host = OttoHostRuntime(
      dataSource: source,
      journal: try RunEventJournal(directory: fixture.events)
    )
    let request = OttoRPCRequest(method: .diagnosticsGet)

    let forbidden = await host.handle(
      request,
      client: OttoHostClientContext(deviceID: UUID(), scopes: [.threadRead])
    )
    #expect(forbidden.error?.code == "forbidden")

    let output = try await host.handle(
      request,
      client: OttoHostClientContext(deviceID: UUID(), scopes: [.environmentRead])
    ).decodeResult(MobileDiagnosticsOutput.self)
    #expect(output == diagnostics)
    #expect(output.isPrivacySafe)
  }

  @Test("Push registration is scoped to the authenticated paired device")
  func pushRegistration() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let source = FakeHostDataSource(environment: fixture.environment, threads: [fixture.thread])
    let host = OttoHostRuntime(
      dataSource: source,
      journal: try RunEventJournal(directory: fixture.events)
    )
    let deviceID = UUID()
    let input = DeviceRegisterPushInput(
      token: String(repeating: "ab", count: 32),
      environment: .sandbox
    )
    let request = try OttoRPCRequest(method: .deviceRegisterPush, parameters: input)
    let output = try await host.handle(
      request,
      client: OttoHostClientContext(deviceID: deviceID, scopes: [.environmentRead])
    ).decodeResult(AcceptedOutput.self)

    #expect(output.accepted)
    #expect(
      await source.pushRegistrations() == [PushRegistration(deviceID: deviceID, input: input)])
  }

  @Test("Approval responses require the exact live request and cannot be replayed")
  func approvalRoundTrip() async throws {
    let fixture = try HostFixture()
    defer { fixture.cleanup() }
    let approval = MobileApprovalRequest(
      requestID: UUID(),
      threadID: fixture.thread.id,
      runID: UUID(),
      reason: "Bash: publish the release tag",
      nonce: UUID().uuidString,
      requestedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let source = FakeHostDataSource(
      environment: fixture.environment,
      threads: [fixture.thread],
      approval: approval
    )
    let host = OttoHostRuntime(
      dataSource: source,
      journal: try RunEventJournal(directory: fixture.events)
    )
    let client = OttoHostClientContext(deviceID: UUID(), scopes: [.approvalRespond])
    let current = try await host.handle(
      try OttoRPCRequest(
        method: .approvalGet,
        parameters: ApprovalGetInput(threadID: fixture.thread.id)
      ),
      client: client
    ).decodeResult(ApprovalGetOutput.self)
    #expect(current.request == approval)

    let wrongNonce = ApprovalRespondInput(
      threadID: fixture.thread.id,
      requestID: approval.requestID,
      nonce: "stale-nonce",
      decision: .approveOnce
    )
    let stale = await host.handle(
      try OttoRPCRequest(method: .approvalRespond, parameters: wrongNonce),
      client: client
    )
    #expect(stale.error?.code == "approval_unavailable")

    let exact = ApprovalRespondInput(
      threadID: fixture.thread.id,
      requestID: approval.requestID,
      nonce: approval.nonce,
      decision: .approveOnce
    )
    let accepted = try await host.handle(
      try OttoRPCRequest(method: .approvalRespond, parameters: exact),
      client: client
    ).decodeResult(ApprovalRespondOutput.self)
    #expect(accepted.accepted)
    #expect(accepted.requestID == approval.requestID)
    #expect(await source.approvalDecisions() == [.approveOnce])

    let replay = await host.handle(
      try OttoRPCRequest(method: .approvalRespond, parameters: exact),
      client: client
    )
    #expect(replay.error?.code == "approval_unavailable")
  }
}

private struct PushRegistration: Equatable, Sendable {
  var deviceID: UUID
  var input: DeviceRegisterPushInput
}

private actor FakeHostDataSource: OttoHostDataSource {
  let hostEnvironment: ExecutionEnvironment
  let hostThreads: [OttoModels.Thread]
  var messages: [String] = []
  var registrations: [PushRegistration] = []
  var approval: MobileApprovalRequest?
  var decisions: [MobileApprovalDecision] = []
  var snapshotHook: (@Sendable () async -> Void)?
  func onSnapshot(_ hook: @escaping @Sendable () async -> Void) { snapshotHook = hook }
  let diagnosticOutput: MobileDiagnosticsOutput?

  init(
    environment: ExecutionEnvironment,
    threads: [OttoModels.Thread],
    approval: MobileApprovalRequest? = nil,
    diagnostics: MobileDiagnosticsOutput? = nil
  ) {
    hostEnvironment = environment
    hostThreads = threads
    self.approval = approval
    diagnosticOutput = diagnostics
  }

  func environment() async -> ExecutionEnvironment { hostEnvironment }
  func listThreads() async throws -> [OttoModels.Thread] { hostThreads }

  func snapshot(threadID: UUID) async throws -> ThreadSnapshot {
    guard let thread = hostThreads.first(where: { $0.id == threadID }) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    await snapshotHook?()
    return ThreadSnapshot(thread: thread, messages: [], lastEventSequence: 0)
  }

  func sendMessage(threadID _: UUID, body: String) async throws -> ThreadMessage {
    messages.append(body)
    return ThreadMessage(role: .user, text: body, author: RunEventAuthor(role: .user))
  }
  func interrupt(threadID _: UUID, runID _: UUID) async throws {}
  func stop(threadID _: UUID, runID _: UUID) async throws {}
  func registerPush(deviceID: UUID, input: DeviceRegisterPushInput) async throws {
    registrations.append(PushRegistration(deviceID: deviceID, input: input))
  }
  func sentMessages() -> [String] { messages }
  func pushRegistrations() -> [PushRegistration] { registrations }
  func pendingApproval(threadID: UUID) async throws -> MobileApprovalRequest? {
    guard hostThreads.contains(where: { $0.id == threadID }) else {
      throw OttoHostError.threadNotFound(threadID)
    }
    return approval
  }
  func respondToApproval(_ input: ApprovalRespondInput) async throws {
    guard let current = approval,
      current.threadID == input.threadID,
      current.requestID == input.requestID,
      current.nonce == input.nonce
    else { throw OttoHostError.approvalUnavailable }
    decisions.append(input.decision)
    approval = nil
  }
  func approvalDecisions() -> [MobileApprovalDecision] { decisions }
  func diagnostics() async throws -> MobileDiagnosticsOutput {
    guard let diagnosticOutput else { throw OttoHostError.diagnosticsUnavailable }
    return diagnosticOutput
  }
}

private struct HostFixture {
  let root: URL
  let events: URL
  let environment: ExecutionEnvironment
  let thread: OttoModels.Thread

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-host-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    events = root.appending(path: "events", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let environmentID = UUID()
    environment = ExecutionEnvironment(
      id: environmentID,
      name: "Test Mac",
      kind: .macHost,
      status: .online,
      capabilities: [.conversations],
      protocolVersion: OttoRPCProtocol.currentVersion
    )
    thread = OttoModels.Thread(
      id: UUID(),
      kind: .botChannel,
      title: "Ada",
      botProfileIDs: [UUID()],
      executionEnvironmentID: environmentID
    )
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

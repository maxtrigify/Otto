import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

/// An approval raised on the Mac — a session nobody opened from Telegram, or a routine's agent —
/// must reach the paired phone, not only approvals for runs Telegram started (issue #49).
/// These tests extend the media delivery suite so they run in series with it: all drive the real
/// connector against the globally registered fake Bot API.
extension TelegramMediaDeliveryTests {
  @Test("A session's approval reaches the paired chat with a label naming the work")
  func sessionApprovalRelaysToPairedChat() async throws {
    let harness = try await TelegramQueueHarness.make(updates: #"{"ok":true,"result":[]}"#)
    defer { harness.tearDown() }
    let session = try await harness.sessionNode()
    try await harness.services.supervisor.sendPrompt(agentID: session, prompt: "Fix the CSV import")
    let permission = Task {
      try? await harness.services.supervisor.requestPermission(
        agentID: session, toolName: "file.write", detail: "overwrite imports.csv")
    }
    // Off by default: nothing leaves the Mac until the owner allows approvals on Telegram.
    try await Task.sleep(for: .milliseconds(300))
    #expect(!harness.api.sentMessages.contains { $0.contains("asks for approval:") })

    harness.connector.setApprovalsFromTelegram(true)
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.contains { $0.contains("asks for approval:") }
    }
    let offered = try #require(
      harness.api.sentMessages.first { $0.contains("asks for approval:") })
    #expect(offered.contains("Fix the CSV import"))
    #expect(offered.contains("file.write: overwrite imports.csv"))
    // One offer per request, however many passes the watch makes.
    try await Task.sleep(for: .seconds(5))
    #expect(
      harness.api.sentMessages.filter { $0.contains("asks for approval:") }.count == 1)

    // Answering on the Mac ends the offer cycle; a new request gets a new offer.
    let pending = try #require(
      await harness.services.supervisor.pendingPermission(agentID: session))
    try await harness.services.supervisor.resolvePermission(
      agentID: session, requestID: pending.requestID, nonce: pending.nonce, approved: true)
    let answered = await permission.value
    #expect(answered == true)
    _ = try? await harness.services.supervisor.requestPermission(
      agentID: session, toolName: "file.write", detail: "create imports.bak", timeout: .seconds(8))
    try await waitUntil(timeout: .seconds(30), describe: harness.describe) {
      harness.api.sentMessages.filter { $0.contains("asks for approval:") }.count == 2
    }
    await harness.shutdown()
  }

  @Test("A bot's approval belongs to the run that started it, not the watch")
  func botApprovalIsNotRelayedByTheWatch() async throws {
    let harness = try await TelegramQueueHarness.make(updates: #"{"ok":true,"result":[]}"#)
    defer { harness.tearDown() }
    harness.connector.setApprovalsFromTelegram(true)
    let permission = Task {
      try? await harness.services.supervisor.requestPermission(
        agentID: harness.node, toolName: "file.write", detail: "touch notes.md",
        timeout: .seconds(4))
    }
    try await Task.sleep(for: .seconds(4))
    // The follow loop answers bot approvals in the chat that started the run; the watch stays
    // out of it so the phone never sees the same request twice.
    #expect(!harness.api.sentMessages.contains { $0.contains("asks for approval:") })
    _ = await permission.value
    await harness.shutdown()
  }
}

@MainActor
extension TelegramQueueHarness {
  /// A plain shell session with no bot profile, so it is not in the bots' roster.
  fileprivate func sessionNode() async throws -> UUID {
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    services.store.dispatch(
      .setAgentDefinition(
        id: node,
        definition: AgentDefinition(
          provider: .shell, workingDirectory: root.path, launchCommand: "/bin/sh",
          permissionMode: "workspaceWrite", resumeSessionID: nil, profileID: nil)))
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c", "printf 'OTTO_STATUS:IDLE\\r\\n'; while IFS= read -r line; do sleep 0.05; done",
        ],
        environment: ["NO_COLOR": "1"], workingDirectory: root.path), id: node)
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline,
      try await services.supervisor.snapshot(agentID: node).state != .idle
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    return node
  }
}

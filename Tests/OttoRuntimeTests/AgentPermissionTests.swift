import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("One-shot permission approvals")
struct AgentPermissionTests {
  @Test("Expired browser approvals clear the card and cannot be approved later")
  func browserApprovalExpires() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(100))
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    await #expect(throws: RuntimeError.permissionExpired) { try await decision.value }
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    #expect(
      try await supervisor.snapshot(agentID: id).transcript.last?.text.contains("expired") == true)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id, requestID: pending.requestID, nonce: pending.nonce, approved: true)
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Expiry of a queued request leaves the first approval intact")
  func queuedExpiryPreservesFirst() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let first = Task { try await supervisor.requestPermission(agentID: id, toolName: "Write") }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    let second = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(50))
    }
    await #expect(throws: RuntimeError.permissionExpired) { try await second.value }
    #expect(await supervisor.pendingPermission(agentID: id)?.requestID == pending.requestID)
    try await supervisor.resolvePermission(
      agentID: id, requestID: pending.requestID, nonce: pending.nonce, approved: true)
    #expect(try await first.value)
    try await supervisor.stop(agentID: id)
  }

  @Test("An approved request's timer cannot expire the next approval")
  func approvedTimerCannotExpireNext() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let first = Task {
      try await supervisor.requestPermission(
        agentID: id, toolName: "browser.click", timeout: .milliseconds(100))
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await first.value)
    let second = Task { try await supervisor.requestPermission(agentID: id, toolName: "Write") }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))
    try await Task.sleep(for: .milliseconds(150))
    #expect(await supervisor.pendingPermission(agentID: id)?.requestID == pending.requestID)
    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await second.value == false)
    try await supervisor.stop(agentID: id)
  }

  @Test("Claude one-shot launches route approvals through the otto permission tool")
  func oneShotLaunchWiresPermissionPromptTool() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "List the repository files.",
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp"
      ))
    let flagIndex = try #require(spec.arguments.firstIndex(of: "--permission-prompt-tool"))
    #expect(spec.arguments[flagIndex + 1] == AgentPermissionPrompt.mcpToolName)
    #expect(spec.arguments.contains("--mcp-config"))
    // The prompt stays the final positional argument, after every flag.
    #expect(spec.arguments.last == "List the repository files.")
  }

  @Test("The permission prompt flag requires the otto MCP bridge")
  func noPermissionPromptToolWithoutBridge() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        prompt: "List the repository files.",
        permissionMode: .workspaceWrite
      ))
    #expect(!spec.arguments.contains("--permission-prompt-tool"))
  }

  @Test("Interactive launches keep the native TUI permission prompt")
  func noPermissionPromptToolForInteractiveLaunches() async throws {
    let adapter = ClaudeCodeAdapter(executablePath: "/bin/echo")
    let spec = try await adapter.buildLaunchSpec(
      AgentLaunchRequest(
        workspacePath: FileManager.default.currentDirectoryPath,
        permissionMode: .workspaceWrite,
        ottoMCPExecutable: "/usr/local/bin/otto-mcp"
      ))
    #expect(spec.arguments.contains("--mcp-config"))
    #expect(!spec.arguments.contains("--permission-prompt-tool"))
  }

  @Test("Approval surfaces WAITING_PERMISSION and resumes the parked request")
  func approvalRoundTrip() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "git push")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let waiting = try await supervisor.snapshot(agentID: id)
    #expect(waiting.attentionReason == "Bash: git push")
    #expect(await supervisor.hasPendingPermission(agentID: id))

    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await decision.value == true)

    let resumed = try await supervisor.snapshot(agentID: id)
    #expect(resumed.state == .working)
    #expect(resumed.attentionReason == nil)
    #expect(resumed.transcript.last?.kind == .notice)
    #expect(resumed.transcript.last?.text == "Approved Bash: git push")
    #expect(await !supervisor.hasPendingPermission(agentID: id))
    try await supervisor.stop(agentID: id)
  }

  @Test("Denial resumes the parked request with a refusal")
  func denialRoundTrip() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Write")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    #expect(try await supervisor.snapshot(agentID: id).attentionReason == "Wants to use Write")

    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await decision.value == false)

    let resumed = try await supervisor.snapshot(agentID: id)
    #expect(resumed.state == .working)
    #expect(resumed.transcript.last?.text == "Denied Wants to use Write")
    try await supervisor.stop(agentID: id)
  }

  @Test("Remote approval validates the surfaced request ID and nonce exactly once")
  func nonceBoundApproval() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(
        agentID: id,
        toolName: "Bash",
        detail: "publish the release tag"
      )
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let pending = try #require(await supervisor.pendingPermission(agentID: id))

    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id,
        requestID: pending.requestID,
        nonce: "wrong-nonce",
        approved: true
      )
    }
    #expect(await supervisor.hasPendingPermission(agentID: id))

    try await supervisor.resolvePermission(
      agentID: id,
      requestID: pending.requestID,
      nonce: pending.nonce,
      approved: true
    )
    #expect(try await decision.value)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(
        agentID: id,
        requestID: pending.requestID,
        nonce: pending.nonce,
        approved: true
      )
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Queued requests resolve in arrival order and keep the surfaced reason current")
  func queuedRequestsResolveInOrder() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)

    let first = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "rm -rf tmp")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    let second = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "WebFetch")
    }
    try await waitFor(supervisor: supervisor) {
      let hasPending = await supervisor.hasPendingPermission(agentID: id)
      let state = (try? await supervisor.snapshot(agentID: id))?.state
      return hasPending && state == .waitingPermission
    }
    // The card resolves in arrival order, so the first request owns the surfaced reason.
    #expect(try await supervisor.snapshot(agentID: id).attentionReason == "Bash: rm -rf tmp")

    try await supervisor.resolvePermission(agentID: id, approved: true)
    #expect(try await first.value == true)
    let betweenRequests = try await supervisor.snapshot(agentID: id)
    #expect(betweenRequests.state == .waitingPermission)
    #expect(betweenRequests.attentionReason == "Wants to use WebFetch")

    try await supervisor.resolvePermission(agentID: id, approved: false)
    #expect(try await second.value == false)
    #expect(try await supervisor.snapshot(agentID: id).state == .working)
    try await supervisor.stop(agentID: id)
  }

  @Test("Process exit denies every parked permission request")
  func exitDeniesPendingRequests() async throws {
    let supervisor = AgentSupervisor()
    let id = try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        // Wait for explicit test input instead of racing a wall-clock sleep against the full
        // suite's parallel load. Reading one line then exiting still exercises natural process
        // teardown rather than supervisor.stop().
        arguments: ["-c", "read line"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .working,
      executionMode: .oneShotProvider
    )
    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "ls")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.sendInput(agentID: id, text: "exit")
    #expect(try await decision.value == false)
    #expect(await !supervisor.hasPendingPermission(agentID: id))
  }

  @Test("Stopping an agent denies its parked permission request")
  func stopDeniesPendingRequests() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    let decision = Task {
      try await supervisor.requestPermission(agentID: id, toolName: "Bash", detail: "ls")
    }
    try await waitForPermissionState(.waitingPermission, id: id, supervisor: supervisor)
    try await supervisor.stop(agentID: id)
    #expect(try await decision.value == false)
  }

  @Test("Resolving without a parked request is an explicit error")
  func resolveWithoutPendingRequestThrows() async throws {
    let supervisor = AgentSupervisor()
    let id = try await spawnLongRunningOneShot(supervisor: supervisor)
    await #expect(throws: RuntimeError.noPendingPermission(id)) {
      try await supervisor.resolvePermission(agentID: id, approved: true)
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("Requests for unknown or exited agents are rejected")
  func requestForUnknownAgentThrows() async throws {
    let supervisor = AgentSupervisor()
    await #expect(throws: RuntimeError.self) {
      _ = try await supervisor.requestPermission(agentID: UUID(), toolName: "Bash")
    }
  }

  private func spawnLongRunningOneShot(supervisor: AgentSupervisor) async throws -> UUID {
    try await supervisor.spawn(
      provider: .claudeCode,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 20"],
        workingDirectory: FileManager.default.currentDirectoryPath
      ),
      parser: .claude(ClaudeOutputParser()),
      initialState: .working,
      executionMode: .oneShotProvider
    )
  }

  private func waitForPermissionState(
    _ expected: AgentLifecycleState,
    id: UUID,
    supervisor: AgentSupervisor
  ) async throws {
    try await waitFor(supervisor: supervisor) {
      (try? await supervisor.snapshot(agentID: id))?.state == expected
    }
  }

  private func waitFor(
    supervisor: AgentSupervisor,
    timeout: Duration = .seconds(10),
    _ condition: () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for permission state condition")
  }
}

import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Provider account launches")
struct ProviderAccountLaunchTests {
  @Test("Named accounts remove host credentials before applying their own")
  func inheritedCredentialsCannotOverrideAccount() {
    let account = AgentAccountLaunch(
      accountID: UUID(), accountName: "Personal",
      environment: ["CLAUDE_CONFIG_DIR": "/accounts/personal", "ANTHROPIC_API_KEY": "account-key"],
      inheritedEnvironmentPrefixesToRemove:
        ProviderAccountIsolation.descriptor(for: .claudeCode).credentialEnvironmentVariables)
    let spec = ProcessLaunchSpec(executable: "/bin/sh", workingDirectory: "/")
    let inherited = [
      "ANTHROPIC_API_KEY": "host-key", "ANTHROPIC_AUTH_TOKEN": "host-token",
      "CLAUDE_CODE_OAUTH_TOKEN": "host-oauth", "PATH": "/usr/bin",
    ]
    let resolved = AgentSupervisor.applyingAccount(spec, account: account)
      .resolvedEnvironment(inheriting: inherited)
    #expect(resolved["ANTHROPIC_API_KEY"] == "account-key")
    #expect(resolved["ANTHROPIC_AUTH_TOKEN"] == nil)
    #expect(resolved["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    #expect(resolved["CLAUDE_CONFIG_DIR"] == "/accounts/personal")
    #expect(resolved["PATH"] == "/usr/bin")
    #expect(
      AgentSupervisor.applyingAccount(spec, account: nil)
        .resolvedEnvironment(inheriting: inherited)["ANTHROPIC_AUTH_TOKEN"] == "host-token")
  }

  @Test("Account environment reaches the provider process and overrides adapter defaults")
  func accountEnvironmentReachesChild() async throws {
    let output = FileManager.default.temporaryDirectory.appending(path: "account-env-\(UUID())")
    defer { try? FileManager.default.removeItem(at: output) }
    let supervisor = AgentSupervisor()
    let accountID = UUID()
    await supervisor.setAccountProvider { _, provider in
      #expect(provider == .codex)
      return AgentAccountLaunch(
        accountID: accountID, accountName: "Personal",
        environment: ["CODEX_HOME": "/accounts/personal/codex"])
    }
    let id = try await supervisor.spawnOneShot(
      adapter: EnvironmentEchoAdapter(outputPath: output.path),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.temporaryDirectory.path, prompt: "hello"))
    try await waitUntilExited(id, supervisor)
    let written = try String(contentsOf: output, encoding: .utf8)
    #expect(written == "/accounts/personal/codex")
  }

  @Test("No account keeps the Mac's existing provider login untouched")
  func noAccountLeavesEnvironmentAlone() async throws {
    let output = FileManager.default.temporaryDirectory.appending(path: "account-env-\(UUID())")
    defer { try? FileManager.default.removeItem(at: output) }
    let supervisor = AgentSupervisor()
    await supervisor.setAccountProvider { _, _ in nil }
    let id = try await supervisor.spawnOneShot(
      adapter: EnvironmentEchoAdapter(outputPath: output.path),
      request: AgentLaunchRequest(
        workspacePath: FileManager.default.temporaryDirectory.path, prompt: "hello"))
    try await waitUntilExited(id, supervisor)
    #expect(try String(contentsOf: output, encoding: .utf8) == "adapter-default")
  }

  @Test("A provider session is not resumed on a different account")
  func resumeAcrossAccountsStartsFresh() async throws {
    let supervisor = AgentSupervisor()
    let capture = AccountRequestCapture()
    let work = UUID()
    let personal = UUID()
    let current = AccountSelection(work)
    await supervisor.setAccountProvider { _, _ in
      AgentAccountLaunch(accountID: await current.value, accountName: "fixture")
    }
    let adapter = AccountCapturingAdapter(capture: capture)
    let workspace = FileManager.default.temporaryDirectory.path
    let id = try await supervisor.spawnOneShot(
      adapter: adapter, request: AgentLaunchRequest(workspacePath: workspace, prompt: "one"))
    try await waitUntilExited(id, supervisor)

    _ = try await supervisor.resumeOneShot(
      adapter: adapter, request: AgentLaunchRequest(workspacePath: workspace, prompt: "two"),
      sessionID: "work-session", id: id)
    try await waitUntilExited(id, supervisor)
    #expect(await capture.latest()?.resumeSessionID == "work-session")
    #expect(await capture.latest()?.account?.accountID == work)

    await current.set(personal)
    _ = try await supervisor.resumeOneShot(
      adapter: adapter, request: AgentLaunchRequest(workspacePath: workspace, prompt: "three"),
      sessionID: "work-session", id: id)
    try await waitUntilExited(id, supervisor)
    #expect(await capture.latest()?.resumeSessionID == nil)
    #expect(await capture.latest()?.account?.accountID == personal)
  }

  @Test("A failing account resolution aborts the launch with its reason")
  func accountErrorsAbortLaunch() async throws {
    let supervisor = AgentSupervisor()
    await supervisor.setAccountProvider { _, _ in
      throw RuntimeError.launchFailed("Personal has no Cursor API key")
    }
    await #expect(throws: RuntimeError.self) {
      _ = try await supervisor.spawnOneShot(
        adapter: EnvironmentEchoAdapter(outputPath: "/dev/null"),
        request: AgentLaunchRequest(
          workspacePath: FileManager.default.temporaryDirectory.path, prompt: "hello"))
    }
  }

  @Test("Sessions are read back from the account's relocated provider home")
  func restoresSessionsFromAccountHome() throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "account-session-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let accountHome = base.appending(path: "accounts/personal/codex")
    let directory = accountHome.appending(path: "sessions/2026/09/29")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sessionID = "019fdb85-account-fixture"
    let lines = [
      #"{"type":"session_meta","payload":{"id":"019fdb85-account-fixture","cwd":"/work"}}"#,
      #"{"type":"event_msg","payload":{"type":"user_message","message":"draft it"}}"#,
      #"{"type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","message":"Drafted."}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8).write(
      to: directory.appending(path: "rollout-2026-09-29T10-00-00-\(sessionID).jsonl"))
    let defaultHome = base.appending(path: "home")

    let missing = ProviderSessionStore.restore(
      provider: .codex, workingDirectory: "/work", sessionID: sessionID, home: defaultHome)
    #expect(missing.turns.isEmpty)
    let restored = ProviderSessionStore.restore(
      provider: .codex, workingDirectory: "/work", sessionID: sessionID, home: defaultHome,
      providerHome: accountHome)
    #expect(restored.turns.map(\.text) == ["draft it", "Drafted."])

    #expect(
      ProviderSessionStore.claudeProjectDirectory(
        workingDirectory: "/work", home: defaultHome, providerHome: accountHome
      ).path == accountHome.appending(path: "projects/-work").path)
  }

  @Test("Model catalogs are read with the account's own home and environment")
  func modelCatalogsFollowTheAccount() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "account-models-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    let personalHome = base.appending(path: "accounts/personal/codex")
    try FileManager.default.createDirectory(at: personalHome, withIntermediateDirectories: true)
    try Data(
      #"{"models":[{"slug":"gpt-personal","display_name":"GPT Personal"}]}"#.utf8
    ).write(to: personalHome.appending(path: "models_cache.json"))
    let workHome = base.appending(path: "home/.codex")
    try FileManager.default.createDirectory(at: workHome, withIntermediateDirectories: true)
    try Data(#"{"models":[{"slug":"gpt-work","display_name":"GPT Work"}]}"#.utf8)
      .write(to: workHome.appending(path: "models_cache.json"))

    let codex = CodexAdapter(homeDirectory: base.appending(path: "home").path)
    #expect(codex.discoverModels()?.map(\.id) == ["gpt-work"])
    #expect(
      codex.discoverModels(environment: ["CODEX_HOME": personalHome.path])?.map(\.id)
        == ["gpt-personal"])
    // A fresh account home has no cache yet: no models from another account leak in.
    #expect(
      codex.discoverModels(environment: ["CODEX_HOME": base.appending(path: "none").path]) == nil)

    #expect(codex.discoverModels(environment: ["OPENAI_API_KEY": "test-key"]) == nil)
    #expect(codex.discoverModels(environment: ["CODEX_API_KEY": "test-key"]) == nil)

    // HOME is an always-present harmless stand-in for an inherited credential here.
    let isolated = await ExecutableLocator.captureOutput(
      executable: "/bin/sh", arguments: ["-c", "printf '%s' \"${HOME-unset}\""],
      inheritedEnvironmentPrefixesToRemove: ["HOME"])
    #expect(isolated == "unset")

    let echoed = await ExecutableLocator.captureOutput(
      executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$CURSOR_API_KEY\""],
      environment: ["CURSOR_API_KEY": "personal-key"])
    #expect(echoed == "personal-key")
  }

  @Test("Every agent provider declares how accounts are isolated")
  func everyProviderHasIsolation() {
    for provider in AgentProvider.allCases where provider.supportsProviderAccounts {
      let isolation = ProviderAccountIsolation.descriptor(for: provider)
      if provider == .openAI {
        // The Otto harness isolates per backend key rather than by environment.
        #expect(isolation.homeVariable == nil && isolation.apiKeyVariable == nil)
      } else {
        #expect(isolation.supportsLogin || isolation.supportsAPIKey, "\(provider.rawValue)")
      }
    }
    #expect(
      ProviderAccountIsolation.descriptor(for: .claudeCode).homeVariable == "CLAUDE_CONFIG_DIR")
    #expect(ProviderAccountIsolation.descriptor(for: .codex).homeVariable == "CODEX_HOME")
    #expect(ProviderAccountIsolation.descriptor(for: .grok).homeVariable == "GROK_HOME")
    #expect(ProviderAccountIsolation.descriptor(for: .kimi).homeVariable == "KIMI_CODE_HOME")
    #expect(ProviderAccountIsolation.descriptor(for: .cursor).apiKeyVariable == "CURSOR_API_KEY")
    // Credentials must never be shared between accounts.
    for provider in AgentProvider.allCases {
      let shared = ProviderAccountIsolation.descriptor(for: provider).sharedEntries
      #expect(!shared.contains { $0.contains("auth") || $0.contains("credential") })
      #expect(!shared.contains(".claude.json"))
    }
  }
}

private func waitUntilExited(_ id: UUID, _ supervisor: AgentSupervisor) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if try await supervisor.snapshot(agentID: id).exitCode != nil { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("Agent did not exit")
}

private actor AccountSelection {
  var value: UUID
  init(_ value: UUID) { self.value = value }
  func set(_ next: UUID) { value = next }
}

private actor AccountRequestCapture {
  private var request: AgentLaunchRequest?
  func record(_ value: AgentLaunchRequest) { request = value }
  func latest() -> AgentLaunchRequest? { request }
}

private struct AccountCapturingAdapter: AgentAdapter {
  let provider = AgentProvider.codex
  let capture: AccountRequestCapture
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    await capture.record(request)
    return ProcessLaunchSpec(
      executable: "/bin/sh", arguments: ["-c", "exit 0"], workingDirectory: request.workspacePath)
  }
}

private struct EnvironmentEchoAdapter: AgentAdapter {
  let provider = AgentProvider.codex
  let outputPath: String
  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }
  func availableModels() async -> [AgentModel] { [] }
  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", "printf '%s' \"$CODEX_HOME\" > \"$1\"", "sh", outputPath],
      environment: ["CODEX_HOME": "adapter-default"],
      workingDirectory: request.workspacePath)
  }
}

import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoApplicationTools
@testable import OttoServices

@MainActor
@Suite("Provider accounts")
struct ProviderAccountStoreTests {
  private struct Fixture {
    let root: URL
    let home: URL
    let secrets: InMemorySecretStore
    @MainActor func store() -> ProviderAccountStore {
      ProviderAccountStore(rootDirectory: root, userHome: home, secrets: secrets)
    }
    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: home)
    }
  }

  private func fixture() -> Fixture {
    let base = FileManager.default.temporaryDirectory.appending(path: "accounts-\(UUID())")
    return Fixture(
      root: base.appending(path: "otto"), home: base.appending(path: "home"),
      secrets: InMemorySecretStore())
  }

  @Test func accountsPersistResolveAndNeverChangeTheDefaultImplicitly() throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    let work = try store.create(name: "Work · HubSpot")
    let personal = try store.create(name: "Personal")
    #expect(work.color != personal.color)
    #expect(store.defaultAccountID == nil)
    #expect(throws: ProviderAccountStore.AccountError.duplicateName("personal")) {
      try store.create(name: "personal")
    }
    try store.setDefault(work.id)

    let restored = fixture.store()
    #expect(restored.accounts.map(\.name) == ["Work · HubSpot", "Personal"])
    #expect(restored.defaultAccountID == work.id)
    #expect(try restored.resolve("work").id == work.id)
    #expect(try restored.resolve(personal.id.uuidString).id == personal.id)
    #expect(throws: (any Error).self) { try restored.resolve("nobody") }
  }

  @Test func accountResolutionPrefersAgentThenProjectThenGlobalDefault() throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    let work = try store.create(name: "Work")
    let personal = try store.create(name: "Personal")
    #expect(store.effectiveAccountID(agentAccountID: nil, projectDefaultAccountID: nil) == nil)
    try store.setDefault(personal.id)
    #expect(
      store.effectiveAccountID(agentAccountID: nil, projectDefaultAccountID: nil) == personal.id)
    #expect(
      store.effectiveAccountID(agentAccountID: nil, projectDefaultAccountID: work.id) == work.id)
    #expect(
      store.effectiveAccountID(agentAccountID: personal.id, projectDefaultAccountID: work.id)
        == personal.id)
    // A deleted account is skipped rather than breaking the launch.
    #expect(
      store.effectiveAccountID(agentAccountID: UUID(), projectDefaultAccountID: work.id) == work.id)
  }

  @Test func loginAccountsGetAPrivateHomeThatSharesConfigurationButNotCredentials() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let claudeHome = fixture.home.appending(path: ".claude")
    try FileManager.default.createDirectory(
      at: claudeHome.appending(path: "skills"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: claudeHome.appending(path: "settings.json"))
    try Data("secret".utf8).write(to: claudeHome.appending(path: ".credentials.json"))
    let store = fixture.store()
    let personal = try store.create(name: "Personal")

    let launch = try #require(
      try await store.launchContext(accountID: personal.id, provider: .claudeCode))
    let configDir = try #require(launch.environment["CLAUDE_CONFIG_DIR"])
    #expect(configDir == store.providerHome(accountID: personal.id, provider: .claudeCode).path)
    let linkedSettings = try FileManager.default.destinationOfSymbolicLink(
      atPath: configDir + "/settings.json")
    #expect(linkedSettings == claudeHome.appending(path: "settings.json").path)
    #expect(FileManager.default.fileExists(atPath: configDir + "/skills"))
    #expect(!FileManager.default.fileExists(atPath: configDir + "/.credentials.json"))
    #expect(!store.hasProviderLogin(accountID: personal.id, provider: .claudeCode))
    // Claude writes this file even when signed out; only a recorded OAuth account counts.
    try Data("{\"projects\":{}}".utf8).write(to: URL(fileURLWithPath: configDir + "/.claude.json"))
    #expect(!store.hasProviderLogin(accountID: personal.id, provider: .claudeCode))
    try Data("{\"oauthAccount\":{\"emailAddress\":\"me@example.com\"}}".utf8)
      .write(to: URL(fileURLWithPath: configDir + "/.claude.json"))
    #expect(store.hasProviderLogin(accountID: personal.id, provider: .claudeCode))

    // Re-preparing keeps an account-specific override instead of relinking it.
    try FileManager.default.removeItem(atPath: configDir + "/settings.json")
    try Data("{\"model\":\"personal\"}".utf8).write(
      to: URL(fileURLWithPath: configDir + "/settings.json"))
    _ = try await store.launchContext(accountID: personal.id, provider: .claudeCode)
    #expect(
      (try? FileManager.default.destinationOfSymbolicLink(atPath: configDir + "/settings.json"))
        == nil)
  }

  @Test func unsharedAccountsLinkNothing() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let codexHome = fixture.home.appending(path: ".codex")
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try Data("model = 'x'".utf8).write(to: codexHome.appending(path: "config.toml"))
    let store = fixture.store()
    var work = try store.create(name: "Work")
    work.sharesProviderConfiguration = false
    try store.update(work)
    let launch = try #require(try await store.launchContext(accountID: work.id, provider: .codex))
    let home = try #require(launch.environment["CODEX_HOME"])
    #expect(!FileManager.default.fileExists(atPath: home + "/config.toml"))
  }

  @Test func apiKeyAccountsRequireAStoredKeyAndPassItToTheProvider() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    var work = try store.create(name: "Work")
    work.credentialModes[.grok] = .apiKey
    try store.update(work)
    await #expect(throws: ProviderAccountStore.AccountError.self) {
      _ = try await store.launchContext(accountID: work.id, provider: .grok)
    }
    try await store.setAPIKey("xai-work", accountID: work.id, provider: .grok)
    #expect(await store.hasAPIKey(accountID: work.id, provider: .grok))
    let launch = try await store.launchContext(accountID: work.id, provider: .grok)
    #expect(launch?.environment == ["XAI_API_KEY": "xai-work"])

    // Cursor has no relocatable login home, so an account always isolates it by API key.
    #expect(work.credentialMode(for: .cursor) == .apiKey)
    try await store.setAPIKey("cursor-work", accountID: work.id, provider: .cursor)
    let cursor = try await store.launchContext(accountID: work.id, provider: .cursor)
    #expect(cursor?.environment == ["CURSOR_API_KEY": "cursor-work"])
  }

  @Test func harnessAgentsReceiveTheAccountsBackendKeys() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    let personal = try store.create(name: "Personal")
    try await store.setHarnessKey(
      "sk-personal", accountID: personal.id, credentialKey: "openai.api-key")
    let launch = try #require(
      try await store.launchContext(accountID: personal.id, provider: .openAI))
    #expect(launch.environment.isEmpty)
    #expect(launch.harnessCredentials == ["openai.api-key": "sk-personal"])
    #expect(try await store.launchContext(accountID: nil, provider: .openAI) == nil)
    #expect(try await store.launchContext(accountID: personal.id, provider: .shell) == nil)
  }

  @Test func deletingAnAccountRemovesItsKeysAndLogins() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    let work = try store.create(name: "Work")
    try store.setDefault(work.id)
    try await store.setAPIKey("key", accountID: work.id, provider: .cursor)
    try store.prepareProviderHome(accountID: work.id, provider: .codex)
    let directory = store.accountDirectory(work.id)
    #expect(FileManager.default.fileExists(atPath: directory.path))
    try await store.delete(work.id)
    #expect(store.accounts.isEmpty)
    #expect(store.defaultAccountID == nil)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(
      try await fixture.secrets.value(for: work.apiKeyCredentialKey(for: .cursor)) == nil)
  }

  @Test func loginCommandScopesTheHomeToTheLoginProcessAndQuotesPaths() {
    let command = ApplicationServices.loginCommand(
      environment: ["CLAUDE_CONFIG_DIR": "/Users/me/Library/Application Support/Muse/it's"],
      executable: "/Users/me/.local/bin/claude", arguments: ["auth", "login"])
    #expect(
      command
        == "env CLAUDE_CONFIG_DIR='/Users/me/Library/Application Support/Muse/it'\\''s' '/Users/me/.local/bin/claude' 'auth' 'login'"
    )
    let script = ApplicationServices.loginScript(
      provider: "Claude Code", account: "Personal", command: command)
    #expect(script.hasPrefix("#!/bin/zsh\n"))
    #expect(script.contains(command))
    #expect(script.contains("'Signing in to Claude Code for the Personal account in Otto.'"))
  }

  @Test func loginsToTheMacsOwnAccountAreFlaggedRatherThanCountedAsSeparate() throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    try FileManager.default.createDirectory(at: fixture.home, withIntermediateDirectories: true)
    func claudeState(_ email: String, org: String) -> Data {
      Data(
        """
        {"oauthAccount":{"emailAddress":"\(email)","accountUuid":"user-\(email.lowercased())",
        "organizationUuid":"\(org)","organizationName":"Org \(org)"}}
        """.utf8)
    }
    try claudeState("work@example.com", org: "acme").write(
      to: fixture.home.appending(path: ".claude.json"))
    let store = fixture.store()
    let personal = try store.create(name: "Personal")
    let data = try store.prepareProviderHome(accountID: personal.id, provider: .claudeCode)
    #expect(store.loginStatus(accountID: personal.id, provider: .claudeCode) == .signedOut)

    // The browser was still signed in to work, so the "Personal" login is the work account.
    try claudeState("WORK@example.com", org: "acme").write(to: data.appending(path: ".claude.json"))
    let status = store.loginStatus(accountID: personal.id, provider: .claudeCode)
    guard case .sameAsMac(let same) = status else {
      Issue.record("expected sameAsMac, got \(status)")
      return
    }
    #expect(same.label == "WORK@example.com · Org acme")
    #expect(!store.hasDistinctProviderLogin(accountID: personal.id, provider: .claudeCode))
    #expect(store.hasProviderLogin(accountID: personal.id, provider: .claudeCode))

    // Same email in a different organization is a different seat.
    try claudeState("work@example.com", org: "home").write(to: data.appending(path: ".claude.json"))
    #expect(store.hasDistinctProviderLogin(accountID: personal.id, provider: .claudeCode))

    try claudeState("me@example.com", org: "home").write(to: data.appending(path: ".claude.json"))
    #expect(
      store.loginStatus(accountID: personal.id, provider: .claudeCode)
        == .signedIn(
          ProviderLoginIdentity(
            email: "me@example.com", organization: "Org home", accountKey: "user-me@example.com",
            organizationKey: "home")))
  }

  @Test func codexIdentityComesFromTheRecordedIDToken() throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    func auth(_ email: String, user: String) throws -> Data {
      let claims = try JSONSerialization.data(withJSONObject: [
        "email": email,
        "https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": "ws"],
      ])
      let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      return try JSONSerialization.data(withJSONObject: [
        "tokens": ["id_token": "e30.\(payload).sig", "access_token": "never-read"]
      ])
    }
    let macCodex = fixture.home.appending(path: ".codex")
    try FileManager.default.createDirectory(at: macCodex, withIntermediateDirectories: true)
    try auth("mac@example.com", user: "u1").write(to: macCodex.appending(path: "auth.json"))
    let store = fixture.store()
    let personal = try store.create(name: "Personal")
    let home = try store.prepareProviderHome(accountID: personal.id, provider: .codex)
    try auth("mac@example.com", user: "u1").write(to: home.appending(path: "auth.json"))
    #expect(
      store.loginStatus(accountID: personal.id, provider: .codex)
        == .sameAsMac(
          ProviderLoginIdentity(email: "mac@example.com", accountKey: "u1", organizationKey: "ws")))
    try auth("me@example.com", user: "u2").write(to: home.appending(path: "auth.json"))
    #expect(store.hasDistinctProviderLogin(accountID: personal.id, provider: .codex))
    #expect(
      store.loginIdentity(accountID: personal.id, provider: .codex)?.label == "me@example.com")
  }

  @Test func codeLoginFallsBackToBrowserLoginAndWarnsAboutTheExistingAccount() async {
    let guidance = ApplicationServices.loginGuidance(
      provider: "Codex", account: "Personal", macLogin: "mac@example.com", usesCodeLogin: true)
    #expect(guidance.contains("already uses Codex as mac@example.com"))
    #expect(guidance.contains("private browser window"))
    let script = ApplicationServices.loginScript(
      provider: "Codex", account: "Personal", command: "codex login --device-auth",
      fallbackCommand: "codex login", guidance: guidance)
    // Run it with a failing code login and a working fallback.
    let ran = ApplicationServices.loginScript(
      provider: "Codex", account: "Personal", command: "false", fallbackCommand: "true",
      guidance: guidance
    ).replacingOccurrences(of: "\nclear\n", with: "\n")
    let output = await ExecutableLocator.captureOutput(
      executable: "/bin/zsh", arguments: ["-c", ran], environment: [:])
    #expect(output?.contains("Trying the standard browser sign-in") == true)
    #expect(output?.contains("Done. Return to Otto") == true)
    let device = try! #require(script.range(of: "codex login --device-auth"))
    let fallback = try! #require(script.range(of: "\n  codex login\n"))
    #expect(device.upperBound < fallback.lowerBound)
    #expect(script.contains("if (( login_status != 0 )); then"))
    #expect(
      ProviderAccountIsolation.descriptor(for: .codex).codeLoginArguments
        == ["login", "--device-auth"])
  }

  @Test func isolatedModesScrubHostCredentialsButSystemDefaultDoesNot() async throws {
    let fixture = fixture()
    defer { fixture.cleanUp() }
    let store = fixture.store()
    var account = try store.create(name: "Personal")
    let login = try #require(
      try await store.launchContext(accountID: account.id, provider: .claudeCode))
    #expect(login.inheritedEnvironmentPrefixesToRemove.contains("CLAUDE_CODE_OAUTH_TOKEN"))
    account.credentialModes[.claudeCode] = .systemDefault
    try store.update(account)
    let system = try #require(
      try await store.launchContext(accountID: account.id, provider: .claudeCode))
    #expect(system.inheritedEnvironmentPrefixesToRemove.isEmpty)
    #expect(system.environment.isEmpty)
  }

  @Test func loginCommandRemovesHostAuthenticationBeforeApplyingAccountValues() async {
    let command = ApplicationServices.loginCommand(
      environment: ["CLAUDE_CONFIG_DIR": "/account home"],
      executable: "/bin/sh",
      arguments: [
        "-c",
        #"printf '%s|%s|%s' "$CLAUDE_CONFIG_DIR" "${ANTHROPIC_API_KEY-unset}" "${CLAUDE_CODE_OAUTH_TOKEN-unset}""#,
      ],
      removingEnvironmentVariables: ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"])
    let output = await ExecutableLocator.captureOutput(
      executable: "/bin/zsh", arguments: ["-c", command],
      environment: ["ANTHROPIC_API_KEY": "host-key", "CLAUDE_CODE_OAUTH_TOKEN": "host-token"])
    #expect(output == "/account home|unset|unset")
  }

  @Test func projectsRememberTheirDefaultAccount() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "projects-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let projects = ConversationProjectStore(workspacePath: root.path)
    let project = try projects.create(name: "Trigify GTM")
    let account = UUID()
    try projects.setDefaultAccount(projectID: project.id, accountID: account)
    let channel = UUID()
    try projects.select(channelID: channel, projectID: project.id)
    let restored = ConversationProjectStore(workspacePath: root.path)
    #expect(restored.project(channelID: channel)?.defaultAccountID == account)
  }
}

@MainActor
@Suite("Provider usage-limit handling")
struct ProviderUsageLimitHandlingTests {
  @Test func limitedRunOffersTheProjectFallbackFirstAndIgnoresOrdinaryAnswers() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "limits-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let accounts = ProviderAccountStore(
      rootDirectory: base.appending(path: "otto"), userHome: base.appending(path: "home"),
      secrets: InMemorySecretStore())
    let work = try accounts.create(name: "Work")
    let personal = try accounts.create(name: "Personal")
    let spare = try accounts.create(name: "Spare")

    let canvas = OttoCanvas(name: "Main")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let nodeID = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: .claudeCode, workingDirectory: base.path, launchCommand: "claude",
          permissionMode: "workspaceWrite", accountID: work.id)))
    let services = ApplicationServices(
      store: store, providerAccounts: accounts, workspacePath: base.path)
    let project = try services.conversationProjects.create(name: "Trigify GTM")
    try services.conversationProjects.select(channelID: nodeID, projectID: project.id)
    try services.conversationProjects.setUsageLimitPolicy(
      projectID: project.id, policy: .ask, fallbackAccountID: spare.id)

    await services.handleUsageLimit(
      AgentRuntimeSnapshot(
        id: nodeID, runID: UUID(), provider: .claudeCode, state: .done, confidence: 1,
        result: String(
          repeating: "A long answer that explains how rate limit exceeded errors work. ", count: 10),
        lastPrompt: "explain rate limits"))
    #expect(services.usageLimits.notices[nodeID] == nil)

    await services.handleUsageLimit(
      AgentRuntimeSnapshot(
        id: nodeID, runID: UUID(), provider: .claudeCode, state: .failed, confidence: 0,
        result: "You've hit your limit · resets 2pm", lastPrompt: "draft the Q3 summary"))
    let notice = try #require(services.usageLimits.notices[nodeID])
    #expect(notice.accountName == "Work")
    #expect(notice.prompt == "draft the Q3 summary")
    #expect(notice.alternatives.map(\.id) == [spare.id, personal.id])
    #expect(notice.limit.resetsAt != nil)
    #expect(notice.projectName == "Trigify GTM")

    services.dismissUsageLimit(nodeID: nodeID)
    #expect(services.usageLimits.notices[nodeID] == nil)
  }
}

@MainActor
@Suite("Provider account boundaries")
struct ProviderAccountBoundaryTests {
  @Test func crossAccountHandoffsNeedApprovalAndAgentsCannotReassignAccounts() async throws {
    let base = FileManager.default.temporaryDirectory.appending(path: "boundary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let accounts = ProviderAccountStore(
      rootDirectory: base.appending(path: "otto"), userHome: base.appending(path: "home"),
      secrets: InMemorySecretStore())
    let work = try accounts.create(name: "Work")
    let personal = try accounts.create(name: "Personal")
    let canvas = OttoCanvas(name: "Main")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    func agent(_ accountID: UUID?) throws -> UUID {
      let id = try #require(
        store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
      store.dispatch(
        .setAgentDefinition(
          id: id,
          definition: AgentDefinition(
            provider: .codex, workingDirectory: base.path, launchCommand: "codex",
            permissionMode: "workspaceWrite", accountID: accountID)))
      return id
    }
    let researcher = try agent(work.id)
    let coder = try agent(personal.id)
    let reviewer = try agent(work.id)
    let services = ApplicationServices(
      store: store, providerAccounts: accounts, workspacePath: base.path)

    #expect(
      services.accountCrossing(source: researcher, targetNode: reviewer, targetAccountID: nil)
        == nil)
    #expect(
      services.accountCrossing(source: researcher, targetNode: coder, targetAccountID: nil)
        == AgentAccountCrossing(sourceAccount: "Work", targetAccount: "Personal"))
    #expect(
      services.accountCrossing(source: researcher, targetNode: nil, targetAccountID: personal.id)
        != nil)

    let boundary: AgentAccountBoundary = { source, target, account in
      await services.accountCrossing(source: source, targetNode: target, targetAccountID: account)
    }
    let agentContext = ToolContext(
      actorID: "agent", scopes: Set(ToolScope.allCases), source: .agent, sourceNodeID: researcher)
    await #expect(throws: ToolRegistryError.self) {
      _ = try await enforceAccountBoundary(
        boundary, context: agentContext, targetNode: coder, targetAccountID: nil, allowed: nil)
    }
    let approved = try await enforceAccountBoundary(
      boundary, context: agentContext, targetNode: coder, targetAccountID: nil, allowed: true)
    #expect(approved?.targetAccount == "Personal")
    let userContext = ToolContext(
      actorID: "otto-ui", scopes: Set(ToolScope.allCases), source: .userInterface,
      sourceNodeID: researcher)
    #expect(
      try await enforceAccountBoundary(
        boundary, context: userContext, targetNode: coder, targetAccountID: nil, allowed: nil)
        == nil)

    await #expect(throws: ToolRegistryError.self) {
      _ = try await services.providerAccountAction(
        ProviderAccountInput(action: "assign", account: "Personal", agentID: reviewer),
        context: agentContext)
    }
    let listed = try await services.providerAccountAction(
      ProviderAccountInput(action: "list"), context: agentContext)
    #expect(listed.accounts.map(\.name) == ["Work", "Personal"])
    #expect(listed.effectiveAccount?.name == "Work")
    let assigned = try await services.providerAccountAction(
      ProviderAccountInput(action: "assign", account: "personal", agentID: reviewer),
      context: userContext)
    #expect(assigned.effectiveAccount?.id == personal.id)
    #expect(
      store.activeCanvas.nodes.first { $0.id == reviewer }?.agentDefinition?.accountID
        == personal.id)
  }
}

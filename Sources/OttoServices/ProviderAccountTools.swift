import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools

public struct ProviderAccountInput: Codable, Sendable {
  /// list, assign, or set_project_default
  public var action: String
  /// Account name or ID. Use "default" to clear an assignment and inherit the fallback chain.
  public var account: String?
  /// Agent node to assign; agents default to themselves.
  public var agentID: UUID?
  public var projectID: UUID?
  public var projectName: String?

  public init(
    action: String, account: String? = nil, agentID: UUID? = nil, projectID: UUID? = nil,
    projectName: String? = nil
  ) {
    self.action = action
    self.account = account
    self.agentID = agentID
    self.projectID = projectID
    self.projectName = projectName
  }
}

public struct ProviderAccountSummary: Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var color: String
  public var isDefault: Bool
}

public struct ProviderAccountOutput: Codable, Sendable {
  public var accounts: [ProviderAccountSummary]
  /// The account the addressed agent will use on its next run, after fallbacks.
  public var effectiveAccount: ProviderAccountSummary?
  public var note: String
}

public struct ProviderAccountTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "account.manage",
    description:
      "Lists the user's provider accounts (for example a work subscription and a personal one) and chooses which one an agent runs on. Actions: list; assign (account name/ID or \"default\", optional agentID); set_project_default (projectID or projectName, account or \"default\"). Accounts cover every provider — Claude Code, Codex, Grok, Kimi, Cursor, OpenCode, Hermes and the Otto harness. Agents may list accounts; only the user (interface or voice) can assign or change defaults.",
    inputSchema: .objectSchema(
      properties: [
        "action": .stringSchema(description: "list, assign, or set_project_default"),
        "account": .stringSchema(
          description: "Account name or ID; \"default\" clears the choice to inherit defaults"),
        "agentID": .stringSchema(description: "Agent node to assign; defaults to the caller"),
        "projectID": .stringSchema(description: "Project for set_project_default"),
        "projectName": .stringSchema(description: "Exact project name for set_project_default"),
      ], required: ["action"]),
    outputSchema: .objectSchema(),
    requiredScopes: [.agentControl], riskLevel: .reversible)

  private let handler:
    @Sendable (ProviderAccountInput, ToolContext) async throws -> ProviderAccountOutput

  public init(
    handler:
      @escaping @Sendable (ProviderAccountInput, ToolContext) async throws -> ProviderAccountOutput
  ) { self.handler = handler }

  public func call(_ input: ProviderAccountInput, context: ToolContext) async throws
    -> ProviderAccountOutput
  { try await handler(input, context) }
}

extension ApplicationServices {
  func providerAccountAction(_ input: ProviderAccountInput, context: ToolContext) async throws
    -> ProviderAccountOutput
  {
    let targetAgent = input.agentID ?? context.sourceNodeID
    // Which subscription pays for work — and where work data goes — is the user's decision.
    if input.action != "list", context.source == .agent || context.source == .automation {
      throw ToolRegistryError.invalidInput(
        "Only the user can change accounts. Ask them to pick one from the account chip under the composer or in Settings → Accounts."
      )
    }
    var note = ""
    switch input.action {
    case "list":
      note =
        providerAccounts.accounts.isEmpty
        ? "No accounts yet. Agents use the Mac's existing provider logins; add accounts in Settings → Accounts."
        : "Agents without an account use their project's default, then the global default."
    case "assign":
      guard let targetAgent else {
        throw ToolRegistryError.invalidInput("assign needs an agentID")
      }
      let accountID = try accountReference(input.account)
      try await setAccount(accountID, forAgent: targetAgent)
      note =
        accountID == nil
        ? "The agent now inherits its project or global default account."
        : "The agent's next run uses this account and starts a fresh provider session."
    case "set_project_default":
      let project: ConversationProject
      if let id = input.projectID,
        let match = conversationProjects.projects.first(where: { $0.id == id })
      {
        project = match
      } else {
        project = try conversationProjects.resolve(name: input.projectName ?? "")
      }
      try conversationProjects.setDefaultAccount(
        projectID: project.id, accountID: try accountReference(input.account))
      note = "New work in \(project.name) runs on this account unless an agent overrides it."
    default:
      throw ToolRegistryError.invalidInput("Expected list, assign or set_project_default.")
    }
    let effective = targetAgent.flatMap { effectiveAccountID(nodeID: $0) }
    return ProviderAccountOutput(
      accounts: providerAccounts.accounts.map(summary),
      effectiveAccount: providerAccounts.account(id: effective).map(summary),
      note: note)
  }

  /// Chooses the account an agent runs on. Nil inherits the project and global defaults.
  /// Provider sessions are per account, so the saved resume session is cleared and a live
  /// interactive terminal is relaunched on the new account.
  public func setAccount(_ accountID: UUID?, forAgent nodeID: UUID) async throws {
    if let accountID, providerAccounts.account(id: accountID) == nil {
      throw ProviderAccountStore.AccountError.unknownAccount(accountID.uuidString)
    }
    guard
      var definition = store.snapshot.canvases.lazy.flatMap(\.nodes)
        .first(where: { $0.id == nodeID })?.agentDefinition
    else {
      throw ToolRegistryError.invalidInput("That agent has no launch configuration")
    }
    guard definition.provider.supportsProviderAccounts else {
      throw ToolRegistryError.invalidInput("Terminals do not use provider accounts")
    }
    let previous = effectiveAccountID(nodeID: nodeID)
    definition.accountID = accountID
    let projectDefault = projectChannel(nodeID: nodeID)
      .flatMap { conversationProjects.project(channelID: $0) }?.defaultAccountID
    let next = providerAccounts.effectiveAccountID(
      agentAccountID: accountID, projectDefaultAccountID: projectDefault)
    let accountChanged = next != previous
    if accountChanged { definition.resumeSessionID = nil }
    store.dispatch(
      .setAgentDefinition(id: nodeID, definition: definition),
      targetCanvasID: store.canvasID(containing: nodeID))
    guard accountChanged else { return }
    usageLimits.clear(nodeID)
    await prepareAccountHandover(
      nodeID: nodeID,
      from: providerAccounts.account(id: previous)?.name ?? "this Mac's login",
      to: providerAccounts.account(id: next)?.name ?? "this Mac's login")
    if let snapshot = fleet[nodeID], snapshot.exitCode == nil,
      snapshot.executionMode == .interactiveProvider
    {
      try await restart(agentID: nodeID)
    }
  }

  /// Opens the provider's own login in Terminal.app, pointed at the account's private provider
  /// home. Terminal is used rather than a canvas node so the login is always in front of the
  /// user, whichever Otto surface is showing. Otto never sees the resulting credentials.
  public func startProviderLogin(accountID: UUID, provider: AgentProvider) async throws {
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    guard isolation.supportsLogin else {
      throw ProviderAccountStore.AccountError.loginUnsupported(provider.rawValue)
    }
    guard let account = providerAccounts.account(id: accountID) else {
      throw ProviderAccountStore.AccountError.unknownAccount(accountID.uuidString)
    }
    guard let adapter = isolatedTeamAdapter(for: provider),
      case .installed(let executable, _) = await adapter.detectInstallation()
    else {
      throw ToolRegistryError.invalidInput("\(provider.rawValue) is not installed on this Mac")
    }
    let environment = try providerAccounts.loginEnvironment(
      accountID: accountID, provider: provider)
    let command = { (arguments: [String]) in
      Self.loginCommand(
        environment: environment, executable: executable, arguments: arguments,
        removingEnvironmentVariables: isolation.credentialEnvironmentVariables)
    }
    let codeLogin = isolation.codeLoginArguments.map(command)
    let script = Self.loginScript(
      provider: provider.rawValue, account: account.name,
      command: codeLogin ?? command(isolation.loginArguments),
      fallbackCommand: codeLogin == nil ? nil : command(isolation.loginArguments),
      guidance: Self.loginGuidance(
        provider: provider.rawValue, account: account.name,
        macLogin: providerAccounts.macLoginIdentity(provider: provider)?.label,
        usesCodeLogin: codeLogin != nil))
    // The script holds only paths and the login command, never credentials.
    let file = providerAccounts.accountDirectory(accountID)
      .appending(path: "\(provider.accountCredentialName)-login.command")
    try Data(script.utf8).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-a", "Terminal", file.path]
    try opener.run()
    opener.waitUntilExit()
    guard opener.terminationStatus == 0 else {
      throw ToolRegistryError.invalidInput("Terminal could not be opened for the login")
    }
  }

  nonisolated static func loginCommand(
    environment: [String: String], executable: String, arguments: [String],
    removingEnvironmentVariables: [String] = []
  ) -> String {
    let assignments = environment.keys.sorted().map { key in
      "\(key)=\(shellQuoted(environment[key] ?? ""))"
    }
    // Unset host credentials before restoring explicit account values.
    let removals = removingEnvironmentVariables.flatMap { ["-u", shellQuoted($0)] }
    return
      (["env"] + removals + assignments + [shellQuoted(executable)] + arguments.map(shellQuoted))
      .joined(separator: " ")
  }

  /// Browsers silently approve the account they are already signed in to, which would give
  /// the new account the Mac's existing login. Point the user at a private window instead.
  nonisolated static func loginGuidance(
    provider: String, account: String, macLogin: String?, usesCodeLogin: Bool
  ) -> String {
    let existing =
      macLogin.map { "This Mac already uses \(provider) as \($0). " }
      ?? "Your browser may already be signed in to \(provider). "
    let action =
      if provider == AgentProvider.pi.rawValue {
        "Pi opens below. Type /login, pick the model provider, and sign in to the account you want for \(account); if the browser is already signed in to another account, copy the link into a private window (Shift-Command-N) instead. Quit Pi with /quit when it says you are signed in."
      } else if usesCodeLogin {
        "Open the link below in a private browser window (Shift-Command-N), sign in to the account you want for \(account), then enter the code."
      } else {
        "If your browser opens already signed in to that account, close the tab and open the link printed below in a private browser window (Shift-Command-N) instead, then sign in to the account you want for \(account)."
      }
    return existing + action
  }

  nonisolated static func loginScript(
    provider: String, account: String, command: String, fallbackCommand: String? = nil,
    guidance: String? = nil
  ) -> String {
    let guidanceLines = guidance.map { "print -r -- \(shellQuoted($0))\nprint\n" } ?? ""
    let fallback =
      fallbackCommand.map {
        """
        if (( login_status != 0 )); then
          print
          print -r -- "Code sign-in didn't complete. Trying the standard browser sign-in instead."
          print
          \($0)
          login_status=$?
        fi

        """
      } ?? ""
    return """
      #!/bin/zsh
      clear
      print -r -- \(shellQuoted("Signing in to \(provider) for the \(account) account in Otto."))
      print
      \(guidanceLines)\(command)
      login_status=$?
      \(fallback)print
      if (( login_status == 0 )); then
        print -r -- "Done. Return to Otto and check the account shows the email you expect. You can close this window."
      else
        print -r -- "The login exited with status $login_status. Close this window and try again from Otto."
      fi

      """
  }

  private nonisolated static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Nil when both sides bill to the same account (including both on this Mac's login).
  func accountCrossing(source: UUID, targetNode: UUID?, targetAccountID: UUID?)
    -> AgentAccountCrossing?
  {
    let sourceAccount = effectiveAccountID(nodeID: source)
    let targetAccount = targetNode.map { effectiveAccountID(nodeID: $0) } ?? targetAccountID
    guard sourceAccount != targetAccount else { return nil }
    let name: (UUID?) -> String = { [providerAccounts] id in
      providerAccounts.account(id: id)?.name ?? "this Mac's login"
    }
    return AgentAccountCrossing(
      sourceAccount: name(sourceAccount), targetAccount: name(targetAccount))
  }

  private func accountReference(_ reference: String?) throws -> UUID? {
    let trimmed = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty || ["default", "none", "inherit"].contains(trimmed.lowercased()) {
      return nil
    }
    return try providerAccounts.resolve(trimmed).id
  }

  private func summary(_ account: ProviderAccount) -> ProviderAccountSummary {
    ProviderAccountSummary(
      id: account.id, name: account.name, color: account.color.rawValue,
      isDefault: providerAccounts.defaultAccountID == account.id)
  }
}

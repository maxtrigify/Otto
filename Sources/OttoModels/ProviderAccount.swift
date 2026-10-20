import Foundation

/// A named set of provider credentials — for example a work subscription and a personal one.
///
/// Otto never holds provider login sessions itself. Each account owns one private home
/// directory per provider CLI; the provider's own login command writes its credentials there
/// (or into the Keychain entry that CLI derives from that home). API-key credentials, which
/// Otto does hold, live only in the secure credential store under `apiKeyCredentialKey`.
public struct ProviderAccount: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var color: ProviderAccountColor
  /// Per-provider credential choice. A provider with no entry uses `.login`.
  public var credentialModes: [AgentProvider: ProviderAccountCredentialMode]
  /// Link shared CLI configuration (settings, skills, instructions) from the provider's
  /// default home into this account's home so only the login differs.
  public var sharesProviderConfiguration: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    color: ProviderAccountColor = .blue,
    credentialModes: [AgentProvider: ProviderAccountCredentialMode] = [:],
    sharesProviderConfiguration: Bool = true,
    createdAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.color = color
    self.credentialModes = credentialModes
    self.sharesProviderConfiguration = sharesProviderConfiguration
    self.createdAt = createdAt
  }

  public func credentialMode(for provider: AgentProvider) -> ProviderAccountCredentialMode {
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    let requested = credentialModes[provider] ?? .login
    // A provider without a separable login home can only be isolated by an API key.
    if requested == .login, isolation.homeVariable == nil {
      return isolation.apiKeyVariable == nil ? .systemDefault : .apiKey
    }
    if requested == .apiKey, isolation.apiKeyVariable == nil { return .login }
    return requested
  }

  /// Secure-store key for this account's API key for one provider.
  public func apiKeyCredentialKey(for provider: AgentProvider) -> String {
    Self.apiKeyCredentialKey(accountID: id, credentialName: provider.accountCredentialName)
  }

  /// Secure-store key for an Otto Harness backend key (OpenAI, Anthropic, xAI, Moonshot).
  public func harnessCredentialKey(_ baseKey: String) -> String {
    Self.apiKeyCredentialKey(accountID: id, credentialName: baseKey)
  }

  public static func apiKeyCredentialKey(accountID: UUID, credentialName: String) -> String {
    "account.\(accountID.uuidString.lowercased()).\(credentialName)"
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, color, credentialModes, sharesProviderConfiguration, createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    color = (try? values.decode(ProviderAccountColor.self, forKey: .color)) ?? .blue
    let rawModes =
      try values.decodeIfPresent(
        [String: ProviderAccountCredentialMode].self, forKey: .credentialModes)
      ?? [:]
    credentialModes = Dictionary(
      uniqueKeysWithValues: rawModes.compactMap { key, mode in
        AgentProvider(rawValue: key).map { ($0, mode) }
      })
    sharesProviderConfiguration =
      try values.decodeIfPresent(Bool.self, forKey: .sharesProviderConfiguration) ?? true
    createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(name, forKey: .name)
    try values.encode(color, forKey: .color)
    try values.encode(
      Dictionary(uniqueKeysWithValues: credentialModes.map { ($0.key.rawValue, $0.value) }),
      forKey: .credentialModes)
    try values.encode(sharesProviderConfiguration, forKey: .sharesProviderConfiguration)
    try values.encode(createdAt, forKey: .createdAt)
  }
}

public enum ProviderAccountCredentialMode: String, Codable, CaseIterable, Sendable {
  /// The provider CLI's own login, stored in this account's private provider home.
  case login
  /// An API key held in Otto's secure credential store and passed at launch.
  case apiKey
  /// Not isolated: the provider uses whatever login the Mac already has.
  case systemDefault
}

/// What happens when a run stops because its account hit a usage limit.
public enum ProviderUsageLimitPolicy: String, Codable, CaseIterable, Sendable {
  /// Show the limit in the conversation and let the user choose another account or wait.
  case ask
  /// Re-run the stopped prompt on the same account when the limit resets.
  case waitForReset
  /// Re-run the stopped prompt immediately on the project's fallback account.
  case switchAccount
}

public enum ProviderAccountColor: String, Codable, CaseIterable, Sendable {
  case blue, green, amber, violet, rose, slate

  /// sRGB hex without the leading `#`, tuned for Otto's dark surfaces.
  public var hex: String {
    switch self {
    case .blue: "5FB3CF"
    case .green: "A4C1AF"
    case .amber: "E0B46A"
    case .violet: "BCB6EF"
    case .rose: "E29AA8"
    case .slate: "A3A6B3"
    }
  }
}

/// How one provider CLI can be pointed at a separate account. Every provider is described
/// here so account handling stays provider-neutral: adding a provider means adding one entry.
public struct ProviderAccountIsolation: Equatable, Sendable {
  /// Environment variable that relocates the CLI's home (and therefore its login).
  public var homeVariable: String?
  /// The CLI's default home, relative to the user's home directory.
  public var defaultHomePath: String?
  /// Environment variable the CLI reads an API key from.
  public var apiKeyVariable: String?
  /// Arguments appended to the provider's executable to start its own login flow.
  public var loginArguments: [String]
  /// Entries in the default home that are safe to share between accounts. Credentials and
  /// per-account state (sessions, `.claude.json` account metadata) are deliberately excluded.
  public var sharedEntries: [String]
  /// When set, the home variable points at this subdirectory's parent rather than the account
  /// home itself (XDG-style CLIs keep their data under `$XDG_DATA_HOME/<name>`).
  public var homeSubdirectory: String?

  public init(
    homeVariable: String? = nil,
    defaultHomePath: String? = nil,
    apiKeyVariable: String? = nil,
    loginArguments: [String] = [],
    sharedEntries: [String] = [],
    homeSubdirectory: String? = nil
  ) {
    self.homeVariable = homeVariable
    self.defaultHomePath = defaultHomePath
    self.apiKeyVariable = apiKeyVariable
    self.loginArguments = loginArguments
    self.sharedEntries = sharedEntries
    self.homeSubdirectory = homeSubdirectory
  }

  /// Credentials inherited from the host shell must not override a named account.
  public var credentialEnvironmentVariables: [String] {
    switch homeVariable {
    case "CLAUDE_CONFIG_DIR":
      [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR",
      ]
    case "CODEX_HOME": ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"]
    default: apiKeyVariable.map { [$0] } ?? []
    }
  }

  public var supportsLogin: Bool { homeVariable != nil && !loginArguments.isEmpty }
  public var supportsAPIKey: Bool { apiKeyVariable != nil }

  public static func descriptor(for provider: AgentProvider) -> ProviderAccountIsolation {
    switch provider {
    case .claudeCode:
      ProviderAccountIsolation(
        homeVariable: "CLAUDE_CONFIG_DIR",
        defaultHomePath: ".claude",
        apiKeyVariable: "ANTHROPIC_API_KEY",
        loginArguments: ["auth", "login"],
        sharedEntries: [
          "settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins", "output-styles",
          "hooks",
        ]
      )
    case .codex:
      ProviderAccountIsolation(
        homeVariable: "CODEX_HOME",
        defaultHomePath: ".codex",
        apiKeyVariable: "CODEX_API_KEY",
        loginArguments: ["login"],
        sharedEntries: ["config.toml", "AGENTS.md", "skills", "prompts", "rules", "hooks.json"]
      )
    case .grok:
      ProviderAccountIsolation(
        homeVariable: "GROK_HOME",
        defaultHomePath: ".grok",
        apiKeyVariable: "XAI_API_KEY",
        loginArguments: ["login"],
        sharedEntries: ["config.toml", "hooks"]
      )
    case .kimi:
      ProviderAccountIsolation(
        homeVariable: "KIMI_CODE_HOME",
        defaultHomePath: ".kimi-code",
        apiKeyVariable: "KIMI_API_KEY",
        loginArguments: ["login"],
        sharedEntries: ["config.toml", "tui.toml"]
      )
    case .hermes:
      ProviderAccountIsolation(
        homeVariable: "HERMES_HOME",
        defaultHomePath: ".hermes",
        loginArguments: ["login"],
        sharedEntries: ["config.yaml", "SOUL.md", "skills"]
      )
    case .openCode:
      // OpenCode stores auth.json under $XDG_DATA_HOME/opencode; configuration stays in
      // ~/.config/opencode and is untouched, so nothing needs linking.
      ProviderAccountIsolation(
        homeVariable: "XDG_DATA_HOME",
        defaultHomePath: ".local/share/opencode",
        loginArguments: ["auth", "login"],
        homeSubdirectory: "opencode"
      )
    case .cursor:
      // cursor-agent has no relocatable home; a per-account API key is the only isolation.
      ProviderAccountIsolation(apiKeyVariable: "CURSOR_API_KEY")
    case .openAI:
      // Otto's own harness: keys are per backend and resolved by the harness adapter.
      ProviderAccountIsolation()
    case .shell:
      ProviderAccountIsolation()
    }
  }
}

extension AgentProvider {
  /// Stable, filesystem- and keychain-safe identifier used for account storage.
  public var accountCredentialName: String {
    switch self {
    case .claudeCode: "claude-code"
    case .codex: "codex"
    // Persisted storage name from before the rename; changing it would orphan saved accounts.
    case .openAI: "muse-harness"
    case .cursor: "cursor"
    case .grok: "grok"
    case .hermes: "hermes"
    case .kimi: "kimi"
    case .openCode: "opencode"
    case .shell: "shell"
    }
  }

  /// Whether an agent of this provider can be assigned to an account at all.
  public var supportsProviderAccounts: Bool { self != .shell }
}

import Combine
import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity

/// Device-local registry of provider accounts (work, personal, …).
///
/// Accounts are user-level, not workspace-level: the same work subscription applies in every
/// Otto workspace on this Mac. The registry itself holds no secrets. Provider logins stay in the
/// provider CLI's own storage inside each account home; API keys live in the secure store.
@MainActor
public final class ProviderAccountStore: ObservableObject {
  private struct State: Codable {
    var accounts: [ProviderAccount] = []
    var defaultAccountID: UUID?
  }

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  public var accounts: [ProviderAccount] { state.accounts }
  public var defaultAccountID: UUID? { state.defaultAccountID }

  private let fileURL: URL
  /// Root of every account's provider homes: `<root>/<account-id>/<provider>`.
  public let accountsRoot: URL
  private let userHome: URL
  private let secrets: any SecretStore
  private let fileManager: FileManager

  public init(
    rootDirectory: URL = ProviderAccountStore.defaultRootDirectory,
    userHome: URL = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path,
      isDirectory: true),
    secrets: any SecretStore = makeDefaultSecretStore(),
    fileManager: FileManager = .default
  ) {
    self.fileURL = rootDirectory.appending(path: "provider-accounts.json")
    self.accountsRoot = rootDirectory.appending(path: "Accounts", directoryHint: .isDirectory)
    self.userHome = userHome
    self.secrets = secrets
    self.fileManager = fileManager
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  public nonisolated static var defaultRootDirectory: URL {
    (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
      .appending(path: "Otto", directoryHint: .isDirectory)
  }

  // MARK: - Registry

  public func account(id: UUID?) -> ProviderAccount? {
    guard let id else { return nil }
    return accounts.first { $0.id == id }
  }

  /// Resolves a user-supplied account reference: an ID, or a case-insensitive name.
  public func resolve(_ reference: String) throws -> ProviderAccount {
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = UUID(uuidString: trimmed), let account = account(id: id) { return account }
    let matches = accounts.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    if matches.count == 1 { return matches[0] }
    let prefixed = accounts.filter { $0.name.lowercased().hasPrefix(trimmed.lowercased()) }
    guard prefixed.count == 1 else {
      throw AccountError.unknownAccount(trimmed)
    }
    return prefixed[0]
  }

  @discardableResult
  public func create(name: String, color: ProviderAccountColor? = nil) throws -> ProviderAccount {
    let name = try validatedName(name)
    let usedColors = Set(accounts.map(\.color))
    let account = ProviderAccount(
      name: name,
      color: color ?? ProviderAccountColor.allCases.first { !usedColors.contains($0) } ?? .slate)
    var next = state
    // Creating an account never changes the default: existing agents keep the Mac's current
    // login until the user explicitly picks a default.
    next.accounts.append(account)
    try persist(next)
    return account
  }

  public func update(_ account: ProviderAccount) throws {
    guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
      throw AccountError.unknownAccount(account.id.uuidString)
    }
    var updated = account
    updated.name = try validatedName(account.name, excluding: account.id)
    var next = state
    next.accounts[index] = updated
    try persist(next)
  }

  public func setDefault(_ accountID: UUID?) throws {
    if let accountID, account(id: accountID) == nil {
      throw AccountError.unknownAccount(accountID.uuidString)
    }
    var next = state
    next.defaultAccountID = accountID
    try persist(next)
  }

  /// Removes the account, its stored API keys, and its provider homes (logins included).
  public func delete(_ accountID: UUID) async throws {
    guard let account = account(id: accountID) else { return }
    var next = state
    next.accounts.removeAll { $0.id == accountID }
    if next.defaultAccountID == accountID { next.defaultAccountID = nil }
    try persist(next)
    for provider in AgentProvider.allCases {
      try? await secrets.delete(account.apiKeyCredentialKey(for: provider))
    }
    for key in Self.harnessCredentialKeys {
      try? await secrets.delete(account.harnessCredentialKey(key))
    }
    try? fileManager.removeItem(at: accountDirectory(accountID))
  }

  // MARK: - API keys

  public func setAPIKey(_ value: String?, accountID: UUID, provider: AgentProvider) async throws {
    guard let account = account(id: accountID) else {
      throw AccountError.unknownAccount(accountID.uuidString)
    }
    try await store(value, key: account.apiKeyCredentialKey(for: provider))
  }

  public func hasAPIKey(accountID: UUID, provider: AgentProvider) async -> Bool {
    guard let account = account(id: accountID) else { return false }
    return await hasSecret(account.apiKeyCredentialKey(for: provider))
  }

  /// Otto Harness backends (OpenAI, Anthropic, xAI, Moonshot) are keyed by their base
  /// credential key, e.g. `openai.api-key`.
  public func setHarnessKey(_ value: String?, accountID: UUID, credentialKey: String) async throws {
    guard let account = account(id: accountID) else {
      throw AccountError.unknownAccount(accountID.uuidString)
    }
    try await store(value, key: account.harnessCredentialKey(credentialKey))
  }

  public func hasHarnessKey(accountID: UUID, credentialKey: String) async -> Bool {
    guard let account = account(id: accountID) else { return false }
    return await hasSecret(account.harnessCredentialKey(credentialKey))
  }

  // MARK: - Provider homes

  public func accountDirectory(_ accountID: UUID) -> URL {
    accountsRoot.appending(path: accountID.uuidString.lowercased(), directoryHint: .isDirectory)
  }

  /// The directory assigned to the provider's home variable for this account.
  public func providerHome(accountID: UUID, provider: AgentProvider) -> URL {
    accountDirectory(accountID).appending(
      path: provider.accountCredentialName, directoryHint: .isDirectory)
  }

  /// Where the provider actually keeps its files inside the account home.
  public func providerDataDirectory(accountID: UUID, provider: AgentProvider) -> URL {
    let home = providerHome(accountID: accountID, provider: provider)
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    return isolation.homeSubdirectory.map { home.appending(path: $0, directoryHint: .isDirectory) }
      ?? home
  }

  /// Creates the account's provider home and links shared configuration from the default home.
  /// Existing files in the account home always win, so per-account overrides are preserved.
  @discardableResult
  public func prepareProviderHome(accountID: UUID, provider: AgentProvider) throws -> URL {
    guard let account = account(id: accountID) else {
      throw AccountError.unknownAccount(accountID.uuidString)
    }
    let home = providerHome(accountID: accountID, provider: provider)
    let data = providerDataDirectory(accountID: accountID, provider: provider)
    try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    guard account.sharesProviderConfiguration, let defaultPath = isolation.defaultHomePath else {
      return home
    }
    let defaultHome = userHome.appending(path: defaultPath, directoryHint: .isDirectory)
    for entry in isolation.sharedEntries {
      let source = defaultHome.appending(path: entry)
      let destination = data.appending(path: entry)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      // `fileExists` follows links; check the link itself so a dangling link is not recreated.
      if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil
        || fileManager.fileExists(atPath: destination.path)
      {
        continue
      }
      try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    }
    return home
  }

  /// Best-effort check that the provider's own login has been completed for this account.
  public func hasProviderLogin(accountID: UUID, provider: AgentProvider) -> Bool {
    let data = providerDataDirectory(accountID: accountID, provider: provider)
    if provider == .claudeCode {
      // Claude writes `.claude.json` on every launch, signed in or not; only a completed login
      // records the OAuth account in it (credentials themselves stay in the Keychain).
      let state = try? Data(contentsOf: data.appending(path: ".claude.json"))
      if let state, String(decoding: state, as: UTF8.self).contains("\"oauthAccount\"") {
        return true
      }
    }
    return Self.loginMarkers(for: provider).contains { marker in
      fileManager.fileExists(atPath: data.appending(path: marker).path)
    }
  }

  static func loginMarkers(for provider: AgentProvider) -> [String] {
    switch provider {
    case .claudeCode: [".credentials.json"]
    case .codex: ["auth.json"]
    case .grok: ["auth.json"]
    case .kimi: ["credentials"]
    case .hermes: [".env", "auth.json", "config.yaml"]
    case .openCode: ["auth.json"]
    case .cursor, .openAI, .shell: []
    }
  }

  // MARK: - Login identity

  /// Who the account's own provider login belongs to, when the provider records it in a file.
  public func loginIdentity(accountID: UUID, provider: AgentProvider) -> ProviderLoginIdentity? {
    let data = providerDataDirectory(accountID: accountID, provider: provider)
    return Self.readIdentity(
      provider: provider, in: data, claudeState: data.appending(path: ".claude.json"))
  }

  /// Who this Mac's own (non-account) provider login belongs to.
  public func macLoginIdentity(provider: AgentProvider) -> ProviderLoginIdentity? {
    guard let defaultPath = ProviderAccountIsolation.descriptor(for: provider).defaultHomePath
    else { return nil }
    // Claude keeps its default state next to the home folder, not inside it.
    return Self.readIdentity(
      provider: provider, in: userHome.appending(path: defaultPath, directoryHint: .isDirectory),
      claudeState: userHome.appending(path: ".claude.json"))
  }

  /// Signed in, and to a different provider account than the Mac's own login. A browser that is
  /// already signed in silently approves the same account again, so a completed login alone
  /// does not prove the account is separate.
  public func loginStatus(accountID: UUID, provider: AgentProvider) -> ProviderLoginStatus {
    guard hasProviderLogin(accountID: accountID, provider: provider) else { return .signedOut }
    let identity = loginIdentity(accountID: accountID, provider: provider)
    if let identity, let mac = macLoginIdentity(provider: provider), identity.isSameAccount(as: mac)
    {
      return .sameAsMac(identity)
    }
    return .signedIn(identity)
  }

  /// Whether the account adds a login this Mac does not already have.
  public func hasDistinctProviderLogin(accountID: UUID, provider: AgentProvider) -> Bool {
    if case .signedIn = loginStatus(accountID: accountID, provider: provider) { return true }
    return false
  }

  nonisolated static func readIdentity(
    provider: AgentProvider, in directory: URL, claudeState: URL
  ) -> ProviderLoginIdentity? {
    switch provider {
    case .claudeCode:
      guard
        let data = try? Data(contentsOf: claudeState),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let account = object["oauthAccount"] as? [String: Any]
      else { return nil }
      return ProviderLoginIdentity(
        email: account["emailAddress"] as? String,
        organization: account["organizationName"] as? String,
        accountKey: account["accountUuid"] as? String,
        organizationKey: account["organizationUuid"] as? String)
    case .codex:
      guard
        let data = try? Data(contentsOf: directory.appending(path: "auth.json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tokens = object["tokens"] as? [String: Any],
        let idToken = tokens["id_token"] as? String,
        let claims = jwtClaims(idToken)
      else { return nil }
      let auth = claims["https://api.openai.com/auth"] as? [String: Any]
      return ProviderLoginIdentity(
        email: claims["email"] as? String,
        organization: nil,
        accountKey: (auth?["chatgpt_user_id"] as? String) ?? (claims["sub"] as? String),
        organizationKey: (auth?["chatgpt_account_id"] as? String)
          ?? (tokens["account_id"] as? String))
    default:
      return nil
    }
  }

  /// Decodes a JWT payload without verifying it: used only to label the login, never to trust it.
  private nonisolated static func jwtClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = parts[1].replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  // MARK: - Launch

  /// Environment and credentials for one agent launch on `accountID`. Returns nil when the
  /// account is unknown so callers fall back to the Mac's existing provider login.
  public func launchContext(accountID: UUID?, provider: AgentProvider) async throws
    -> AgentAccountLaunch?
  {
    guard provider.supportsProviderAccounts, let account = account(id: accountID) else {
      return nil
    }
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    var environment: [String: String] = [:]
    var harnessKeys: [String: String] = [:]
    switch account.credentialMode(for: provider) {
    case .login:
      if let variable = isolation.homeVariable {
        environment[variable] = try prepareProviderHome(accountID: account.id, provider: provider)
          .path
      }
    case .apiKey:
      guard let variable = isolation.apiKeyVariable else { break }
      guard let key = try await secrets.value(for: account.apiKeyCredentialKey(for: provider)),
        !key.isEmpty
      else {
        throw AccountError.missingAPIKey(account: account.name, provider: provider.rawValue)
      }
      environment[variable] = key
    case .systemDefault:
      break
    }
    if provider == .openAI {
      for base in Self.harnessCredentialKeys {
        if let key = try await secrets.value(for: account.harnessCredentialKey(base)), !key.isEmpty
        {
          harnessKeys[base] = key
        }
      }
    }
    return AgentAccountLaunch(
      accountID: account.id, accountName: account.name, environment: environment,
      harnessCredentials: harnessKeys,
      inheritedEnvironmentPrefixesToRemove: account.credentialMode(for: provider) == .systemDefault
        ? [] : isolation.credentialEnvironmentVariables)
  }

  /// Environment for running the provider's own login command against this account's home.
  public func loginEnvironment(accountID: UUID, provider: AgentProvider) throws -> [String: String]
  {
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    guard let variable = isolation.homeVariable else {
      throw AccountError.loginUnsupported(provider.rawValue)
    }
    return [variable: try prepareProviderHome(accountID: accountID, provider: provider).path]
  }

  /// Account resolution order: the agent's own choice, the project's default, the global default.
  public func effectiveAccountID(agentAccountID: UUID?, projectDefaultAccountID: UUID?) -> UUID? {
    for candidate in [agentAccountID, projectDefaultAccountID, defaultAccountID] {
      if let candidate, account(id: candidate) != nil { return candidate }
    }
    return nil
  }

  // MARK: - Private

  public static let harnessCredentialKeys = [
    "openai.api-key", "anthropic.api-key", "xai.api-key", "moonshot.api-key",
  ]

  private func validatedName(_ raw: String, excluding id: UUID? = nil) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 60 else { throw AccountError.invalidName }
    guard
      !accounts.contains(where: {
        $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
      })
    else { throw AccountError.duplicateName(name) }
    return name
  }

  private func store(_ value: String?, key: String) async throws {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      try await secrets.delete(key)
    } else {
      try await secrets.set(trimmed, for: key)
    }
  }

  private func hasSecret(_ key: String) async -> Bool {
    ((try? await secrets.value(for: key)) ?? nil)?.isEmpty == false
  }

  private func persist(_ next: State) throws {
    if let persistenceError { throw AccountError.unavailable(persistenceError) }
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
    state = next
  }

  public enum AccountError: Error, LocalizedError, Equatable {
    case invalidName
    case duplicateName(String)
    case unknownAccount(String)
    case missingAPIKey(account: String, provider: String)
    case loginUnsupported(String)
    case unavailable(String)

    public var errorDescription: String? {
      switch self {
      case .invalidName: "Account names must be 1–60 characters."
      case .duplicateName(let name): "An account named \(name) already exists."
      case .unknownAccount(let reference): "No account matches \(reference)."
      case .missingAPIKey(let account, let provider):
        "\(account) has no \(provider) API key. Add it in Settings → Accounts."
      case .loginUnsupported(let provider):
        "\(provider) has no separate login home; use an API key for this account instead."
      case .unavailable(let message): "Accounts are unavailable: \(message)"
      }
    }
  }
}

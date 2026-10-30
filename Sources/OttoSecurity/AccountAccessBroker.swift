import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Host-only policy foundation. Do not expose administration or submission as agent tools.
/// The caller must authenticate the human/device and derive identity from the host session.
/// This actor is NOT an isolation boundary against unrestricted same-user processes.
public actor AccountAccessBroker {
  /// One writer per host process. The future isolated broker must own this instance;
  /// independent processes must not concurrently mutate the same Keychain record.
  public static let shared = AccountAccessBroker()

  public enum Action: String, Codable, Sendable, Hashable {
    case browser
    case api
  }

  public enum BotScope: Codable, Sendable, Equatable {
    case selected(Set<UUID>)
    /// Explicit opt-in; selected bots never implicitly includes subsequently created bots.
    case allCurrentAndFuture

    fileprivate func contains(_ id: UUID) -> Bool {
      switch self {
      case .selected(let ids): ids.contains(id)
      case .allCurrentAndFuture: true
      }
    }
  }

  public struct Identity: Sendable, Equatable {
    public let userID: UUID
    public let workspaceID: UUID
    public let botID: UUID
    public let runID: UUID
    public let deviceID: UUID

    public init(userID: UUID, workspaceID: UUID, botID: UUID, runID: UUID, deviceID: UUID) {
      self.userID = userID
      self.workspaceID = workspaceID
      self.botID = botID
      self.runID = runID
      self.deviceID = deviceID
    }
  }

  /// Safe metadata only. Neither this value nor an account ID authorises execution.
  public struct Account: Codable, Sendable, Equatable {
    public let id: UUID
    public let userID: UUID
    public let workspaceID: UUID
    public let origin: String
    public fileprivate(set) var bots: BotScope
    public fileprivate(set) var actions: Set<Action>
    public fileprivate(set) var browserSessionApproved: Bool?
    public fileprivate(set) var hasCredential: Bool
  }

  /// Display in a secure native flow, never accept the ID alone as authentication.
  public struct InputRequest: Sendable, Equatable {
    public let id: UUID
    public let accountID: UUID
    public let origin: String
    public let action: Action
    public let expiresAt: Date
  }

  /// Native-only value, deliberately not Codable. Default logging and reflection redact it.
  /// This does not guarantee memory zeroisation or make an ordinary chat/RPC path safe.
  public struct SecretInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
  {
    fileprivate let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
  }

  public enum Failure: Error, Equatable, Sendable {
    case denied, invalidOrigin, invalidRequest, invalidSecret, unavailable, busy
  }

  private struct Entry: Codable {
    var account: Account
    var credential: String?
  }

  private struct State: Codable {
    var version = 1
    var entries: [Entry] = []
  }

  private struct Pending {
    let request: InputRequest
    let identity: Identity
  }

  private let storage: any SecretStore
  private let now: @Sendable () -> Date
  private var pending: [UUID: Pending] = [:]
  private var transactionActive = false
  private var processLock: ProcessFileLock?
  private var needsProcessLock = true
  private static let storageKey = "account-access-v1"

  /// Deliberately bypasses makeDefaultSecretStore: no DEBUG file fallback. Items written under
  /// the pre-rename service are still read (and copied forward) once.
  private init() {
    storage = makeKeychainSecretStore(service: OttoSecretService.accountAccess)
    now = { Date() }
  }

  /// Test-only injection; production callers cannot substitute file-backed storage.
  package init(storage: any SecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
    self.storage = storage
    self.now = now
    needsProcessLock = false
  }

  public func createAccount(
    userID: UUID, workspaceID: UUID, origin: String,
    bots: BotScope, actions: Set<Action>
  ) async throws -> Account {
    try beginTransaction()
    defer { endTransaction() }
    let origin = try Self.canonicalOrigin(origin)
    guard !actions.isEmpty else { throw Failure.denied }
    var state = try await load()
    guard state.entries.count < 256 else { throw Failure.unavailable }
    let account = Account(
      id: UUID(), userID: userID, workspaceID: workspaceID, origin: origin,
      bots: bots, actions: actions, hasCredential: false)
    state.entries.append(Entry(account: account))
    try await save(state)
    return account
  }

  public func accounts(userID: UUID, workspaceID: UUID) async throws -> [Account] {
    try beginTransaction()
    defer { endTransaction() }
    return try await load().entries.map(\.account).filter {
      $0.userID == userID && $0.workspaceID == workspaceID
    }
  }

  public func updateGrant(
    accountID: UUID, userID: UUID, workspaceID: UUID,
    bots: BotScope, actions: Set<Action>
  ) async throws {
    try beginTransaction()
    defer { endTransaction() }
    var state = try await load()
    let index = try Self.ownedIndex(state, accountID, userID, workspaceID)
    state.entries[index].account.bots = bots
    state.entries[index].account.actions = actions
    // Retire old requests even if storage fails; no stale approval may later submit.
    invalidateRequests(accountID)
    try await save(state)
  }

  /// Removes both policy and local credential atomically. Upstream logout is separate.
  public func disconnect(accountID: UUID, userID: UUID, workspaceID: UUID) async throws {
    try beginTransaction()
    defer { endTransaction() }
    var state = try await load()
    let index = try Self.ownedIndex(state, accountID, userID, workspaceID)
    invalidateRequests(accountID)
    state.entries.remove(at: index)
    try await save(state)
  }

  /// Policy check only, not a bearer capability or a browser/API execution endpoint.
  public func authorise(
    accountID: UUID, identity: Identity, origin: String, action: Action
  ) async throws -> Account {
    try beginTransaction()
    defer { endTransaction() }
    let state = try await load()
    return try Self.authorisedEntry(state, accountID, identity, origin, action).account
  }

  /// Native owner confirmation; a cookie session is not a stored password.
  public func approveBrowserSession(
    accountID: UUID, userID: UUID, workspaceID: UUID, approved: Bool
  ) async throws {
    try beginTransaction()
    defer { endTransaction() }
    var state = try await load()
    let index = try Self.ownedIndex(state, accountID, userID, workspaceID)
    state.entries[index].account.browserSessionApproved = approved
    try await save(state)
  }

  public func requestInput(
    accountID: UUID, identity: Identity, origin: String, action: Action
  ) async throws -> InputRequest {
    try beginTransaction()
    defer { endTransaction() }
    let state = try await load()
    let entry = try Self.authorisedEntry(state, accountID, identity, origin, action)
    let timestamp = now()
    pending = pending.filter { $0.value.request.expiresAt > timestamp }
    // Only the latest native prompt may replace this account's credential.
    invalidateRequests(accountID)
    guard pending.count < 128 else { throw Failure.unavailable }
    let request = InputRequest(
      id: UUID(), accountID: accountID, origin: entry.account.origin,
      action: action, expiresAt: timestamp.addingTimeInterval(300))
    pending[request.id] = Pending(request: request, identity: identity)
    return request
  }

  /// Host lifecycle hooks: revoke pending input when a paired device is removed or a run ends.
  public func cancelInputs(deviceID: UUID) throws {
    try beginTransaction()
    defer { endTransaction() }
    pending = pending.filter { $0.value.identity.deviceID != deviceID }
  }

  public func cancelInputs(runID: UUID) throws {
    try beginTransaction()
    defer { endTransaction() }
    pending = pending.filter { $0.value.identity.runID != runID }
  }

  /// Native authenticated input only. There is intentionally no secret retrieval API.
  /// Do not encode this call into tool arguments, chat messages or ordinary RPC logging.
  public func submitInput(
    requestID: UUID, identity: Identity, origin: String, secret: SecretInput
  ) async throws {
    try beginTransaction()
    defer { endTransaction() }
    guard let item = pending[requestID], item.identity == identity,
      item.request.origin == (try? Self.canonicalOrigin(origin)),
      item.request.expiresAt > now()
    else { throw Failure.invalidRequest }
    // Consume before the first suspension; storage errors require a fresh native request.
    pending.removeValue(forKey: requestID)
    guard !secret.value.isEmpty, secret.value.utf8.count <= 65_536 else {
      throw Failure.invalidSecret
    }
    var state = try await load()
    _ = try Self.authorisedEntry(
      state, item.request.accountID, identity, origin, item.request.action)
    // Loading storage may take time (e.g. a Keychain prompt).
    guard item.request.expiresAt > now() else { throw Failure.invalidRequest }
    let index = try Self.ownedIndex(
      state, item.request.accountID, identity.userID, identity.workspaceID)
    state.entries[index].credential = secret.value
    state.entries[index].account.hasCredential = true
    try await save(state)
  }

  private func beginTransaction() throws {
    // Reject reentrant calls during a Keychain operation instead of losing updates.
    guard !transactionActive else { throw Failure.busy }
    if needsProcessLock {
      let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Otto/AccountAccess")
      do {
        try FileManager.default.createDirectory(
          at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      } catch { throw Failure.unavailable }
      do {
        processLock = try ProcessFileLock(path: root.appending(path: "writer.lock").path)
      } catch ProcessFileLock.Failure.busy {
        throw Failure.busy
      } catch {
        throw Failure.unavailable
      }
    }
    transactionActive = true
  }

  private func endTransaction() {
    processLock?.release()
    processLock = nil
    transactionActive = false
  }

  private func invalidateRequests(_ accountID: UUID) {
    pending = pending.filter { $0.value.request.accountID != accountID }
  }

  private func load() async throws -> State {
    do {
      guard let encoded = try await storage.value(for: Self.storageKey) else { return State() }
      let state = try JSONDecoder().decode(State.self, from: Data(encoded.utf8))
      guard state.version == 1,
        Set(state.entries.map { $0.account.id }).count == state.entries.count,
        state.entries.allSatisfy({
          (try? Self.canonicalOrigin($0.account.origin)) == $0.account.origin
            && $0.account.hasCredential == ($0.credential != nil)
        })
      else { throw Failure.unavailable }
      return state
    } catch { throw Failure.unavailable }
  }

  private func save(_ state: State) async throws {
    do {
      let data = try JSONEncoder().encode(state)
      try await storage.set(String(decoding: data, as: UTF8.self), for: Self.storageKey)
    } catch {
      // Underlying storage errors may embed sensitive values; never forward them.
      throw Failure.unavailable
    }
  }

  private static func ownedIndex(
    _ state: State, _ accountID: UUID, _ userID: UUID, _ workspaceID: UUID
  ) throws -> Int {
    guard
      let index = state.entries.firstIndex(where: {
        $0.account.id == accountID && $0.account.userID == userID
          && $0.account.workspaceID == workspaceID
      })
    else { throw Failure.denied }
    return index
  }

  private static func authorisedEntry(
    _ state: State, _ accountID: UUID, _ identity: Identity, _ origin: String, _ action: Action
  ) throws -> Entry {
    let index = try ownedIndex(state, accountID, identity.userID, identity.workspaceID)
    let entry = state.entries[index]
    guard entry.account.origin == (try? canonicalOrigin(origin)),
      entry.account.bots.contains(identity.botID), entry.account.actions.contains(action)
    else { throw Failure.denied }
    return entry
  }

  /// Accept origins, not arbitrary URLs: no credentials, path, query, fragment or wildcards.
  /// HTTPS only; explicit non-default ports remain a distinct origin.
  private static func canonicalOrigin(_ value: String) throws -> String {
    guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(), !host.isEmpty,
      !host.contains("*"), !host.contains("%"), !host.hasSuffix("."),
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/",
      url.port == nil || (1...65_535).contains(url.port!)
    else { throw Failure.invalidOrigin }
    let port = url.port.flatMap { $0 == 443 ? nil : ":\($0)" } ?? ""
    return "https://\(host)\(port)"
  }
}

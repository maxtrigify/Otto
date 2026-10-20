import Combine
import CryptoKit
import Foundation
import OttoModels
import OttoSecurity
import OttoTools

public enum AppConnectionError: Error, LocalizedError, Equatable {
  case setupRequired, cancelled, invalidCallback, reconnectRequired, unavailable, invalidMessage
  case requestFailed(Int)
  public var errorDescription: String? {
    switch self {
    case .setupRequired: "Google sign-in is not configured for this Otto installation yet."
    case .cancelled: "Google sign-in was cancelled or timed out."
    case .invalidCallback: "Google sign-in could not be verified. Please try again."
    case .reconnectRequired: "Reconnect Gmail in Connect apps to continue."
    case .unavailable: "This Gmail connection is unavailable to this agent."
    case .invalidMessage:
      "Provide a valid recipient, subject and message without header line breaks."
    case .requestFailed(let status): "Google could not complete the request (HTTP \(status))."
    }
  }
}

public struct GmailConnection: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var email: String
  public var scopes: Set<String>
  public var needsReconnect: Bool
  public var shared: Bool
  public var createdAt: Date
  var credentialID: UUID? = nil
}

public enum SharedAppProviders {
  public static let supported: Set<AgentProvider> = [
    .claudeCode, .codex, .cursor, .grok, .kimi, .openCode,
  ]
}

// Credentials are encoded only into SecretStore; never into workspace metadata or tool results.
struct GoogleCredential: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  var description: String { "<Google credential redacted>" }
  var debugDescription: String { description }
  var accessToken: String
  var refreshToken: String
  var expiresAt: Date
  var clientID: String
}

struct GoogleTokenResponse: Decodable, Sendable {
  let accessToken: String
  let expiresIn: Double
  let refreshToken: String?
  let scope: String?
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

struct GoogleHTTP: Sendable {
  let execute: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  init(session: URLSession = .shared) {
    execute = { request in
      let (data, response) = try await session.data(for: request)
      return (data, response)
    }
  }
  init(execute: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
    self.execute = execute
  }
  func data(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await execute(request)
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 { throw AppConnectionError.reconnectRequired }
      throw AppConnectionError.requestFailed(response.statusCode)
    }
    guard data.count <= 16_000_000 else { throw AppConnectionError.requestFailed(413) }
    return data
  }
  func token(_ fields: [String: String]) async throws -> GoogleTokenResponse {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.form(fields).utf8)
    let (data, response) = try await execute(request)
    guard response.statusCode == 200 else {
      // Never surface the response body: token endpoints can echo sensitive values.
      if let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        error["error"] as? String == "invalid_grant"
      {
        throw AppConnectionError.reconnectRequired
      }
      throw AppConnectionError.requestFailed(response.statusCode)
    }
    return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
  }
  static func form(_ fields: [String: String]) -> String {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return fields.sorted { $0.key < $1.key }.map {
      "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
  }
}

@MainActor
public final class AppConnectionsStore: ObservableObject {
  public nonisolated static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
  public nonisolated static let composeScope = "https://www.googleapis.com/auth/gmail.compose"
  public nonisolated static let sendScope = "https://www.googleapis.com/auth/gmail.send"
  @Published public private(set) var accounts: [GmailConnection] = []
  @Published public private(set) var isConnecting = false
  @Published public private(set) var error: String?
  @Published public private(set) var googleClientID: String
  private let fileURL: URL
  private let configurationURL: URL
  private let namespace: String
  private let secrets: any SecretStore
  private let http: GoogleHTTP
  private var refreshes: [UUID: Task<GoogleCredential, Error>] = [:]
  private var generations: [UUID: UUID] = [:]
  private var signIn: GoogleLoopbackSignIn?
  private var connectID: UUID?
  private var disconnecting: Set<UUID> = []

  public convenience init(workspacePath: String) {
    self.init(
      workspacePath: workspacePath,
      secrets: makeKeychainSecretStore(service: OttoSecretService.appConnections),
      http: GoogleHTTP())
  }
  init(
    workspacePath: String, secrets: any SecretStore, http: GoogleHTTP,
    clientID: String? = nil
  ) {
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/app-connections.json")
    let root = ProviderAccountStore.defaultRootDirectory
    configurationURL = root.appending(path: "google-app-client.json")
    namespace = SHA256.hash(
      data: Data(URL(fileURLWithPath: workspacePath).standardizedFileURL.path.utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
    self.secrets = secrets
    self.http = http
    googleClientID =
      clientID
      ?? OttoEnvironment.value("GOOGLE_CLIENT_ID")
      ?? (Bundle.main.object(forInfoDictionaryKey: "OttoGoogleClientID") as? String)
      ?? ((try? WorkspaceJSONFile.load(String.self, from: configurationURL, fileManager: .default))
        ?? "")
    do {
      accounts =
        try WorkspaceJSONFile.load([GmailConnection].self, from: fileURL, fileManager: .default)
        ?? []
    } catch { self.error = "Could not load app connections. \(error.localizedDescription)" }
  }

  public var isConfigured: Bool { !googleClientID.isEmpty }
  public func configureGoogle(clientID: String, clientSecret: String?) async throws {
    let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard id.hasSuffix(".apps.googleusercontent.com"), id.count < 512 else {
      throw AppConnectionError.setupRequired
    }
    if let clientSecret, !clientSecret.isEmpty {
      try await secrets.set(clientSecret, for: "google-client-\(id)")
    }
    try WorkspaceJSONFile.save(id, to: configurationURL, fileManager: .default)
    googleClientID = id
  }

  public func connect(allowSending: Bool = false, reconnecting accountID: UUID? = nil) async {
    guard !isConnecting else { return }
    guard disconnecting.isEmpty else {
      error = AppConnectionError.unavailable.localizedDescription
      return
    }
    guard isConfigured else {
      error = AppConnectionError.setupRequired.localizedDescription
      return
    }
    let operationID = UUID()
    connectID = operationID
    if let accountID, generations[accountID] == nil { generations[accountID] = UUID() }
    let reconnectGeneration = accountID.flatMap { generations[$0] }
    isConnecting = true
    error = nil
    let signIn = GoogleLoopbackSignIn()
    self.signIn = signIn
    defer {
      self.signIn = nil
      connectID = nil
      isConnecting = false
    }
    do {
      let clientID = googleClientID
      var scopes: Set<String> = [Self.readScope]
      if allowSending { scopes.formUnion([Self.composeScope, Self.sendScope]) }
      let authorization = try await signIn.authorize(clientID: clientID, scopes: scopes)
      var fields = [
        "client_id": clientID, "grant_type": "authorization_code",
        "code": authorization.code, "code_verifier": authorization.verifier,
        "redirect_uri": authorization.redirectURI,
      ]
      fields["client_secret"] = try await secrets.value(for: "google-client-\(clientID)")
      let token = try await http.token(fields)
      let granted = Set((token.scope ?? "").split(separator: " ").map(String.init))
      guard granted.contains(Self.readScope), let refresh = token.refreshToken,
        !refresh.isEmpty
      else { throw AppConnectionError.reconnectRequired }
      var request = URLRequest(
        url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
      request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
      let profile = try JSONDecoder().decode(GmailProfile.self, from: await http.data(request))
      if let accountID, let old = accounts.first(where: { $0.id == accountID }),
        old.email.caseInsensitiveCompare(profile.emailAddress) != .orderedSame
      {
        throw AppConnectionError.invalidCallback
      }
      guard connectID == operationID else { throw AppConnectionError.cancelled }
      if let accountID {
        guard accounts.contains(where: { $0.id == accountID }),
          generations[accountID] == reconnectGeneration
        else { throw AppConnectionError.unavailable }
      }
      let existing = accounts.first {
        $0.email.caseInsensitiveCompare(profile.emailAddress) == .orderedSame
      }
      let id = accountID ?? existing?.id ?? UUID()
      let account = GmailConnection(
        id: id, email: profile.emailAddress, scopes: granted,
        needsReconnect: false, shared: existing?.shared ?? true,
        createdAt: existing?.createdAt ?? .now)
      try await install(
        account,
        credential: GoogleCredential(
          accessToken: token.accessToken,
          refreshToken: refresh, expiresAt: .now.addingTimeInterval(token.expiresIn),
          clientID: clientID), connectOperationID: operationID)
    } catch { self.error = safeMessage(error) }
  }
  public func cancelConnect() {
    connectID = nil
    signIn?.cancel()
  }
  public func clearError() { error = nil }

  func install(
    _ account: GmailConnection, credential: GoogleCredential, connectOperationID: UUID? = nil
  ) async throws {
    // Reject duplicate IDs before decoding persisted records into any dictionary.
    var account = account
    let old = accounts.first { $0.id == account.id }
    account.credentialID = UUID()
    let key = credentialKey(account)
    let generation = UUID()
    generations[account.id] = generation
    refreshes.removeValue(forKey: account.id)?.cancel()
    let value = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
    try await secrets.set(value, for: key)
    guard generations[account.id] == generation,
      connectOperationID == nil || connectID == connectOperationID
    else {
      try? await secrets.delete(key)
      throw AppConnectionError.unavailable
    }
    var next = accounts.filter { $0.id != account.id }
    next.append(account)
    do { try persist(next) } catch {
      try? await secrets.delete(key)
      throw error
    }
    if let old { try? await secrets.delete(credentialKey(old)) }
  }

  public func setShared(_ shared: Bool, accountID: UUID) throws {
    guard !disconnecting.contains(accountID) else { throw AppConnectionError.unavailable }
    var next = accounts
    guard let index = next.firstIndex(where: { $0.id == accountID }) else { return }
    next[index].shared = shared
    try persist(next)
  }

  public func disconnect(accountID: UUID) async throws {
    guard !disconnecting.contains(accountID) else { throw AppConnectionError.unavailable }
    disconnecting.insert(accountID)
    defer { disconnecting.remove(accountID) }
    cancelConnect()
    guard let account = accounts.first(where: { $0.id == accountID }) else { return }
    let key = credentialKey(account)
    // Deny calls before waiting on keychain or the network, including refreshes already in flight.
    var paused = accounts
    paused[paused.firstIndex(where: { $0.id == accountID })!].shared = false
    try persist(paused)
    generations[accountID] = UUID()
    refreshes.removeValue(forKey: accountID)?.cancel()
    let encoded = try await secrets.value(for: key)
    try await secrets.delete(key)
    try persist(accounts.filter { $0.id != accountID })
    guard let encoded,
      let credential = try? JSONDecoder().decode(GoogleCredential.self, from: Data(encoded.utf8))
    else { return }
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(GoogleHTTP.form(["token": credential.refreshToken]).utf8)
    do { _ = try await http.data(request) } catch {
      self.error =
        "Disconnected in Otto. Google revocation could not be confirmed; remove Otto access from your Google account if needed."
    }
  }

  public func available(provider: AgentProvider, scope: String = readScope) -> Bool {
    SharedAppProviders.supported.contains(provider)
      && accounts.contains { $0.shared && !$0.needsReconnect && $0.scopes.contains(scope) }
  }
  func resolve(_ reference: UUID?, scope: String) throws -> GmailConnection {
    let eligible = accounts.filter { $0.shared && !$0.needsReconnect && $0.scopes.contains(scope) }
    if let reference, let account = eligible.first(where: { $0.id == reference }) { return account }
    guard reference == nil, eligible.count == 1 else {
      if reference == nil, eligible.count > 1 {
        throw ToolRegistryError.invalidInput(
          "Several Gmail accounts are connected. Supply an accountID from apps.accounts.")
      }
      throw AppConnectionError.unavailable
    }
    return eligible[0]
  }

  func request(
    account: GmailConnection, path: String, method: String = "GET",
    query: [URLQueryItem] = [], body: JSONValue? = nil
  ) async throws -> JSONValue {
    let generation = generations[account.id, default: UUID()]
    generations[account.id] = generation
    do {
      let credential = try await freshCredential(account.id, generation: generation)
      try requireActive(account.id, generation: generation)
      var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
      url.queryItems = query.isEmpty ? nil : query
      var request = URLRequest(url: url.url!)
      request.httpMethod = method
      request.timeoutInterval = 30
      request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
      if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
      }
      let data = try await http.data(request)
      try requireActive(account.id, generation: generation)
      return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch AppConnectionError.reconnectRequired {
      if generations[account.id] == generation, accounts.contains(where: { $0.id == account.id }) {
        var next = accounts
        next[next.firstIndex(where: { $0.id == account.id })!].needsReconnect = true
        try persist(next)
      }
      throw AppConnectionError.reconnectRequired
    }
  }
  private func freshCredential(_ id: UUID, generation: UUID) async throws -> GoogleCredential {
    if let refresh = refreshes[id] { return try await refresh.value }
    guard let account = accounts.first(where: { $0.id == id }) else {
      throw AppConnectionError.unavailable
    }
    let key = credentialKey(account)
    guard let encoded = try await secrets.value(for: key) else {
      throw AppConnectionError.reconnectRequired
    }
    try requireActive(id, generation: generation)
    let credential = try JSONDecoder().decode(GoogleCredential.self, from: Data(encoded.utf8))
    if credential.expiresAt.timeIntervalSinceNow > 60 { return credential }
    if let refresh = refreshes[id] { return try await refresh.value }
    let task = Task { [http, secrets] in
      var fields = [
        "client_id": credential.clientID, "grant_type": "refresh_token",
        "refresh_token": credential.refreshToken,
      ]
      fields["client_secret"] = try await secrets.value(for: "google-client-\(credential.clientID)")
      let token = try await http.token(fields)
      return GoogleCredential(
        accessToken: token.accessToken,
        refreshToken: token.refreshToken ?? credential.refreshToken,
        expiresAt: .now.addingTimeInterval(token.expiresIn), clientID: credential.clientID)
    }
    refreshes[id] = task
    defer { if generations[id] == generation { refreshes[id] = nil } }
    let renewed = try await task.value
    try requireActive(id, generation: generation)
    try await secrets.set(String(decoding: JSONEncoder().encode(renewed), as: UTF8.self), for: key)
    do { try requireActive(id, generation: generation) } catch {
      if !accounts.contains(where: { $0.id == id && $0.credentialID == account.credentialID }) {
        try? await secrets.delete(key)
      }
      throw error
    }
    return renewed
  }
  private func requireActive(_ id: UUID, generation: UUID) throws {
    guard generations[id] == generation,
      accounts.contains(where: { $0.id == id && $0.shared && !$0.needsReconnect })
    else {
      throw AppConnectionError.unavailable
    }
  }
  func credentialKey(_ id: UUID) -> String {
    if let account = accounts.first(where: { $0.id == id }) { return credentialKey(account) }
    return "gmail-\(namespace)-\(id.uuidString)"
  }
  private func credentialKey(_ account: GmailConnection) -> String {
    "gmail-\(namespace)-\(account.id.uuidString)-\(account.credentialID?.uuidString ?? "legacy")"
  }
  private func persist(_ next: [GmailConnection]) throws {
    try WorkspaceJSONFile.save(next, to: fileURL, fileManager: .default)
    accounts = next
  }
  private func safeMessage(_ error: Error) -> String {
    if let error = error as? AppConnectionError { return error.localizedDescription }
    if error is SecretStoreError {
      return "Could not access secure storage. Please check Keychain access."
    }
    return "The connection could not be completed. Please try again."
  }
}
private struct GmailProfile: Decodable { let emailAddress: String }

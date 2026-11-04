#if canImport(AppKit)
  import AppKit
#endif
#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
import OttoModels
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import OttoRPCContracts
import OttoSecurity
#if canImport(WebKit)
  import WebKit
#endif

public enum WebsiteAccountError: Error, LocalizedError {
  case unavailable, denied, signInRequired, expired, stalePage, busy
  public var errorDescription: String? {
    switch self {
    case .unavailable: "Website account unavailable. Open Website Accounts in Otto."
    case .denied: "This bot or destination is not authorised for that website account."
    case .signInRequired:
      "Sign in privately in Otto → Website Accounts, or Secure Sign-in on your paired phone. Never send passwords or verification codes in chat."
    case .expired: "This private sign-in request expired or belongs to another device."
    case .stalePage: "The page changed. Inspect it again before acting."
    case .busy: "The account is busy. Retry when its current action finishes."
    }
  }
}

public struct WebsiteAccountCommand: Codable, Sendable {
  public var action: String
  public var accountID: UUID?
  public var url: String?
  public var revision: UUID?
  public var elementID: String?
  public var text: String?
  public init(
    action: String, accountID: UUID? = nil, url: String? = nil, revision: UUID? = nil,
    elementID: String? = nil, text: String? = nil
  ) {
    self.action = action
    self.accountID = accountID
    self.url = url
    self.revision = revision
    self.elementID = elementID
    self.text = text
  }
}
public struct WebsiteAccountResult: Codable, Sendable {
  public var accounts: [AccountAccessBroker.Account] = []
  public var message: String = ""
  public var revision: UUID?
  public var elements: [SecureLoginElement] = []
  public var pageText: String?
}

/// The only executor for account cookie stores. It registers no generic BrowserRuntime renderer,
/// raw JS/debugging endpoint, screenshot handler, diagnostic bridge, or console observer.
@MainActor
public final class WebsiteAccountService: ObservableObject {
  @Published public private(set) var accounts: [AccountAccessBroker.Account] = []
  @Published public private(set) var notice = ""
  public let ownerID: UUID
  public let workspaceID: UUID
  private let broker: AccountAccessBroker
  var credentialVault = WebsiteCredentialVault()
  private var drivers: [UUID: WebsiteAccountDriver] = [:]
  #if DEBUG
    var fixtureURL: URL?
  #endif
  var now: () -> Date = { Date() }
  private var leases: [UUID: Lease] = [:]
  private struct Lease {
    var accountID: UUID
    var request: SecureLoginRequest
    var deviceID: UUID?
    var credential: WebsiteCredentialVault.Credential?
  }
  public var onOpenLogin: ((UUID) -> Void)?
  private var validBot: (UUID) -> Bool

  public init(
    workspacePath: String, broker: AccountAccessBroker = .shared,
    validBot: @escaping (UUID) -> Bool = { _ in false }
  ) {
    self.broker = broker
    self.validBot = validBot
    // Stable derivation input, not a display name: saved website credentials are scoped to
    // this owner ID, so the pre-rename "muse-" seed must not change.
    ownerID = Self.identifier("muse-local-owner:" + NSHomeDirectory())
    workspaceID = Self.identifier(
      URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().standardizedFileURL.path)
  }
  private static func identifier(_ value: String) -> UUID {
    let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
  public func refresh() async {
    do {
      accounts = try await broker.accounts(userID: ownerID, workspaceID: workspaceID)
      notice = ""
    } catch {
      accounts = []
      notice = "Website account storage is unavailable. No access was granted."
    }
  }
  @discardableResult public func create(origin: String, bots: AccountAccessBroker.BotScope)
    async throws -> UUID
  {
    let account = try await broker.createAccount(
      userID: ownerID, workspaceID: workspaceID, origin: origin, bots: bots, actions: [.browser])
    await refresh()
    return account.id
  }
  public func setGrant(accountID: UUID, bots: AccountAccessBroker.BotScope) async throws {
    invalidate(accountID)
    try await broker.updateGrant(
      accountID: accountID, userID: ownerID, workspaceID: workspaceID, bots: bots,
      actions: [.browser])
    await refresh()
  }
  public func disconnect(accountID: UUID) async throws {
    let account = try await owned(accountID)
    invalidate(accountID)
    try await broker.updateGrant(
      accountID: accountID, userID: ownerID, workspaceID: workspaceID, bots: .selected([]),
      actions: [])
    try await credentialVault.delete(
      owner: ownerID, workspace: workspaceID, account: accountID, origin: account.origin)
    // Remove policy before cookie cleanup: a cleanup failure cannot retain bot access.
    try await broker.disconnect(accountID: accountID, userID: ownerID, workspaceID: workspaceID)
    #if canImport(WebKit)
      let dataStore = WKWebsiteDataStore(forIdentifier: accountID)
      await dataStore.removeData(
        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    #endif
    await refresh()
  }
  private func invalidate(_ id: UUID) {
    leases = leases.filter { $0.value.accountID != id }
    drivers.removeValue(forKey: id)?.close()
  }
  private func owned(_ id: UUID) async throws -> AccountAccessBroker.Account {
    guard
      let account = try await broker.accounts(userID: ownerID, workspaceID: workspaceID).first(
        where: { $0.id == id })
    else { throw WebsiteAccountError.denied }
    return account
  }
  private func driver(_ account: AccountAccessBroker.Account) -> WebsiteAccountDriver {
    if let existing = drivers[account.id] { return existing }
    let value = WebsiteAccountDriver(accountID: account.id, origin: account.origin)
    #if DEBUG
      if let fixtureURL, fixtureURL.host == "127.0.0.1", fixtureURL.scheme == "http" {
        value.fixtureURL = fixtureURL
      }
    #endif
    drivers[account.id] = value
    return value
  }
  @discardableResult public func beginLogin(accountID: UUID, url: String? = nil) async throws
    -> SecureLoginRequest
  {
    let account = try await owned(accountID)
    let renderer = driver(account)
    guard !renderer.busy else { throw WebsiteAccountError.busy }
    renderer.locked = true
    renderer.busy = true
    defer { renderer.busy = false }
    try await broker.approveBrowserSession(
      accountID: accountID, userID: ownerID, workspaceID: workspaceID, approved: false)
    guard drivers[accountID] === renderer else { throw WebsiteAccountError.expired }
    leases = leases.filter { $0.value.accountID != accountID }
    let request = SecureLoginRequest(
      id: UUID(), origin: account.origin, expiresAt: now().addingTimeInterval(300))
    leases[request.id] = Lease(accountID: accountID, request: request)
    if let url {
      try await renderer.load(url)
    } else if renderer.webView.url == nil {
      try await renderer.load(account.origin)
    }
    guard drivers[accountID] === renderer, leases[request.id] != nil else {
      throw WebsiteAccountError.expired
    }
    await refresh()
    return request
  }
  public func showLogin(accountID: UUID) async {
    do {
      _ = try await beginLogin(accountID: accountID)
      onOpenLogin?(accountID)
    } catch { notice = error.localizedDescription }
  }
  #if canImport(WebKit)
  /// Native UI only. Never register this view with an agent browser/capture handler.
  public func humanWebView(accountID: UUID) -> WKWebView? {
    guard
      leases.values.contains(where: {
        $0.accountID == accountID && $0.request.expiresAt > now() && $0.deviceID == nil
      })
    else { return nil }
    return drivers[accountID]?.webView
  }
  #endif
  public func finishLogin(accountID: UUID) async throws {
    guard
      let lease = leases.values.first(where: { $0.accountID == accountID && $0.deviceID == nil })
    else { throw WebsiteAccountError.expired }
    try await finish(lease)
  }
  private func finish(_ lease: Lease) async throws {
    guard lease.request.expiresAt > now(), let renderer = drivers[lease.accountID], !renderer.busy
    else { throw WebsiteAccountError.expired }
    renderer.busy = true
    defer { renderer.busy = false }
    _ = try await owned(lease.accountID)
    try await renderer.requireNoSensitiveFields()
    guard drivers[lease.accountID] === renderer,
      leases[lease.request.id]?.deviceID == lease.deviceID,
      leases[lease.request.id] != nil, lease.request.expiresAt > now()
    else { throw WebsiteAccountError.expired }
    if var credential = leases[lease.request.id]?.credential {
      credential.successURL = renderer.webView.url?.absoluteString ?? ""
      let account = try await owned(lease.accountID)
      try await credentialVault.save(
        credential, owner: ownerID, workspace: workspaceID,
        account: account.id, origin: account.origin)
      guard drivers[lease.accountID] === renderer, leases[lease.request.id] != nil,
        lease.request.expiresAt > now()
      else { throw WebsiteAccountError.expired }
    }
    // The human confirms the resulting account. Do not infer identity from a cookie alone.
    try await broker.approveBrowserSession(
      accountID: lease.accountID, userID: ownerID, workspaceID: workspaceID, approved: true)
    guard drivers[lease.accountID] === renderer, leases[lease.request.id] != nil,
      lease.request.expiresAt > now()
    else {
      try? await broker.approveBrowserSession(
        accountID: lease.accountID, userID: ownerID, workspaceID: workspaceID, approved: false)
      throw WebsiteAccountError.expired
    }
    leases = leases.filter { $0.value.accountID != lease.accountID }
    renderer.locked = false
    renderer.webView.removeFromSuperview()
    await refresh()
  }
  public func cancelLogin(accountID: UUID) { invalidate(accountID) }

  public func perform(_ command: WebsiteAccountCommand, botID: UUID, runID: UUID) async throws
    -> WebsiteAccountResult
  {
    guard validBot(botID) else { throw WebsiteAccountError.denied }
    let identity = AccountAccessBroker.Identity(
      userID: ownerID, workspaceID: workspaceID, botID: botID, runID: runID, deviceID: ownerID)
    var result = WebsiteAccountResult()
    if command.action == "list" {
      for account in try await broker.accounts(userID: ownerID, workspaceID: workspaceID) {
        if let allowed = try? await broker.authorise(
          accountID: account.id, identity: identity, origin: account.origin, action: .browser)
        {
          result.accounts.append(allowed)
        }
      }
      return result
    }
    guard let id = command.accountID else { throw WebsiteAccountError.denied }
    let account = try await owned(id)
    _ = try await broker.authorise(
      accountID: id, identity: identity, origin: account.origin, action: .browser)
    if command.action == "request_login" {
      if !leases.values.contains(where: { $0.accountID == id && $0.request.expiresAt > now() }) {
        _ = try await beginLogin(accountID: id, url: command.url)
      }
      onOpenLogin?(id)
      result.message =
        "Private sign-in is open in Otto. Enter credentials there or in Secure Sign-in on the paired mobile app, never in chat."
      return result
    }
    let renderer = driver(account)
    guard account.browserSessionApproved == true, !renderer.locked,
      !leases.values.contains(where: { $0.accountID == id })
    else { throw WebsiteAccountError.signInRequired }
    guard !renderer.busy else { throw WebsiteAccountError.busy }
    renderer.busy = true
    defer { renderer.busy = false }
    do {
      if command.action == "open" {
        try await renderer.load(command.url ?? account.origin)
      } else if renderer.webView.url == nil {
        try await renderer.load(account.origin)
      }
      try await renderer.requireNoSensitiveFields()
      if ["click", "type"].contains(command.action) {
        try await renderer.act(
          kind: command.action, revision: command.revision, elementID: command.elementID,
          value: command.text, human: false)
      } else if !["open", "inspect"].contains(command.action) {
        throw WebsiteAccountError.denied
      }
      let snapshot = try await renderer.inspect(human: false)
      // Recheck after suspension: revocation closes the renderer and invalidates in-flight output.
      guard drivers[id] === renderer, validBot(botID), !renderer.locked else {
        throw WebsiteAccountError.denied
      }
      _ = try await broker.authorise(
        accountID: id, identity: identity, origin: account.origin, action: .browser)
      result.revision = snapshot.revision
      result.elements = snapshot.elements
      result.pageText = snapshot.text
      result.message = "Account page inspected."
      return result
    } catch WebsiteAccountError.signInRequired {
      renderer.locked = true
      throw WebsiteAccountError.signInRequired
    } catch { throw (error as? WebsiteAccountError) ?? WebsiteAccountError.unavailable }
  }

  /// Keeps the original tool call pending; completion continues the same run, never a replay.
  public func waitForLogin(accountID: UUID, botID: UUID, runID: UUID) async throws
    -> WebsiteAccountResult
  {
    guard let lease = leases.values.first(where: { $0.accountID == accountID }),
      let renderer = drivers[accountID]
    else { throw WebsiteAccountError.expired }
    do {
      while true {
        try Task.checkCancellation()
        guard validBot(botID), drivers[accountID] === renderer, lease.request.expiresAt > now()
        else { throw WebsiteAccountError.expired }
        if leases[lease.request.id] == nil {
          guard !renderer.locked else { throw WebsiteAccountError.expired }
          if !renderer.busy { break }
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      var result = try await perform(
        WebsiteAccountCommand(action: "inspect", accountID: accountID), botID: botID, runID: runID)
      result.accounts = [try await owned(accountID)]
      result.message =
        "Private sign-in completed. Continue the user's original task using this account."
      return result
    } catch {
      if leases[lease.request.id] != nil { invalidate(accountID) }
      throw (error as? WebsiteAccountError) ?? WebsiteAccountError.expired
    }
  }

  public static func originForLogin(_ value: String) throws -> String {
    guard var parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host,
      !host.isEmpty, parts.user == nil, parts.password == nil
    else { throw WebsiteAccountError.denied }
    parts.host = host.lowercased()
    if parts.port == 443 { parts.port = nil }
    parts.path = ""
    parts.query = nil
    parts.fragment = nil
    guard let origin = parts.url?.absoluteString else { throw WebsiteAccountError.denied }
    return origin
  }

  /// Resolve the exact live target before displaying a human approval. Revalidated on execution.
  public func clickApproval(_ command: WebsiteAccountCommand, botID: UUID, runID: UUID) async throws
    -> String
  {
    guard command.action == "click", let id = command.accountID, validBot(botID) else {
      throw WebsiteAccountError.denied
    }
    let account = try await owned(id)
    let identity = AccountAccessBroker.Identity(
      userID: ownerID, workspaceID: workspaceID, botID: botID, runID: runID, deviceID: ownerID)
    _ = try await broker.authorise(
      accountID: id, identity: identity, origin: account.origin, action: .browser)
    guard account.browserSessionApproved == true, let renderer = drivers[id], !renderer.locked,
      !renderer.busy
    else { throw WebsiteAccountError.denied }
    let label = try await renderer.targetLabel(
      revision: command.revision, elementID: command.elementID)
    return
      "Website: \(account.origin)\nAccount: \(id.uuidString)\nClick once: \(label)\nThe page may submit or change information."
  }

  /// Called only by the dedicated paired-device transport; no secret-bearing event is emitted.
  func trySavedLogin(accountID: UUID, botID: UUID, runID: UUID, url: String?) async throws -> Bool {
    guard validBot(botID), !leases.values.contains(where: { $0.accountID == accountID }) else {
      return false
    }
    let account = try await owned(accountID)
    let identity = AccountAccessBroker.Identity(
      userID: ownerID, workspaceID: workspaceID,
      botID: botID, runID: runID, deviceID: ownerID)
    _ = try await broker.authorise(
      accountID: accountID, identity: identity, origin: account.origin, action: .browser)
    guard
      let credential = try await credentialVault.load(
        owner: ownerID, workspace: workspaceID,
        account: accountID, origin: account.origin), !credential.successURL.isEmpty
    else { return false }
    let renderer = driver(account)
    guard !renderer.busy else { throw WebsiteAccountError.busy }
    renderer.busy = true
    renderer.locked = true
    defer { renderer.busy = false }
    try await renderer.load(url ?? account.origin)
    // Sites whose login and success share a URL need explicit phone confirmation.
    guard renderer.webView.url?.absoluteString != credential.successURL,
      try await renderer.fillSavedCredential(credential)
    else { return false }
    for _ in 0..<200 {
      try Task.checkCancellation()
      try await Task.sleep(for: .milliseconds(50))
      guard drivers[accountID] === renderer else { throw WebsiteAccountError.denied }
      if !renderer.webView.isLoading, renderer.webView.url?.absoluteString == credential.successURL
      {
        break
      }
    }
    guard renderer.webView.url?.absoluteString == credential.successURL,
      (try? await renderer.requireNoSensitiveFields()) != nil
    else { return false }
    _ = try await broker.authorise(
      accountID: accountID, identity: identity, origin: account.origin, action: .browser)
    guard validBot(botID), drivers[accountID] === renderer else { throw WebsiteAccountError.denied }
    try await broker.approveBrowserSession(
      accountID: accountID, userID: ownerID, workspaceID: workspaceID, approved: true)
    guard validBot(botID), drivers[accountID] === renderer else { throw WebsiteAccountError.denied }
    renderer.locked = false
    return true
  }

  func stageRememberedInput(_ input: SecureLoginInput, deviceID: UUID, remember: Bool) async throws
  {
    guard let id = input.requestID, var lease = leases[id], lease.deviceID == deviceID,
      lease.request.expiresAt > now(), let renderer = drivers[lease.accountID], !renderer.busy
    else { throw WebsiteAccountError.expired }
    if !remember {
      lease.credential = nil
      leases[id] = lease
      return
    }
    renderer.busy = true
    defer { renderer.busy = false }
    if let candidate = try await renderer.credentialCandidate(input) {
      guard leases[id]?.deviceID == deviceID, leases[id]!.request.expiresAt > now(),
        drivers[lease.accountID] === renderer
      else {
        throw WebsiteAccountError.expired
      }
      leases[id]?.credential = candidate
    }
  }

  public func secureInput(_ input: SecureLoginInput, deviceID: UUID) async throws
    -> SecureLoginOutput
  {
    for lease in leases.values.filter({ $0.request.expiresAt <= now() }) {
      invalidate(lease.accountID)
    }
    if input.action == .list {
      return SecureLoginOutput(
        requests: leases.values.map(\.request).sorted { $0.expiresAt < $1.expiresAt })
    }
    guard let id = input.requestID, var lease = leases[id], lease.request.expiresAt > now(),
      lease.deviceID == nil || lease.deviceID == deviceID,
      let renderer = drivers[lease.accountID], renderer.locked, !renderer.busy
    else { throw WebsiteAccountError.expired }
    lease.deviceID = deviceID
    leases[id] = lease
    renderer.busy = true
    do { _ = try await owned(lease.accountID) } catch {
      renderer.busy = false
      throw error
    }
    renderer.busy = false
    guard drivers[lease.accountID] === renderer, leases[id]?.deviceID == deviceID,
      lease.request.expiresAt > now()
    else { throw WebsiteAccountError.expired }
    // Remote ownership detaches the private native view so input cannot race another surface.
    renderer.webView.removeFromSuperview()
    if input.action == .cancel {
      cancelLogin(accountID: lease.accountID)
      return SecureLoginOutput(message: "Sign-in cancelled")
    }
    if input.action == .finish {
      try await finish(lease)
      return SecureLoginOutput(message: "Signed-in session ready")
    }
    renderer.busy = true
    defer { renderer.busy = false }
    if input.action == .fill || input.action == .click {
      try await renderer.act(
        kind: input.action == .fill ? "type" : "click", revision: input.revision,
        elementID: input.elementID, value: input.value, human: true, fields: input.fields ?? [:])
    }
    let snapshot = try await renderer.inspect(human: true)
    guard drivers[lease.accountID] === renderer, leases[id]?.deviceID == deviceID,
      lease.request.expiresAt > now()
    else { throw WebsiteAccountError.expired }
    return SecureLoginOutput(
      requests: [lease.request], revision: snapshot.revision, elements: snapshot.elements,
      message: "Private sign-in · " + lease.request.origin)
  }
}

#if canImport(WebKit)
@MainActor
private final class WebsiteAccountDriver: NSObject, WKNavigationDelegate {
  let webView: WKWebView
  let origin: String
  var locked = false
  var busy = false
  private var revision: UUID?
  private var closed = false
  private var navigationFailed = false
  #if DEBUG
    var fixtureURL: URL?
  #endif
  init(accountID: UUID, origin: String) {
    self.origin = origin
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: accountID)
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: configuration)
    super.init()
    webView.navigationDelegate = self
    webView.isInspectable = false
  }
  func close() {
    closed = true
    locked = true
    webView.stopLoading()
    webView.removeFromSuperview()
    webView.navigationDelegate = nil
    webView.loadHTMLString("", baseURL: nil)
  }
  func allowed(_ url: URL?) -> Bool {
    #if DEBUG
      if let fixtureURL, let url, url.scheme == fixtureURL.scheme, url.host == fixtureURL.host,
        url.port == fixtureURL.port
      {
        return true
      }
    #endif
    guard let url, url.scheme == "https", url.user == nil, url.password == nil,
      let target = URL(string: origin)
    else { return false }
    return url.host?.lowercased() == target.host?.lowercased()
      && (url.port ?? 443) == (target.port ?? 443)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    let permit =
      !closed && allowed(navigationAction.request.url) && navigationAction.targetFrame != nil
    if !permit && navigationAction.targetFrame?.isMainFrame != false { navigationFailed = true }
    decisionHandler(permit ? .allow : .cancel)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { navigationFailed = true }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    navigationFailed = true
  }
  func load(_ urlString: String) async throws {
    var destination = urlString
    #if DEBUG
      if let fixtureURL, urlString.hasPrefix(origin) {
        destination = fixtureURL.absoluteString + String(urlString.dropFirst(origin.count))
      }
    #endif
    navigationFailed = false
    guard !closed, let url = URL(string: destination), allowed(url) else {
      throw WebsiteAccountError.denied
    }
    revision = nil
    webView.load(URLRequest(url: url))
    #if DEBUG
      // Test fixtures load many WebKit views in parallel; on a loaded CI runner starting the web
      // content process alone can exceed the ten seconds allowed for a real site.
      let attempts = fixtureURL == nil ? 200 : 600
    #else
      let attempts = 200
    #endif
    for _ in 0..<attempts {
      try await Task.sleep(for: .milliseconds(50))
      guard !closed else { throw WebsiteAccountError.denied }
      if webView.url != nil && !webView.isLoading {
        guard !navigationFailed, allowed(webView.url) else { throw WebsiteAccountError.denied }
        return
      }
    }
    throw WebsiteAccountError.unavailable
  }
  private func js(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    guard !closed, !navigationFailed, allowed(webView.url) else { throw WebsiteAccountError.denied }
    do {
      return try await webView.callAsyncJavaScript(
        script, arguments: arguments, in: nil, contentWorld: .defaultClient)
    } catch { throw WebsiteAccountError.unavailable }
  }
  func requireNoSensitiveFields() async throws {
    let found =
      try await js(
        WebsiteAccountScripts.sensitiveFields
      ) as? Bool
    guard found == false else { throw WebsiteAccountError.signInRequired }
  }
  struct Snapshot {
    var revision: UUID
    var elements: [SecureLoginElement]
    var text: String?
  }
  func inspect(human: Bool) async throws -> Snapshot {
    if !human { try await requireNoSensitiveFields() }
    let current = UUID()
    let object =
      try await js(
        WebsiteAccountScripts.inspect, ["revision": current.uuidString, "human": human]) as? [String: Any]
    guard let items = object?["elements"] as? [[String: Any]] else {
      throw WebsiteAccountError.unavailable
    }
    revision = current
    return Snapshot(
      revision: current,
      elements: items.compactMap { item in
        guard let id = item["id"] as? String, let label = item["label"] as? String,
          let kind = item["kind"] as? String
        else { return nil }
        return SecureLoginElement(
          id: id, label: label, kind: kind, purpose: item["purpose"] as? String)
      }, text: human ? nil : object?["text"] as? String)
  }
  func fillSavedCredential(_ credential: WebsiteCredentialVault.Credential) async throws -> Bool {
    let result =
      try await js(
        WebsiteAccountScripts.credentialFields + WebsiteAccountScripts.fillSuffix,
        [
          "expected": credential.signature, "username": credential.username,
          "password": credential.password,
        ]) as? Bool
    return result == true
  }

  func credentialCandidate(_ input: SecureLoginInput) async throws -> WebsiteCredentialVault
    .Credential?
  {
    guard let revision = input.revision, revision == self.revision else {
      throw WebsiteAccountError.stalePage
    }
    let result =
      try await js(
        WebsiteAccountScripts.credentialFields + WebsiteAccountScripts.candidateSuffix, ["revision": revision.uuidString, "fields": input.fields ?? [:]])
      as? [String: String]
    guard let result, let signature = result["signature"], let username = result["username"],
      let password = result["password"]
    else { return nil }
    return WebsiteCredentialVault.Credential(
      signature: signature, username: username, password: password)
  }

  func targetLabel(revision expected: UUID?, elementID: String?) async throws -> String {
    guard let expected, revision == expected, let elementID, Int(elementID) != nil else {
      throw WebsiteAccountError.stalePage
    }
    try await requireNoSensitiveFields()
    let label =
      try await js(
        WebsiteAccountScripts.targetLabel, ["revision": expected.uuidString, "id": elementID]) as? String
    guard let label else { throw WebsiteAccountError.stalePage }
    return label
  }
  func act(
    kind: String, revision expected: UUID?, elementID: String?, value: String?, human: Bool,
    fields: [String: String] = [:]
  )
    async throws
  {
    guard let expected, revision == expected, let elementID, Int(elementID) != nil,
      (value?.utf8.count ?? 0) <= 16_384
    else { throw WebsiteAccountError.stalePage }
    guard fields.count <= 200, fields.values.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
      human || fields.isEmpty
    else { throw WebsiteAccountError.denied }
    if !human { try await requireNoSensitiveFields() }
    revision = nil  // Every input is single-use, including failures and uncertain navigation.
    let okay =
      try await js(
        WebsiteAccountScripts.act,
        [
          "revision": expected.uuidString, "id": elementID, "kind": kind, "value": value ?? "",
          "human": human, "fields": fields,
        ]) as? Bool
    guard okay == true else { throw WebsiteAccountError.stalePage }
    for _ in 0..<200 {
      try await Task.sleep(for: .milliseconds(50))
      guard !closed else { throw WebsiteAccountError.denied }
      if !webView.isLoading { return }
    }
    throw WebsiteAccountError.unavailable
  }
}
#else
  /// Linux and Windows: the same driver logic as the Mac's WebKit one (origin rule, load and
  /// settle loop, password-field guard, single-use revisions, the shared WebsiteAccountScripts),
  /// with the page in a private Chromium session the host renders (Otto Desktop).
  @MainActor
  private final class WebsiteAccountDriver {
    /// The page facts the service reads, as last reported by the renderer.
    @MainActor
    final class Page {
      fileprivate weak var driver: WebsiteAccountDriver?
      var url: URL? { driver?.state?.url.flatMap(URL.init(string:)) }
      var isLoading: Bool { driver?.state?.isLoading ?? false }
      func removeFromSuperview() { driver?.hide() }
    }
    let webView = Page()
    let accountID: UUID
    let origin: String
    var locked = false
    var busy = false
    private var revision: UUID?
    private var closed = false
    private var opened = false
    #if DEBUG
      var fixtureURL: URL?
    #endif
    struct Snapshot {
      var revision: UUID
      var elements: [SecureLoginElement]
      var text: String?
    }

    init(accountID: UUID, origin: String) {
      self.accountID = accountID
      self.origin = origin
      webView.driver = self
    }

    private var renderer: (any WebsiteAccountRenderer)? { WebsiteAccountRendering.renderer }
    fileprivate var state: WebsiteAccountPageState? { renderer?.state(accountID: accountID) }
    private var navigationFailed: Bool { state?.failed ?? false }

    func close() {
      closed = true
      locked = true
      let id = accountID
      if let renderer { Task { await renderer.close(accountID: id) } }
    }

    fileprivate func hide() {
      let id = accountID
      if let renderer { Task { await renderer.hide(accountID: id) } }
    }

    func allowed(_ url: URL?) -> Bool {
      #if DEBUG
        if let fixtureURL, let url, url.scheme == fixtureURL.scheme, url.host == fixtureURL.host,
          url.port == fixtureURL.port
        {
          return true
        }
      #endif
      guard let url, url.scheme == "https", url.user == nil, url.password == nil,
        let target = URL(string: origin)
      else { return false }
      return url.host?.lowercased() == target.host?.lowercased()
        && (url.port ?? 443) == (target.port ?? 443)
    }

    private func ensureOpen() async throws -> any WebsiteAccountRenderer {
      guard let renderer, !closed else { throw WebsiteAccountError.unavailable }
      if !opened {
        var allowedOrigin = origin
        #if DEBUG
          if let fixtureURL { allowedOrigin = fixtureURL.absoluteString }
        #endif
        try await renderer.open(accountID: accountID, origin: origin, fixtureOrigin: allowedOrigin)
        opened = true
      }
      return renderer
    }

    func load(_ urlString: String) async throws {
      var destination = urlString
      #if DEBUG
        if let fixtureURL, urlString.hasPrefix(origin) {
          destination = fixtureURL.absoluteString + String(urlString.dropFirst(origin.count))
        }
      #endif
      guard !closed, let url = URL(string: destination), allowed(url) else {
        throw WebsiteAccountError.denied
      }
      let renderer = try await ensureOpen()
      revision = nil
      try await renderer.load(accountID: accountID, url: url.absoluteString)
      for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(50))
        guard !closed else { throw WebsiteAccountError.denied }
        if webView.url != nil && !webView.isLoading {
          guard !navigationFailed, allowed(webView.url) else { throw WebsiteAccountError.denied }
          return
        }
      }
      throw WebsiteAccountError.unavailable
    }

    private func js(_ script: String, _ arguments: [String: OpaqueCodableValue] = [:]) async throws
      -> OpaqueCodableValue
    {
      guard !closed, !navigationFailed, allowed(webView.url), let renderer else {
        throw WebsiteAccountError.denied
      }
      do {
        return try await renderer.evaluate(accountID: accountID, body: script, arguments: arguments)
      } catch { throw WebsiteAccountError.unavailable }
    }

    func requireNoSensitiveFields() async throws {
      let found = try await js(WebsiteAccountScripts.sensitiveFields)
      guard case .bool(false) = found else { throw WebsiteAccountError.signInRequired }
    }

    func inspect(human: Bool) async throws -> Snapshot {
      if !human { try await requireNoSensitiveFields() }
      let current = UUID()
      let object = try await js(
        WebsiteAccountScripts.inspect,
        ["revision": .string(current.uuidString), "human": .bool(human)])
      guard case .object(let fields) = object, case .array(let items)? = fields["elements"] else {
        throw WebsiteAccountError.unavailable
      }
      revision = current
      return Snapshot(
        revision: current,
        elements: items.compactMap { item in
          guard case .object(let entry) = item, case .string(let id)? = entry["id"],
            case .string(let label)? = entry["label"], case .string(let kind)? = entry["kind"]
          else { return nil }
          let purpose: String? = if case .string(let value)? = entry["purpose"] { value } else { nil }
          return SecureLoginElement(id: id, label: label, kind: kind, purpose: purpose)
        },
        text: human ? nil : { if case .string(let text)? = fields["text"] { text } else { nil } }())
    }

    func fillSavedCredential(_ credential: WebsiteCredentialVault.Credential) async throws -> Bool {
      let result = try await js(
        WebsiteAccountScripts.credentialFields + WebsiteAccountScripts.fillSuffix,
        [
          "expected": .string(credential.signature), "username": .string(credential.username),
          "password": .string(credential.password),
        ])
      return result == .bool(true)
    }

    func credentialCandidate(_ input: SecureLoginInput) async throws -> WebsiteCredentialVault
      .Credential?
    {
      guard let revision = input.revision, revision == self.revision else {
        throw WebsiteAccountError.stalePage
      }
      let result = try await js(
        WebsiteAccountScripts.credentialFields + WebsiteAccountScripts.candidateSuffix,
        [
          "revision": .string(revision.uuidString),
          "fields": .object((input.fields ?? [:]).mapValues { .string($0) }),
        ])
      guard case .object(let found) = result, case .string(let signature)? = found["signature"],
        case .string(let username)? = found["username"],
        case .string(let password)? = found["password"]
      else { return nil }
      return WebsiteCredentialVault.Credential(
        signature: signature, username: username, password: password)
    }

    func targetLabel(revision expected: UUID?, elementID: String?) async throws -> String {
      guard let expected, revision == expected, let elementID, Int(elementID) != nil else {
        throw WebsiteAccountError.stalePage
      }
      try await requireNoSensitiveFields()
      let label = try await js(
        WebsiteAccountScripts.targetLabel,
        ["revision": .string(expected.uuidString), "id": .string(elementID)])
      guard case .string(let text) = label else { throw WebsiteAccountError.stalePage }
      return text
    }

    func act(
      kind: String, revision expected: UUID?, elementID: String?, value: String?, human: Bool,
      fields: [String: String] = [:]
    ) async throws {
      guard let expected, revision == expected, let elementID, Int(elementID) != nil,
        (value?.utf8.count ?? 0) <= 16_384
      else { throw WebsiteAccountError.stalePage }
      guard fields.count <= 200, fields.values.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
        human || fields.isEmpty
      else { throw WebsiteAccountError.denied }
      if !human { try await requireNoSensitiveFields() }
      revision = nil  // Every input is single-use, including failures and uncertain navigation.
      let okay = try await js(
        WebsiteAccountScripts.act,
        [
          "revision": .string(expected.uuidString), "id": .string(elementID),
          "kind": .string(kind), "value": .string(value ?? ""), "human": .bool(human),
          "fields": .object(fields.mapValues { .string($0) }),
        ])
      guard okay == .bool(true) else { throw WebsiteAccountError.stalePage }
      for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(50))
        guard !closed else { throw WebsiteAccountError.denied }
        if !webView.isLoading { return }
      }
      throw WebsiteAccountError.unavailable
    }
  }
#endif

/// What a website account's private page last reported to the host renderer.
public struct WebsiteAccountPageState: Sendable, Equatable {
  public var url: String?
  public var isLoading: Bool
  public var failed: Bool

  public init(url: String?, isLoading: Bool, failed: Bool) {
    self.url = url
    self.isLoading = isLoading
    self.failed = failed
  }
}

/// Renders website accounts' private pages for hosts without WebKit (Otto Desktop's engine).
/// Each account is its own browser session, kept to its origin; scripts run in an isolated world.
public protocol WebsiteAccountRenderer: Sendable {
  func open(accountID: UUID, origin: String, fixtureOrigin: String) async throws
  func load(accountID: UUID, url: String) async throws
  /// The latest reported state, without waiting (the driver polls it like WKWebView properties).
  func state(accountID: UUID) -> WebsiteAccountPageState?
  /// Runs a function `body` with `arguments` as named parameters and returns its JSON result.
  func evaluate(accountID: UUID, body: String, arguments: [String: OpaqueCodableValue]) async throws
    -> OpaqueCodableValue
  func hide(accountID: UUID) async
  func close(accountID: UUID) async
}

public enum WebsiteAccountRendering {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var installed: (any WebsiteAccountRenderer)?

  public static func install(_ renderer: any WebsiteAccountRenderer) {
    lock.withLock { installed = renderer }
  }

  public static var renderer: (any WebsiteAccountRenderer)? { lock.withLock { installed } }
}

import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

private actor GoogleRequests {
  var requests: [URLRequest] = []
  var status = 200
  var response = "{}"
  func set(_ response: String, status: Int = 200) {
    self.response = response
    self.status = status
  }
  func call(_ request: URLRequest) -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (
      Data(response.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: status,
        httpVersion: nil, headerFields: nil)!
    )
  }
  func count() -> Int { requests.count }
  func last() -> URLRequest? { requests.last }
}

private actor FailingDeleteStore: SecretStore {
  private let backing = InMemorySecretStore()
  private var fail = true
  func set(_ value: String, for key: String) async throws { try await backing.set(value, for: key) }
  func value(for key: String) async throws -> String? { try await backing.value(for: key) }
  func delete(_ key: String) async throws {
    if fail { throw SecretStoreError.storageUnavailable("Fixture") }
    try await backing.delete(key)
  }
  func allowDelete() { fail = false }
}

private actor RefreshBarrier {
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  private var started = false
  private var tokenCalls = 0
  func call(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
    var body = "{}"
    if request.url?.path == "/token" {
      tokenCalls += 1
      started = true
      observer?.resume()
      observer = nil
      await withCheckedContinuation { releaseContinuation = $0 }
      body = "{\"access_token\":\"\(UUID())\",\"expires_in\":3600}"
    }
    return (
      Data(body.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: nil)!
    )
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { observer = $0 }
  }
  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
  func count() -> Int { tokenCalls }
}

@MainActor
@Suite("Shared app connections", .serialized)
struct AppConnectionsTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-apps-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  private func account(scopes: Set<String> = [AppConnectionsStore.readScope]) -> GmailConnection {
    GmailConnection(
      id: UUID(), email: "fixture@example.com", scopes: scopes,
      needsReconnect: false, shared: true, createdAt: .now)
  }
  private func credential(expired: Bool = false) -> GoogleCredential {
    GoogleCredential(
      accessToken: UUID().uuidString, refreshToken: UUID().uuidString,
      expiresAt: .now.addingTimeInterval(expired ? -100 : 3600),
      clientID: "fixture.apps.googleusercontent.com")
  }

  @Test("One connection serves every shared-app provider and denies Hermes and unbound callers")
  func sharedProviders() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = GoogleRequests()
    await requests.set("{\"messages\": []}")
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await requests.call($0) }))
    try await apps.install(account(), credential: credential())
    let canvas = OttoCanvas(name: "Connection tests")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let services = ApplicationServices(
      store: store, supervisor: supervisor,
      secrets: InMemorySecretStore(), appConnections: apps, workspacePath: root.path)
    try await services.registerAppConnectionTools()
    var nodes: [UUID] = []
    do {
      for provider in Array(SharedAppProviders.supported) + [.hermes, .openAI] {
        let id = try #require(
          store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs
            .first)
        // Gmail reaches only bots the Mac owner allowed for it.
        let profileID = try services.saveAgentProfile(
          AgentProfile(name: "Fixture \(UUID())", instructions: "Test", provider: provider)
        ).id
        try services.connectorAccess.setAllowed(true, profileID: profileID, for: .gmail)
        var definition = AgentDefinition(
          provider: provider,
          workingDirectory: root.path, launchCommand: "fixture",
          permissionMode: "workspaceWrite")
        definition.profileID = profileID
        store.dispatch(.setAgentDefinition(id: id, definition: definition))
        _ = try await supervisor.spawn(
          provider: provider,
          specification: ProcessLaunchSpec(
            executable: "/bin/cat", arguments: [], workingDirectory: root.path), id: id)
        nodes.append(id)
        let context = ToolContext(
          actorID: "fixture", scopes: [.agentRead], source: .agent, sourceNodeID: id)
        let names = await services.registry.definitions(for: context).map(\.name)
        if !SharedAppProviders.supported.contains(provider) {
          #expect(!names.contains("gmail.search"))
          await #expect(throws: ToolRegistryError.self) {
            try await services.registry.call(
              name: "gmail.search", input: .object(["query": .string("in:inbox")]), context: context
            )
          }
        } else {
          #expect(names.contains("gmail.search"))
          let result = try await services.registry.call(
            name: "gmail.search",
            input: .object(["query": .string("in:inbox")]), context: context)
          #expect(result["messages"] == .array([]))
          #expect(!names.contains("gmail.send"))
        }
      }
      #expect(await requests.count() == SharedAppProviders.supported.count)
      let unbound = ToolContext(actorID: "fixture", scopes: [.agentRead], source: .agent)
      #expect(await services.registry.definitions(for: unbound).isEmpty)
    } catch {
      for id in nodes { try? await supervisor.stop(agentID: id) }
      throw error
    }
    for id in nodes { try await supervisor.stop(agentID: id) }
  }

  @Test("Workspace metadata persists accounts but never OAuth tokens")
  func securePersistence() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = InMemorySecretStore()
    let apps = AppConnectionsStore(workspacePath: root.path, secrets: secrets, http: GoogleHTTP())
    let account = account()
    let credential = credential()
    try await apps.install(account, credential: credential)
    let metadata = try String(
      contentsOf: root.appending(path: ".otto/app-connections.json"), encoding: .utf8)
    #expect(metadata.contains(account.email))
    #expect(!metadata.contains(credential.accessToken))
    #expect(!metadata.contains(credential.refreshToken))
    let restored = AppConnectionsStore(
      workspacePath: root.path, secrets: secrets, http: GoogleHTTP())
    #expect(restored.accounts.first?.id == account.id)
    let other = AppConnectionsStore(
      workspacePath: root.appending(path: "other").path, secrets: secrets, http: GoogleHTTP())
    #expect(other.credentialKey(account.id) != apps.credentialKey(account.id))
  }

  @Test(
    "Disconnect removes cached authority and secure credentials even when Google revocation fails")
  func disconnect() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = GoogleRequests()
    await requests.set("{}", status: 503)
    let secrets = InMemorySecretStore()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: secrets,
      http: GoogleHTTP(execute: { await requests.call($0) }))
    let account = account()
    try await apps.install(account, credential: credential())
    let key = apps.credentialKey(account.id)
    try await apps.disconnect(accountID: account.id)
    #expect(apps.accounts.isEmpty)
    #expect(try await secrets.value(for: key) == nil)
    #expect(apps.error?.contains("revocation could not be confirmed") == true)
    await #expect(throws: AppConnectionError.unavailable) {
      try await apps.request(account: account, path: "messages")
    }
    #expect(await requests.count() == 1)
  }

  @Test("Failed secure cleanup leaves a paused account that can retry disconnect")
  func failedSecureCleanup() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = FailingDeleteStore()
    let requests = GoogleRequests()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: secrets,
      http: GoogleHTTP(execute: { await requests.call($0) }))
    let account = account()
    try await apps.install(account, credential: credential())
    await #expect(throws: SecretStoreError.self) {
      try await apps.disconnect(accountID: account.id)
    }
    #expect(apps.accounts.first?.shared == false)
    #expect(!apps.available(provider: .claudeCode))
    await #expect(throws: AppConnectionError.unavailable) {
      try await apps.request(account: account, path: "messages")
    }
    await secrets.allowDelete()
    try await apps.disconnect(accountID: account.id)
    #expect(apps.accounts.isEmpty)
  }

  @Test(
    "Expired tokens refresh once and invalid grants require reconnect without leaking Google error bodies"
  )
  func refresh() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = GoogleRequests()
    await requests.set(
      "{\"error\":\"invalid_grant\",\"error_description\":\"sensitive fixture\"}", status: 400)
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await requests.call($0) }))
    let account = account()
    try await apps.install(account, credential: credential(expired: true))
    await #expect(throws: AppConnectionError.reconnectRequired) {
      try await apps.request(account: account, path: "messages")
    }
    #expect(apps.accounts.first?.needsReconnect == true)
    #expect(!apps.available(provider: .codex))
    #expect(await requests.count() == 1)
    let last = await requests.last()
    #expect(last?.url?.host == "oauth2.googleapis.com")
    #expect(
      AppConnectionError.reconnectRequired.localizedDescription.contains("sensitive") == false)
  }

  @Test("Pausing shared access denies calls and ambiguous accounts require explicit routing")
  func accountRouting() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(), http: GoogleHTTP())
    let first = account()
    let second = account()
    try await apps.install(first, credential: credential())
    try await apps.install(second, credential: credential())
    #expect(throws: ToolRegistryError.self) {
      try apps.resolve(nil, scope: AppConnectionsStore.readScope)
    }
    #expect(try apps.resolve(second.id, scope: AppConnectionsStore.readScope).id == second.id)
    try apps.setShared(false, accountID: second.id)
    #expect(throws: AppConnectionError.unavailable) {
      try apps.resolve(second.id, scope: AppConnectionsStore.readScope)
    }
    await #expect(throws: AppConnectionError.unavailable) {
      try await apps.request(account: second, path: "messages")
    }
  }

  @Test("Disconnect during refresh cannot resurrect credentials or perform a Gmail request")
  func disconnectDuringRefresh() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let barrier = RefreshBarrier()
    let secrets = InMemorySecretStore()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: secrets,
      http: GoogleHTTP(execute: { await barrier.call($0) }))
    let account = account()
    try await apps.install(account, credential: credential(expired: true))
    let key = apps.credentialKey(account.id)
    let request = Task { try await apps.request(account: account, path: "messages") }
    await barrier.waitUntilStarted()
    try await apps.disconnect(accountID: account.id)
    await barrier.release()
    await #expect(throws: AppConnectionError.unavailable) { try await request.value }
    #expect(try await secrets.value(for: key) == nil)
    #expect(apps.accounts.isEmpty)
  }

  @Test("Concurrent reads share refresh work and subsequent reads use the renewed credential")
  func successfulRefresh() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let barrier = RefreshBarrier()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await barrier.call($0) }))
    let account = account()
    try await apps.install(account, credential: credential(expired: true))
    let first = Task { try await apps.request(account: account, path: "messages") }
    await barrier.waitUntilStarted()
    let second = Task { try await apps.request(account: account, path: "messages") }
    await Task.yield()
    await barrier.release()
    #expect(try await first.value == .object([:]))
    #expect(try await second.value == .object([:]))
    #expect(try await apps.request(account: account, path: "messages") == .object([:]))
    #expect(await barrier.count() == 1)
  }

  @Test("Sending requires exact-call confirmation and read-only agents cannot discover write tools")
  func sendGate() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let requests = GoogleRequests()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await requests.call($0) }))
    let account = account(scopes: [
      AppConnectionsStore.readScope, AppConnectionsStore.sendScope,
      AppConnectionsStore.composeScope,
    ])
    try await apps.install(account, credential: credential())
    let canvas = OttoCanvas(name: "Sending tests")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let services = ApplicationServices(
      store: store, supervisor: supervisor,
      secrets: InMemorySecretStore(), appConnections: apps, workspacePath: root.path)
    try await services.registerAppConnectionTools()
    let id = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    var definition = AgentDefinition(
      provider: .codex, workingDirectory: root.path,
      launchCommand: "fixture", permissionMode: "workspaceWrite")
    let profileID = try services.saveAgentProfile(
      AgentProfile(name: "Fixture", instructions: "Test", provider: .codex)
    ).id
    definition.profileID = profileID
    try services.connectorAccess.setAllowed(true, profileID: profileID, for: .gmail)
    store.dispatch(.setAgentDefinition(id: id, definition: definition))
    _ = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/cat", arguments: [], workingDirectory: root.path), id: id)
    do {
      let context = ToolContext(
        actorID: "fixture", scopes: [.agentRead], source: .agent, sourceNodeID: id)
      let names = await services.registry.definitions(for: context).map(\.name)
      #expect(names.contains("gmail.send"))
      await #expect(throws: ToolRegistryError.confirmationRequired("gmail.send")) {
        try await services.registry.call(
          name: "gmail.send",
          input: .object([
            "to": .string("fixture@example.com"), "subject": .string("Fixture"),
            "body": .string("Fixture"),
          ]), context: context)
      }
      #expect(await requests.count() == 0)
      var readOnly = definition
      readOnly.permissionMode = "readOnly"
      store.dispatch(.setAgentDefinition(id: id, definition: readOnly))
      let readNames = await services.registry.definitions(for: context).map(\.name)
      #expect(!readNames.contains("gmail.send"))
      #expect(!readNames.contains("gmail.draft"))
      #expect(readNames.contains("gmail.read"))
      try apps.setShared(false, accountID: account.id)
      await #expect(throws: ToolRegistryError.self) {
        try await services.registry.call(
          name: "gmail.read", input: .object(["messageID": .string("123")]), context: context)
      }
      #expect(await requests.count() == 0)
    } catch {
      try? await supervisor.stop(agentID: id)
      throw error
    }
    try await supervisor.stop(agentID: id)
  }

  @Test("OAuth rejects mismatched state, duplicated parameters and unexpected callback paths")
  func oauthCallback() throws {
    let state = UUID().uuidString
    let valid = URLComponents(
      string: "http://127.0.0.1:12345/oauth2callback?state=\(state)&code=example")!
    #expect(try GoogleLoopbackSignIn.validateCallback(valid, expectedState: state) == "example")
    for url in [
      "/oauth2callback?state=other&code=example",
      "/oauth2callback?state=\(state)&state=\(state)&code=example",
      "/oauth2callback?state=\(state)&code=a&code=b",
      "/unexpected?state=\(state)&code=example",
    ] {
      #expect(throws: AppConnectionError.invalidCallback) {
        try GoogleLoopbackSignIn.validateCallback(
          URLComponents(string: "http://127.0.0.1:12345\(url)")!, expectedState: state)
      }
    }
    // RFC 7636 S256 test vector.
    #expect(
      GoogleLoopbackSignIn.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("MIME encoding prevents header injection and preserves Unicode content")
  func mime() throws {
    #expect(throws: AppConnectionError.invalidMessage) {
      try GmailMessageCodec.raw(
        to: "fixture@example.com\r\nBcc: other@example.com", subject: "Hello", body: "Body")
    }
    #expect(throws: AppConnectionError.invalidMessage) {
      try GmailMessageCodec.raw(
        to: "fixture@example.com", subject: "Hello\nBcc: other@example.com", body: "Body")
    }
    let raw = try GmailMessageCodec.raw(
      to: "fixture@example.com", subject: "Hello ☀️", body: "Hi\nthere")
    let decoded = String(decoding: try #require(Data(base64URL: raw)), as: UTF8.self)
    #expect(decoded.contains("Content-Transfer-Encoding: base64"))
    #expect(decoded.contains("Subject: =?UTF-8?B?"))
  }

  @Test("Reconnecting for one Google feature keeps the scopes the account already granted")
  func reconnectKeepsGrantedScopes() throws {
    let calendar: Set<String> = [
      AppConnectionsStore.calendarReadScope, AppConnectionsStore.calendarEventsScope,
    ]
    let send: Set<String> = [AppConnectionsStore.composeScope, AppConnectionsStore.sendScope]
    // Gmail reconnect without calendar keeps calendar; granting calendar keeps sending.
    let gmail = AppConnectionsStore.requestedScopes(
      allowSending: true, allowCalendar: false,
      keeping: calendar.union([AppConnectionsStore.readScope]))
    #expect(gmail.isSuperset(of: calendar.union(send)))
    let granting = AppConnectionsStore.requestedScopes(
      allowSending: false, allowCalendar: true,
      keeping: send.union([AppConnectionsStore.readScope, "openid"]))
    #expect(granting == send.union(calendar).union([AppConnectionsStore.readScope]))

    let url = GoogleLoopbackSignIn.authorizationURL(
      clientID: "id.apps.googleusercontent.com", redirectURI: "http://127.0.0.1:1/oauth2callback",
      scopes: granting, state: "state", challenge: "challenge")
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.contains(URLQueryItem(name: "include_granted_scopes", value: "true")))
  }

  @Test("Nested multipart messages return text and attachment metadata without marking read")
  func multipart() throws {
    let message: JSONValue = .object([
      "id": .string("123"), "labelIds": .array([.string("UNREAD")]),
      "payload": .object([
        "mimeType": .string("multipart/mixed"),
        "parts": .array([
          .object([
            "mimeType": .string("text/plain"),
            "body": .object(["data": .string(Data("Hello".utf8).base64URL)]),
          ]),
          .object([
            "filename": .string("invoice.pdf"), "mimeType": .string("application/pdf"),
            "body": .object(["attachmentId": .string("attachment"), "size": .number(100)]),
          ]),
        ]),
      ]),
    ])
    let result = GmailMessageCodec.normalized(message, includeBody: true)
    #expect(result["body"] == .string("Hello"))
    #expect(result["unread"] == .bool(true))
    #expect(result["attachments"]?.arrayValue?.count == 1)
  }
}

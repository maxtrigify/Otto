import AppKit
import Foundation
import OttoRPCContracts
import OttoSecurity
import Testing
import WebKit

@testable import OttoServices

@Suite("Private website accounts", .serialized)
@MainActor
struct WebsiteAccountTests {
  @Test func privateLoginReuseGrantsAndRevocation() async throws {
    _ = NSApplication.shared
    let server = try WebsiteFixtureServer()
    defer { server.stop() }
    let secrets = InMemorySecretStore()
    let broker = AccountAccessBroker(storage: secrets)
    let workspace = "/tmp/private-website-test-" + UUID().uuidString
    let bot = UUID()
    let stranger = UUID()
    let device = UUID()
    let service = WebsiteAccountService(
      workspacePath: workspace, broker: broker, validBot: { _ in true })
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .selected([bot]))
    var opened: UUID?
    service.onOpenLogin = { opened = $0 }
    _ = try await service.perform(
      WebsiteAccountCommand(
        action: "request_login", accountID: account, url: "https://fixture.invalid"), botID: bot,
      runID: UUID())
    #expect(opened == account)
    let request = try #require(
      try await service.secureInput(SecureLoginInput(action: .list), deviceID: device).requests
        .first)
    let continuation = Task {
      try await service.waitForLogin(accountID: account, botID: bot, runID: UUID())
    }
    defer { continuation.cancel() }
    await #expect(throws: (any Error).self) {
      try await service.perform(
        WebsiteAccountCommand(action: "inspect", accountID: account), botID: bot, runID: UUID())
    }
    var form = try await service.secureInput(
      SecureLoginInput(action: .form, requestID: request.id), deviceID: device)
    await #expect(throws: (any Error).self) {
      try await service.secureInput(
        SecureLoginInput(action: .form, requestID: request.id), deviceID: UUID())
    }
    let username = try #require(form.elements.first { $0.label == "Username" })
    form = try await service.secureInput(
      SecureLoginInput(
        action: .fill, requestID: request.id, revision: form.revision, elementID: username.id,
        value: "fixture-user"), deviceID: device)
    let password = try #require(form.elements.first { $0.kind == "secret" })
    let fill = SecureLoginInput(
      action: .fill, requestID: request.id, revision: form.revision, elementID: password.id,
      value: "SYNTHETIC-TEST-PASSWORD")
    form = try await service.secureInput(fill, deviceID: device)
    #expect(!String(decoding: try JSONEncoder().encode(form), as: UTF8.self).contains("SYNTHETIC"))
    await #expect(throws: (any Error).self) {
      try await service.secureInput(fill, deviceID: device)
    }
    let signIn = try #require(form.elements.first { $0.label == "Sign in" })
    form = try await service.secureInput(
      SecureLoginInput(
        action: .click, requestID: request.id, revision: form.revision, elementID: signIn.id),
      deviceID: device)
    await #expect(throws: (any Error).self) {
      try await service.secureInput(
        SecureLoginInput(action: .finish, requestID: request.id), deviceID: device)
    }
    let otp = try #require(form.elements.first { $0.kind == "secret" })
    form = try await service.secureInput(
      SecureLoginInput(
        action: .fill, requestID: request.id, revision: form.revision, elementID: otp.id,
        value: "654321"), deviceID: device)
    let verify = try #require(form.elements.first { $0.label == "Verify" })
    form = try await service.secureInput(
      SecureLoginInput(
        action: .click, requestID: request.id, revision: form.revision, elementID: verify.id),
      deviceID: device)
    _ = try await service.secureInput(
      SecureLoginInput(action: .finish, requestID: request.id), deviceID: device)
    let continued = try await continuation.value
    #expect(continued.accounts.first?.id == account)
    #expect(continued.message.contains("Continue the user's original task"))
    let page = try await service.perform(
      WebsiteAccountCommand(action: "inspect", accountID: account), botID: bot, runID: UUID())
    #expect(page.pageText?.contains("Signed in as fixture-user") == true)
    #expect(page.pageText?.contains("SYNTHETIC") == false)
    let continueButton = try #require(page.elements.first { $0.label == "Continue" })
    let click = WebsiteAccountCommand(
      action: "click", accountID: account, revision: page.revision, elementID: continueButton.id)
    let detail = try await service.clickApproval(click, botID: bot, runID: UUID())
    #expect(detail.contains("Continue") && detail.contains("https://fixture.invalid"))
    await #expect(throws: (any Error).self) {
      try await service.clickApproval(click, botID: stranger, runID: UUID())
    }
    _ = try await service.perform(click, botID: bot, runID: UUID())
    await #expect(throws: (any Error).self) {
      try await service.perform(click, botID: bot, runID: UUID())
    }
    await #expect(throws: (any Error).self) {
      try await service.perform(
        WebsiteAccountCommand(action: "inspect", accountID: account), botID: stranger, runID: UUID()
      )
    }
    await #expect(throws: (any Error).self) {
      try await service.perform(
        WebsiteAccountCommand(action: "open", accountID: account, url: "https://wrong.invalid"),
        botID: bot, runID: UUID())
    }
    // Recreate both broker and native browser controller, retaining only the real cookie store.
    let restored = WebsiteAccountService(
      workspacePath: workspace, broker: AccountAccessBroker(storage: secrets),
      validBot: { _ in true })
    restored.fixtureURL = server.url
    let resumed = try await restored.perform(
      WebsiteAccountCommand(action: "open", accountID: account), botID: bot, runID: UUID())
    #expect(resumed.pageText?.contains("Signed in as fixture-user") == true)
    try await service.setGrant(accountID: account, bots: .allCurrentAndFuture)
    let future = try await restored.perform(
      WebsiteAccountCommand(action: "inspect", accountID: account), botID: stranger, runID: UUID())
    #expect(future.pageText?.contains("fixture-user") == true)
    try await service.setGrant(accountID: account, bots: .selected([bot]))
    await #expect(throws: (any Error).self) {
      try await restored.perform(
        WebsiteAccountCommand(action: "inspect", accountID: account), botID: stranger, runID: UUID()
      )
    }
    try await service.disconnect(accountID: account)
    await #expect(throws: (any Error).self) {
      try await restored.perform(
        WebsiteAccountCommand(action: "inspect", accountID: account), botID: bot, runID: UUID())
    }
    await #expect(throws: (any Error).self) {
      try await restored.secureInput(
        SecureLoginInput(action: .form, requestID: request.id), deviceID: device)
    }
  }

  @Test func nativeNavigationRejectsAnotherOriginBeforeSending() async throws {
    let server = try WebsiteFixtureServer()
    let other = try WebsiteFixtureServer()
    defer {
      server.stop()
      other.stop()
    }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .allCurrentAndFuture)
    _ = try await service.beginLogin(accountID: account)
    let webView = try #require(service.humanWebView(accountID: account))
    webView.load(URLRequest(url: other.url))
    try await Task.sleep(for: .milliseconds(300))
    #expect(other.requestCount == 0)
    try await service.disconnect(accountID: account)
  }

  @Test func phoneFormOmitsUnrelatedWebsiteLinks() async throws {
    let server = try WebsiteFixtureServer()
    defer { server.stop() }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .allCurrentAndFuture)
    let request = try await service.beginLogin(accountID: account)
    let webView = try #require(service.humanWebView(accountID: account))
    _ = try await webView.evaluateJavaScript(
      "document.body.insertAdjacentHTML('beforeend', '<a href=/ >A</a><a href=/footer>Elemental Selenium</a>')"
    )
    let form = try await service.secureInput(
      SecureLoginInput(action: .form, requestID: request.id), deviceID: UUID())
    #expect(form.elements.filter { $0.kind == "button" }.map(\.label) == ["Sign in"])
    try await service.disconnect(accountID: account)
  }

  @Test func mobileSubmitsTheWholeFormWithOneTap() async throws {
    let server = try WebsiteFixtureServer()
    defer { server.stop() }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.credentialVault = WebsiteCredentialVault(storage: InMemorySecretStore())
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .allCurrentAndFuture)
    let request = try await service.beginLogin(accountID: account)
    let device = UUID()
    var form = try await service.secureInput(
      SecureLoginInput(action: .form, requestID: request.id), deviceID: device)
    let user = try #require(form.elements.first { $0.label == "Username" })
    let password = try #require(form.elements.first { $0.kind == "secret" })
    let submit = try #require(form.elements.first { $0.label == "Sign in" })
    let input = SecureLoginInput(
      action: .click, requestID: request.id, revision: form.revision, elementID: submit.id,
      fields: [user.id: "fixture-user", password.id: "SYNTHETIC-TEST-PASSWORD"])
    #expect(!String(reflecting: input).contains("SYNTHETIC"))
    try await service.stageRememberedInput(input, deviceID: device, remember: true)
    form = try await service.secureInput(input, deviceID: device)
    await #expect(throws: (any Error).self) {
      try await service.secureInput(input, deviceID: device)
    }
    let code = try #require(form.elements.first { $0.label == "Verification code" })
    let verify = try #require(form.elements.first { $0.label == "Verify" })
    _ = try await service.secureInput(
      SecureLoginInput(
        action: .click, requestID: request.id, revision: form.revision, elementID: verify.id,
        fields: [code.id: "654321"]), deviceID: device)
    _ = try await service.secureInput(
      SecureLoginInput(action: .finish, requestID: request.id), deviceID: device)
    let result = try await service.perform(
      WebsiteAccountCommand(action: "inspect", accountID: account), botID: UUID(), runID: UUID())
    #expect(result.pageText?.contains("Signed in as fixture-user") == true)
    let saved = try await service.credentialVault.load(
      owner: service.ownerID, workspace: service.workspaceID, account: account,
      origin: "https://fixture.invalid")
    #expect(saved?.password == "SYNTHETIC-TEST-PASSWORD")
    #expect(saved?.username == "fixture-user")
    try await service.disconnect(accountID: account)
    #expect(
      try await service.credentialVault.load(
        owner: service.ownerID, workspace: service.workspaceID, account: account,
        origin: "https://fixture.invalid") == nil)
  }

  @Test func credentialDeletionFailureRevokesAccessAndCanRetry() async throws {
    let broker = AccountAccessBroker(storage: InMemorySecretStore())
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: broker, validBot: { _ in true })
    service.credentialVault = WebsiteCredentialVault(storage: RefusingCredentialDeletion())
    let bot = UUID()
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .selected([bot]))
    await #expect(throws: (any Error).self) { try await service.disconnect(accountID: account) }
    let available = try await service.perform(
      WebsiteAccountCommand(action: "list"), botID: bot, runID: UUID())
    #expect(available.accounts.isEmpty)
    #expect(
      try await broker.accounts(userID: service.ownerID, workspaceID: service.workspaceID).contains
      { $0.id == account })
    service.credentialVault = WebsiteCredentialVault(storage: InMemorySecretStore())
    try await service.disconnect(accountID: account)
    #expect(
      try await broker.accounts(userID: service.ownerID, workspaceID: service.workspaceID).isEmpty)
  }

  @Test func savedPasswordRestoresOnlyTheApprovedForm() async throws {
    let server = try WebsiteFixtureServer(simpleLogin: true)
    defer { server.stop() }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.credentialVault = WebsiteCredentialVault(storage: InMemorySecretStore())
    service.fixtureURL = server.url
    let bot = UUID()
    let device = UUID()
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .selected([bot]))
    let request = try await service.beginLogin(accountID: account)
    let form = try await service.secureInput(
      SecureLoginInput(action: .form, requestID: request.id), deviceID: device)
    let user = try #require(form.elements.first { $0.label == "Username" })
    let password = try #require(form.elements.first { $0.kind == "secret" })
    let submit = try #require(form.elements.first { $0.label == "Sign in" })
    let input = SecureLoginInput(
      action: .click, requestID: request.id, revision: form.revision,
      elementID: submit.id,
      fields: [user.id: "fixture-user", password.id: "SYNTHETIC-TEST-PASSWORD"])
    try await service.stageRememberedInput(input, deviceID: device, remember: true)
    _ = try await service.secureInput(input, deviceID: device)
    _ = try await service.secureInput(
      SecureLoginInput(action: .finish, requestID: request.id), deviceID: device)
    // Lose the website session while retaining the explicitly saved credential.
    let dataStore = WKWebsiteDataStore(forIdentifier: account)
    await dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    service.cancelLogin(accountID: account)
    #expect(
      try await service.trySavedLogin(
        accountID: account, botID: bot, runID: UUID(), url: "https://fixture.invalid/"))
    let result = try await service.perform(
      WebsiteAccountCommand(action: "inspect", accountID: account), botID: bot, runID: UUID())
    #expect(result.pageText?.contains("Signed in as fixture-user") == true)
    await #expect(throws: (any Error).self) {
      try await service.trySavedLogin(accountID: account, botID: UUID(), runID: UUID(), url: nil)
    }
    try await service.disconnect(accountID: account)
  }

  @Test func cancelledSignInNeverContinuesAgentTask() async throws {
    let server = try WebsiteFixtureServer()
    defer { server.stop() }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .allCurrentAndFuture)
    _ = try await service.beginLogin(accountID: account)
    let continuation = Task {
      try await service.waitForLogin(accountID: account, botID: UUID(), runID: UUID())
    }
    defer { continuation.cancel() }
    await Task.yield()
    service.cancelLogin(accountID: account)
    await #expect(throws: (any Error).self) { try await continuation.value }
    try await service.disconnect(accountID: account)
    #expect(
      try WebsiteAccountService.originForLogin("https://EXAMPLE.com:443/login?next=home")
        == "https://example.com")
    #expect(throws: (any Error).self) {
      try WebsiteAccountService.originForLogin("http://example.com")
    }
  }

  @Test func cancellationAndSecretRedaction() async throws {
    let input = SecureLoginInput(action: .fill, value: "SYNTHETIC-NOT-A-REAL-SECRET")
    #expect(!String(describing: input).contains("SYNTHETIC"))
    #expect(!String(reflecting: input).contains("SYNTHETIC"))
    let server = try WebsiteFixtureServer()
    defer { server.stop() }
    let service = WebsiteAccountService(
      workspacePath: "/tmp/" + UUID().uuidString,
      broker: AccountAccessBroker(storage: InMemorySecretStore()), validBot: { _ in true })
    service.fixtureURL = server.url
    let account = try await service.create(
      origin: "https://fixture.invalid", bots: .allCurrentAndFuture)
    let request = try await service.beginLogin(accountID: account)
    service.cancelLogin(accountID: account)
    await #expect(throws: (any Error).self) {
      try await service.secureInput(
        SecureLoginInput(action: .form, requestID: request.id), deviceID: UUID())
    }
    let next = try await service.beginLogin(accountID: account)
    service.now = { next.expiresAt.addingTimeInterval(1) }
    await #expect(throws: (any Error).self) {
      try await service.secureInput(
        SecureLoginInput(action: .form, requestID: next.id), deviceID: UUID())
    }
    #expect(service.humanWebView(accountID: account) == nil)
    try await service.disconnect(accountID: account)
  }
}

private final class WebsiteFixtureServer {
  let process = Process()
  let url: URL
  let requestsFile = FileManager.default.temporaryDirectory.appending(
    path: "website-requests-" + UUID().uuidString)
  var requestCount: Int { (try? String(contentsOf: requestsFile, encoding: .utf8).count) ?? 0 }
  init(simpleLogin: Bool = false) throws {
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-u", "-c",
      #"""
      from http.server import HTTPServer,BaseHTTPRequestHandler
      import sys
      class H(BaseHTTPRequestHandler):
       def log_message(self,*args): pass
       def do_GET(self):
        with open(sys.argv[1],'a') as f:f.write('x')
        self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
        if 'fixture=ready' in self.headers.get('Cookie',''): body='<h1>Signed in as fixture-user</h1><p>Private test page</p><button onclick="this.innerText=\'Done\'">Continue</button>'
        elif 'fixture=challenge' in self.headers.get('Cookie',''):body='<form method="POST"><label>Verification code<input name="code" autocomplete="one-time-code"></label><button>Verify</button></form>'
        else: body='<form method="POST"><label>Username<input name="user"></label><label>Password<input name="password" type="password"></label><button>Sign in</button></form>'
        self.wfile.write(body.encode())
       def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
        self.send_response(303)
        if 'fixture-user' in body and 'SYNTHETIC-TEST-PASSWORD' in body:self.send_header('Set-Cookie',('fixture=ready' if sys.argv[2]=='simple' else 'fixture=challenge')+'; Path=/; HttpOnly; Max-Age=600')
        if 'code=654321' in body and 'fixture=challenge' in self.headers.get('Cookie',''):self.send_header('Set-Cookie','fixture=ready; Path=/; HttpOnly; Max-Age=600')
        self.send_header('Location','/ready' if sys.argv[2]=='simple' else '/');self.end_headers()
      s=HTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
      """#, requestsFile.path, simpleLogin ? "simple" : "mfa",
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "http://127.0.0.1:" + port), Int(port) != nil else {
      process.terminate()
      throw WebsiteAccountError.unavailable
    }
    self.url = url
  }
  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: requestsFile)
  }
}

private actor RefusingCredentialDeletion: SecretStore {
  func set(_ value: String, for key: String) async throws {}
  func value(for key: String) async throws -> String? { nil }
  func delete(_ key: String) async throws { throw SecretStoreError.invalidEncoding }
}

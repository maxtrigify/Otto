import AppKit
import Foundation
import OttoSecurity
import Testing
import WebKit

@testable import OttoApp

@Suite("Browser password forms", .serialized) @MainActor
struct BrowserPasswordTests {
  private func page(_ html: String, origin: String = "https://example.test") async throws
    -> WKWebView
  {
    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.userContentController.addUserScript(
      WKUserScript(
        source: BrowserPasswordBridge.formScript, injectionTime: .atDocumentStart,
        forMainFrameOnly: true, in: BrowserPasswordBridge.world))
    let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    page.loadHTMLString(html, baseURL: URL(string: origin))
    for _ in 0..<200 {
      let ready =
        try? await page.callAsyncJavaScript(
          "return document.readyState === 'complete' && location.origin === expected && !!document.querySelector('input[type=password]');",
          arguments: ["expected": origin], in: nil, contentWorld: .page) as? Bool
      if ready == true { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let loadedOrigin = try await page.evaluateJavaScript("location.origin") as? String
    #expect(loadedOrigin == origin)
    return page
  }
  private let form =
    "<form action='/session'><label>Email <input name='email' autocomplete='username'></label><label>Password <input name='password' type='password' autocomplete='current-password'></label><button>Sign in</button></form>"

  private func fill(_ page: WKWebView, origin: String = "https://example.test") async throws -> Bool
  {
    try await page.callAsyncJavaScript(
      BrowserPasswordBridge.fillScript,
      arguments: [
        "expectedOrigin": origin, "username": "fixture@example.test", "password": UUID().uuidString,
      ],
      in: nil, contentWorld: BrowserPasswordBridge.world) as? Bool ?? false
  }

  @Test func fillsLoginWithInputEventsWithoutSubmitting() async throws {
    let page = try await page(form)
    try await page.evaluateJavaScript(
      "window.edits=0; window.submits=0; document.addEventListener('input',()=>window.edits++); document.addEventListener('submit',e=>{e.preventDefault();window.submits++})"
    )
    #expect(try await fill(page))
    #expect(
      try await page.evaluateJavaScript("document.querySelector('[name=email]').value") as? String
        == "fixture@example.test")
    #expect(
      try await page.evaluateJavaScript(
        "document.querySelector('[type=password]').value.length > 0") as? Bool == true)
    #expect(try await page.evaluateJavaScript("window.edits") as? Int == 2)
    #expect(try await page.evaluateJavaScript("window.submits") as? Int == 0)
    #expect(
      try await page.evaluateJavaScript("typeof window.ottoPasswordCandidate") as? String
        == "undefined")
    #expect(
      try await page.evaluateJavaScript(
        "typeof window.webkit?.messageHandlers?.ottoPasswordSubmission") as? String == "undefined")
  }

  @Test func rejectsCrossOriginSignupAndChangedForms() async throws {
    let unsafe = [
      form.replacingOccurrences(
        of: "action='/session'", with: "action='https://other.test/session'"),
      form.replacingOccurrences(of: "current-password", with: "new-password"),
      form.replacingOccurrences(of: "<button>", with: "<input type='password'><button>"),
      form.replacingOccurrences(
        of: "<button>", with: "<button formaction='https://other.test/session'>"),
      form.replacingOccurrences(of: "<form ", with: "<form id='login' ")
        + "<button form='login' formaction='https://other.test/session'>External submit</button>",
    ]
    for html in unsafe { #expect(try await fill(try await page(html)) == false) }
    let page = try await page(form)
    #expect(try await fill(page, origin: "https://other.test") == false)
    try await page.evaluateJavaScript(
      "document.querySelector('[name=email]').addEventListener('input',()=>document.querySelector('form').action='https://other.test/session')"
    )
    #expect(try await fill(page) == false)
    #expect(
      try await page.evaluateJavaScript("document.querySelector('[type=password]').value === ''")
        as? Bool == true)
  }

  @Test func nativeSaveAndFillFlow() async throws {
    let page = try await page(form)
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page
    window.orderFront(nil)
    defer { window.close() }
    let vault = BrowserPasswordVault(storage: InMemorySecretStore())
    let candidate = BrowserPasswordVault.Login(
      origin: "https://example.test", username: "fixture@example.test", password: UUID().uuidString)
    _ = try await page.callAsyncJavaScript(
      "document.querySelector('[name=email]').value = username; document.querySelector('[type=password]').value = password; return true;",
      arguments: ["username": candidate.username, "password": candidate.password], in: nil,
      contentWorld: BrowserPasswordBridge.world)
    let declined = Task { await BrowserPasswordBridge.saveCurrent(in: page, vault: vault) }
    try await press("Not Now", in: window)
    await declined.value
    #expect(try await vault.summaries().isEmpty)
    let save = Task { await BrowserPasswordBridge.saveCurrent(in: page, vault: vault) }
    try await press("Save Password", in: window)
    await save.value
    #expect(try await vault.summaries().count == 1)
    _ = try await page.evaluateJavaScript(
      "document.querySelector('[name=email]').value = ''; document.querySelector('[type=password]').value = ''"
    )
    let cancelled = Task { await BrowserPasswordBridge.fillSaved(in: page, vault: vault) }
    try await press("Cancel", in: window)
    await cancelled.value
    #expect(
      try await page.evaluateJavaScript("document.querySelector('[type=password]').value === ''")
        as? Bool == true)
    let fill = Task { await BrowserPasswordBridge.fillSaved(in: page, vault: vault) }
    try await press("Fill Password", in: window)
    await fill.value
    #expect(
      try await page.evaluateJavaScript("document.querySelector('[name=email]').value") as? String
        == candidate.username)
    #expect(
      try await page.callAsyncJavaScript(
        "return document.querySelector('[type=password]').value === expected;",
        arguments: ["expected": candidate.password], in: nil,
        contentWorld: BrowserPasswordBridge.world) as? Bool == true)
    let updated = BrowserPasswordVault.Login(
      origin: candidate.origin, username: candidate.username, password: UUID().uuidString)
    let update = Task { await BrowserPasswordBridge.offerSave(updated, in: page, vault: vault) }
    try await press("Update Password", in: window)
    await update.value
    #expect(
      try await vault.login(origin: candidate.origin, username: candidate.username) == updated)
  }
  private func press(_ title: String, in window: NSWindow) async throws {
    func find(_ view: NSView) -> NSButton? {
      if let button = view as? NSButton, button.title == title { return button }
      return view.subviews.lazy.compactMap(find).first
    }
    for _ in 0..<200 {
      if let sheet = window.attachedSheet, let content = sheet.contentView,
        let button = find(content)
      {
        if let directory = ProcessInfo.processInfo.environment["OTTO_PASSWORD_SCREENSHOTS"] {
          try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
          if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
              to: URL(fileURLWithPath: directory).appendingPathComponent(
                title.replacingOccurrences(of: " ", with: "-").lowercased() + ".png"))
          }
        }
        button.performClick(nil)
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Native password prompt was not shown")
    window.attachedSheet.map { window.endSheet($0, returnCode: .alertSecondButtonReturn) }
  }
}

import AppKit
import OttoSecurity
import SwiftUI
import WebKit

/// Only this native UI reaches the personal browser vault. It is never registered as an agent tool.
struct BrowserPasswordsButton: View {
  @Environment(\.ottoPalette) private var palette
  var tabID: UUID?
  @State private var showsManager = false
  var body: some View {
    Menu {
      Button("Fill Saved Password…") {
        if let page = BrowserRendererPool.passwordPage(tabID: tabID) {
          Task { await BrowserPasswordBridge.fillSaved(in: page) }
        }
      }
      .disabled(BrowserRendererPool.passwordPage(tabID: tabID)?.url?.scheme != "https")
      Button("Save Password on This Page…") {
        if let page = BrowserRendererPool.passwordPage(tabID: tabID) {
          Task { await BrowserPasswordBridge.saveCurrent(in: page) }
        }
      }
      .disabled(BrowserRendererPool.passwordPage(tabID: tabID)?.url?.scheme != "https")
      Divider()
      Button("Saved Passwords…") { showsManager = true }
    } label: {
      Image(systemName: "key.horizontal").font(.system(size: 12, weight: .medium))
        .frame(width: 24, height: 28)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .foregroundStyle(palette.muted)
    .tint(palette.muted)
    .fixedSize()
    .help("Save and fill passwords")
    .accessibilityLabel("Passwords")
    .sheet(isPresented: $showsManager) { BrowserSavedPasswordsView() }
  }
}

struct BrowserSavedPasswordsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var logins: [BrowserPasswordVault.Summary] = []
  @State private var notice = ""
  @State private var deleting: BrowserPasswordVault.Summary?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Saved Passwords").font(.title2.bold())
      Text("Stored in macOS Keychain. Use the key button on a site to fill a saved login.")
        .foregroundStyle(.secondary)
      List(logins) { login in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(login.origin).fontWeight(.medium)
            Text(login.username.isEmpty ? "No username" : login.username).foregroundStyle(
              .secondary)
          }
          Spacer()
          Button("Delete", role: .destructive) { deleting = login }
        }.padding(.vertical, 4)
      }.overlay { if logins.isEmpty { Text("No saved passwords").foregroundStyle(.secondary) } }
      if !notice.isEmpty { Text(notice).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(22).frame(width: 540, height: 380)
    .task { await reload() }
    .confirmationDialog(
      "Delete this saved password?",
      isPresented: Binding(
        get: { deleting != nil }, set: { if !$0 { deleting = nil } }
      ), titleVisibility: .visible
    ) {
      if let login = deleting {
        Button("Delete Password", role: .destructive) {
          Task {
            do {
              try await BrowserPasswordVault.shared.delete(
                origin: login.origin, username: login.username)
              await reload()
            } catch { notice = "Could not delete the password from Keychain. Try again." }
            deleting = nil
          }
        }
      }
    }
  }
  private func reload() async {
    do {
      logins = try await BrowserPasswordVault.shared.summaries()
      notice = ""
    } catch { notice = "Could not read saved passwords from Keychain. Try again." }
  }
}

@MainActor
final class BrowserPasswordBridge: NSObject, WKScriptMessageHandler {
  static let name = "ottoPasswordSubmission"
  static let world = WKContentWorld.world(name: "OttoBrowserPasswords")
  private static let pages = NSHashTable<WKWebView>.weakObjects()
  static func register(_ page: WKWebView) { pages.add(page) }
  weak var webView: WKWebView? {
    didSet { if let webView { Self.register(webView) } }
  }
  private static var promptOpen = false

  static func install(in configuration: WKWebViewConfiguration) -> BrowserPasswordBridge {
    let bridge = BrowserPasswordBridge()
    configuration.userContentController.add(bridge, contentWorld: world, name: name)
    configuration.userContentController.addUserScript(
      WKUserScript(
        source: captureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
    return bridge
  }

  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.name, message.frameInfo.isMainFrame,
      let page = message.webView, Self.pages.contains(page), page.window?.isVisible == true,
      !page.isHidden,
      let origin = BrowserPasswordVault.origin(for: message.frameInfo.request.url),
      BrowserPasswordVault.origin(for: page.url) == origin,
      message.frameInfo.securityOrigin.protocol == "https",
      message.frameInfo.securityOrigin.host.lowercased() == URL(string: origin)?.host?.lowercased(),
      (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port)
        == (URL(string: origin)?.port ?? 443),
      let body = message.body as? [String: String], body["origin"] == origin,
      let password = body["password"], !password.isEmpty, password.utf8.count <= 16_384,
      let username = body["username"], username.utf8.count <= 4096
    else { return }
    let candidate = BrowserPasswordVault.Login(
      origin: origin, username: username, password: password)
    Task { await Self.offerSave(candidate, in: page) }
  }

  static func offerSave(
    _ candidate: BrowserPasswordVault.Login, in page: WKWebView,
    vault: BrowserPasswordVault = .shared
  ) async {
    guard !promptOpen, let window = page.window, window.isVisible, window.attachedSheet == nil
    else { return }
    promptOpen = true
    defer { promptOpen = false }
    do {
      let previous = try await vault.login(
        origin: candidate.origin, username: candidate.username)
      if previous == candidate { return }
      let alert = NSAlert()
      alert.messageText =
        previous == nil
        ? "Save password for \(candidate.origin)?" : "Update password for \(candidate.origin)?"
      alert.informativeText =
        "\(candidate.username.isEmpty ? "This login" : candidate.username) will be saved in macOS Keychain."
      alert.addButton(withTitle: previous == nil ? "Save Password" : "Update Password")
      alert.addButton(withTitle: "Not Now")
      guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
      try await vault.save(candidate)
    } catch { showNotice("The password could not be saved in Keychain. Try again.", in: page) }
  }

  static func saveCurrent(in page: WKWebView, vault: BrowserPasswordVault = .shared) async {
    guard let origin = BrowserPasswordVault.origin(for: page.url) else {
      showNotice("Passwords can only be saved on secure HTTPS pages.", in: page)
      return
    }
    do {
      let result = try await page.callAsyncJavaScript(
        "return globalThis.ottoPasswordCandidate?.() ?? null;", arguments: [:], in: nil,
        contentWorld: world)
      guard BrowserPasswordVault.origin(for: page.url) == origin,
        let body = result as? [String: String], body["origin"] == origin,
        let password = body["password"], !password.isEmpty, let username = body["username"]
      else {
        showNotice(
          "Enter your login in the page first. Only a single, same-site login form is supported.",
          in: page)
        return
      }
      await offerSave(
        .init(origin: origin, username: username, password: password), in: page, vault: vault)
    } catch {
      showNotice(
        "Could not read the login form. Try again when the page has finished loading.", in: page)
    }
  }

  static func fillSaved(in page: WKWebView, vault: BrowserPasswordVault = .shared) async {
    guard let origin = BrowserPasswordVault.origin(for: page.url), let window = page.window,
      window.isVisible, window.attachedSheet == nil
    else {
      showNotice("Passwords can only be filled on secure HTTPS pages.", in: page)
      return
    }
    do {
      let logins = try await vault.summaries().filter { $0.origin == origin }
      guard BrowserPasswordVault.origin(for: page.url) == origin, window.attachedSheet == nil else {
        return
      }
      guard !logins.isEmpty else {
        showNotice("No password is saved for this site yet.", in: page)
        return
      }
      // The native picker also makes the destination explicit before a password enters the page.
      let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
      picker.addItems(withTitles: logins.map { $0.username.isEmpty ? "No username" : $0.username })
      let alert = NSAlert()
      alert.messageText = "Fill a saved password for \(origin)?"
      alert.informativeText = "Choose a login. Otto fills the form; you submit it."
      alert.accessoryView = picker
      alert.addButton(withTitle: "Fill Password")
      alert.addButton(withTitle: "Cancel")
      guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
        BrowserPasswordVault.origin(for: page.url) == origin,
        logins.indices.contains(picker.indexOfSelectedItem),
        let login = try await vault.login(
          origin: origin, username: logins[picker.indexOfSelectedItem].username),
        BrowserPasswordVault.origin(for: page.url) == origin
      else { return }
      let filled =
        try await page.callAsyncJavaScript(
          fillScript,
          arguments: [
            "expectedOrigin": origin, "username": login.username, "password": login.password,
          ],
          in: nil, contentWorld: world) as? Bool
      if filled != true {
        showNotice(
          "No compatible login form was found. Passwords are not filled into sign-up, change-password, embedded, or cross-site forms.",
          in: page)
      }
    } catch {
      showNotice(
        "Could not fill the saved password. Check Keychain access and try again.", in: page)
    }
  }

  private static func showNotice(_ text: String, in page: WKWebView) {
    guard let window = page.window, window.isVisible, window.attachedSheet == nil else { return }
    let alert = NSAlert()
    alert.messageText = text
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: window)
  }

  // Runs in an isolated content world, in the top frame only. The capture bridge has no credential-read operation.
  static let formScript = #"""
    const visible = e => e instanceof HTMLInputElement && !e.disabled && !e.readOnly &&
      e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
    globalThis.ottoPasswordForm = (preferred) => {
      if (location.protocol !== 'https:') return null;
      const passwords = Array.from(document.querySelectorAll('input[type="password"]')).filter(visible);
      if (passwords.length !== 1 || passwords[0].autocomplete.split(/\s+/).includes('new-password')) return null;
      const password = passwords[0], form = password.form;
      if (!form || (preferred && preferred !== form)) return null;
      if (new URL(form.action || location.href, location.href).origin !== location.origin) return null;
      if (Array.from(form.elements).filter(e => e.hasAttribute('formaction')).some(e => new URL(e.formAction, location.href).origin !== location.origin)) return null;
      const before = Array.from(form.elements).filter(e => visible(e) && e !== password &&
        ['text', 'email', 'tel'].includes(e.type) && (e.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING));
      const username = before.find(e => ['username', 'email'].includes(e.autocomplete)) || before.at(-1);
      return {form, password, username};
    };
    globalThis.ottoPasswordCandidate = (preferred) => {
      const fields = globalThis.ottoPasswordForm(preferred);
      if (!fields || !fields.password.value || fields.password.value.length > 16384) return null;
      return {origin: location.origin, username: fields.username?.value || '', password: fields.password.value};
    };
    """#
  static let captureScript =
    formScript + #"""
      let editedAt = 0;
      document.addEventListener('input', event => {
        if (event.isTrusted && event.target instanceof HTMLInputElement && event.target.type === 'password') editedAt = Date.now();
      }, true);
      document.addEventListener('submit', event => {
        if (!event.isTrusted || Date.now() - editedAt > 120000 || !document.hasFocus()) return;
        const candidate = globalThis.ottoPasswordCandidate(event.target);
        if (candidate) window.webkit.messageHandlers.ottoPasswordSubmission.postMessage(candidate);
        editedAt = 0;
      }, true);
      """#
  static let fillScript = #"""
    if (location.origin !== expectedOrigin) return false;
    const fields = globalThis.ottoPasswordForm?.();
    if (!fields) return false;
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    if (fields.username) {
      setter.call(fields.username, username);
      fields.username.dispatchEvent(new Event('input', {bubbles: true}));
      fields.username.dispatchEvent(new Event('change', {bubbles: true}));
    }
    // Input handlers can replace the form or navigate. Recheck before exposing the password.
    const current = globalThis.ottoPasswordForm?.();
    if (location.origin !== expectedOrigin || !current || current.password !== fields.password || !fields.password.isConnected) return false;
    setter.call(fields.password, password);
    fields.password.dispatchEvent(new Event('input', {bubbles: true}));
    fields.password.dispatchEvent(new Event('change', {bubbles: true}));
    return true;
    """#
}

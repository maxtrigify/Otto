import AppKit
import OttoModels
import OttoSecurity
import OttoServices
import SwiftUI
import WebKit

struct WebsiteAccountsView: View {
  @ObservedObject var accounts: WebsiteAccountService
  let profiles: [AgentProfile]
  @State private var origin = ""
  @State private var selected: Set<UUID> = []
  @State private var futureBots = false
  @State private var failure: String?
  @State private var busy = false
  @State private var editing: AccountAccessBroker.Account?

  var body: some View {
    Form {
      Section("Website accounts") {
        Text(
          "Sign in privately, then let selected bots use that website session. Passwords and verification codes are entered directly into the website, not into chat. Each account has its own browser storage."
        )
        .font(.callout).foregroundStyle(.secondary)
        ForEach(accounts.accounts, id: \.id) { account in
          VStack(alignment: .leading, spacing: 8) {
            Text(account.origin).font(.headline)
            Text(
              account.browserSessionApproved == true
                ? "Session approved · website may still request reauthentication"
                : "Private sign-in needed"
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("Sign in privately") {
                Task { await accounts.showLogin(accountID: account.id) }
              }
              Button("Bot access") {
                editing = account
                loadGrant(account)
              }
              Button("Disconnect", role: .destructive) {
                execute { try await accounts.disconnect(accountID: account.id) }
              }
            }
          }.padding(.vertical, 4)
        }
      }
      Section(editing == nil ? "Add an account" : "Change bot access") {
        if editing == nil {
          TextField("Website origin, e.g. https://example.com", text: $origin)
        } else {
          Text(editing!.origin)
        }
        Toggle("Allow all current and future bots", isOn: $futureBots)
        if !futureBots {
          ForEach(profiles.filter { !$0.isArchived }) { profile in
            Toggle(
              profile.name,
              isOn: Binding(
                get: { selected.contains(profile.id) },
                set: { if $0 { selected.insert(profile.id) } else { selected.remove(profile.id) } })
            )
          }
        }
        HStack {
          Button(editing == nil ? "Add account" : "Save access") {
            let grant: AccountAccessBroker.BotScope =
              futureBots ? .allCurrentAndFuture : .selected(selected)
            execute {
              if let editing {
                try await accounts.setGrant(accountID: editing.id, bots: grant)
              } else {
                _ = try await accounts.create(
                  origin: origin.trimmingCharacters(in: .whitespacesAndNewlines), bots: grant)
              }
              origin = ""
              selected = []
              futureBots = false
              editing = nil
            }
          }.disabled(
            busy || (!futureBots && selected.isEmpty) || (editing == nil && origin.isEmpty))
          if editing != nil {
            Button("Cancel") {
              editing = nil
              selected = []
              futureBots = false
            }
          }
        }
      }
      if let failure { Text(failure).foregroundStyle(.red) }
      if !accounts.notice.isEmpty { Text(accounts.notice).foregroundStyle(.secondary) }
      Section("Phone sign-in") {
        Text(
          "When you text your agent, Otto sends a private link for website sign-in and approvals. Open it on your phone, enter your details, and return to Messages. Otto continues automatically. Your Mac must stay online. Never send passwords in ordinary messages."
        )
        .font(.caption)
      }
    }
    .formStyle(.grouped).frame(width: 650, height: 670)
    .task { await accounts.refresh() }
  }
  private func execute(_ work: @escaping @MainActor () async throws -> Void) {
    busy = true
    failure = nil
    Task {
      defer { busy = false }
      do { try await work() } catch {
        failure = "Could not update this account. Check the exact HTTPS origin and try again."
      }
    }
  }
  private func loadGrant(_ account: AccountAccessBroker.Account) {
    switch account.bots {
    case .allCurrentAndFuture:
      futureBots = true
      selected = []
    case .selected(let ids):
      futureBots = false
      selected = ids
    }
  }
}

@MainActor
final class PrivateWebsiteLoginWindows: NSObject, NSWindowDelegate {
  static let shared = PrivateWebsiteLoginWindows()
  private var windows: [UUID: NSWindow] = [:]
  private var services: [UUID: WebsiteAccountService] = [:]
  func open(_ accountID: UUID, service: WebsiteAccountService) {
    guard let webView = service.humanWebView(accountID: accountID) else { return }
    if let old = windows.removeValue(forKey: accountID) {
      old.delegate = nil
      old.close()
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 830),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.identifier = NSUserInterfaceItemIdentifier("otto-private-login-" + accountID.uuidString)
    window.title = "Private website sign-in"
    window.sharingType = .none
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(
      rootView: PrivateWebsiteLoginView(
        service: service, accountID: accountID, webView: webView,
        close: { [weak self] in self?.finishWindow(accountID) }))
    windows[accountID] = window
    services[accountID] = service
    window.center()
    window.makeKeyAndOrderFront(nil)
  }
  private func finishWindow(_ id: UUID) {
    let window = windows.removeValue(forKey: id)
    services[id] = nil
    window?.delegate = nil
    window?.close()
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let id = windows.first(where: { $0.value === window })?.key
    else { return }
    services[id]?.cancelLogin(accountID: id)
    windows[id] = nil
    services[id] = nil
  }
}
private struct PrivateWebsiteLoginView: View {
  @ObservedObject var service: WebsiteAccountService
  let accountID: UUID
  let webView: WKWebView
  let close: () -> Void
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(service.accounts.first(where: { $0.id == accountID })?.origin ?? "Private sign-in").font(
        .headline)
      Text(
        "Bots are paused for this account. Sign in, complete any verification, and confirm you see the intended account. No password is saved by Otto; the website session is retained."
      ).font(.callout)
      HStack {
        Button("I'm signed in — allow bot access") {
          Task {
            do {
              try await service.finishLogin(accountID: accountID)
              close()
            } catch { self.error = error.localizedDescription }
          }
        }
        Button("Cancel") {
          service.cancelLogin(accountID: accountID)
          close()
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
      PrivateWebsiteWebView(webView: webView)
    }.padding(16)
  }
}
private struct PrivateWebsiteWebView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

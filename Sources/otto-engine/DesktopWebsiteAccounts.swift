import Foundation
import OttoModels
import OttoRPCContracts
import OttoServices

/// Website accounts on Otto Desktop. Each account's private page is a separate Chromium session
/// in the desktop, kept to the account's origin; the engine's WebsiteAccountDriver (the Mac's
/// logic) decides what may happen, and the desktop runs its scripts in an isolated world.
final class DesktopAccountRenderer: WebsiteAccountRenderer, @unchecked Sendable {
  private struct OpenParams: Encodable, Sendable {
    var accountID: UUID
    var origin: String
    var allowOrigin: String
  }
  private struct LoadParams: Encodable, Sendable {
    var accountID: UUID
    var url: String
  }
  private struct EvalParams: Encodable, Sendable {
    var accountID: UUID
    var body: String
    var arguments: [String: OpaqueCodableValue]
  }
  private struct IDParams: Encodable, Sendable { var accountID: UUID }
  struct StateEvent: Decodable {
    var accountID: UUID
    var url: String?
    var isLoading: Bool
    var failed: Bool
  }

  private let host: DesktopHost
  private let lock = NSLock()
  private var states: [UUID: WebsiteAccountPageState] = [:]

  init(host: DesktopHost) { self.host = host }

  /// Page state the desktop pushes on every navigation (`account.state`).
  func record(_ event: StateEvent) {
    lock.withLock {
      states[event.accountID] = WebsiteAccountPageState(
        url: event.url, isLoading: event.isLoading, failed: event.failed)
    }
  }

  func open(accountID: UUID, origin: String, fixtureOrigin: String) async throws {
    _ = try await host.call(
      "account.open", OpenParams(accountID: accountID, origin: origin, allowOrigin: fixtureOrigin),
      as: Bool.self)
  }

  func load(accountID: UUID, url: String) async throws {
    // The navigation starts now; the driver polls the pushed state until it settles.
    lock.withLock { states[accountID] = WebsiteAccountPageState(url: nil, isLoading: true, failed: false) }
    _ = try await host.call("account.load", LoadParams(accountID: accountID, url: url), as: Bool.self)
  }

  func state(accountID: UUID) -> WebsiteAccountPageState? {
    lock.withLock { states[accountID] }
  }

  func evaluate(accountID: UUID, body: String, arguments: [String: OpaqueCodableValue])
    async throws -> OpaqueCodableValue
  {
    try await host.call(
      "account.eval", EvalParams(accountID: accountID, body: body, arguments: arguments),
      as: OpaqueCodableValue.self)
  }

  func hide(accountID: UUID) async {
    await host.send("account.hide", IDParams(accountID: accountID))
  }

  func close(accountID: UUID) async {
    lock.withLock { _ = states.removeValue(forKey: accountID) }
    await host.send("account.close", IDParams(accountID: accountID))
  }
}

@MainActor
enum DesktopWebsiteAccounts {
  private struct ShowParams: Encodable, Sendable {
    var accountID: UUID
    var origin: String
  }
  private struct AccountEvent: Decodable { var accountID: UUID }

  /// Installs the renderer and connects the private sign-in window to the service.
  static func start(services: ApplicationServices, host: DesktopHost) async {
    let renderer = DesktopAccountRenderer(host: host)
    WebsiteAccountRendering.install(renderer)
    await host.on("account.state") { payload in
      if let event = try? OttoRPCCodec.decode(DesktopAccountRenderer.StateEvent.self, from: payload)
      {
        renderer.record(event)
      }
    }
    let accounts = services.websiteAccounts
    // A bot asked for sign-in, or the person chose Sign in: show the private window.
    accounts.onOpenLogin = { id in
      let origin = accounts.accounts.first { $0.id == id }?.origin ?? ""
      Task { await host.send("account.show", ShowParams(accountID: id, origin: origin)) }
    }
    await host.on("account.done") { payload in
      guard let event = try? OttoRPCCodec.decode(AccountEvent.self, from: payload) else { return }
      await MainActor.run {
        Task {
          do {
            try await accounts.finishLogin(accountID: event.accountID)
            await host.send("account.finished", ["accountID": event.accountID.uuidString])
          } catch {
            await host.send(
              "account.finished",
              ["accountID": event.accountID.uuidString, "error": error.localizedDescription])
          }
        }
      }
    }
    await host.on("account.cancel") { payload in
      guard let event = try? OttoRPCCodec.decode(AccountEvent.self, from: payload) else { return }
      await MainActor.run { accounts.cancelLogin(accountID: event.accountID) }
    }
  }
}

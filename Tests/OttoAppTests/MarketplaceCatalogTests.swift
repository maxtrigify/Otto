import Foundation
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoServices
import Testing

@testable import OttoApp

@Suite("Marketplace accounts and availability")
@MainActor
struct MarketplaceCatalogTests {
  private func accounts(_ root: URL) -> ProviderAccountStore {
    ProviderAccountStore(rootDirectory: root, userHome: root, secrets: InMemorySecretStore())
  }
  private func app(_ id: String = "gmail", callable: Bool? = nil) -> ProviderMarketplaceApp {
    ProviderMarketplaceApp(
      id: id, name: "Gmail", description: "Email",
      installURL: URL(string: "https://chatgpt.com/apps/gmail/\(id)"), isAccessible: false,
      isEnabled: true, isCallable: callable)
  }

  @Test func missingAndAPIKeyAccountsNeverBorrowMacCatalogue() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    let store = MarketplaceCatalogStore()
    store.publicDiscovery = { [] }
    var calls = 0
    store.discover = { _ in
      calls += 1
      return []
    }
    await store.load(accounts: accounts, accountID: UUID(), workspacePath: root.path)
    #expect(calls == 0)
    #expect(store.listings.isEmpty)
    var keyAccount = try accounts.create(name: "API")
    keyAccount.credentialModes[.codex] = .apiKey
    keyAccount.credentialModes[.claudeCode] = .apiKey
    try accounts.update(keyAccount)
    await store.load(accounts: accounts, accountID: keyAccount.id, workspacePath: root.path)
    #expect(calls == 0)
    #expect(store.listings.isEmpty)
    #expect(store.codexNotice?.contains("API key") == true)
  }

  @Test func namedAccountsUseTheirOwnHomeAndDoNotReadMacInventory() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    let named = try accounts.create(name: "Work")
    let store = MarketplaceCatalogStore()
    store.publicDiscovery = { [] }
    var inventoryCalls = 0
    store.inventory = { _, _ in
      inventoryCalls += 1
      return []
    }
    var probedHome: String?
    store.discover = { environment in
      probedHome = environment["CODEX_HOME"]
      return [app()]
    }
    await store.load(accounts: accounts, accountID: named.id, workspacePath: root.path)
    #expect(probedHome == accounts.providerHome(accountID: named.id, provider: .codex).path)
    #expect(inventoryCalls == 0)
    #expect(store.listings.last?.canSetUp == true)
  }

  @Test func olderAccountResponseCannotReplaceNewAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    let store = MarketplaceCatalogStore()
    store.publicDiscovery = { [] }
    store.inventory = { _, _ in [] }
    var first: CheckedContinuation<[ProviderMarketplaceApp]?, Never>?
    store.discover = { _ in await withCheckedContinuation { first = $0 } }
    let old = Task {
      await store.load(accounts: accounts, accountID: nil, workspacePath: root.path)
    }
    while first == nil { await Task.yield() }
    store.discover = { _ in [app("new")] }
    await store.load(accounts: accounts, accountID: nil, workspacePath: root.path)
    first?.resume(returning: [app("old")])
    await old.value
    #expect(store.listings.contains { $0.id == "codex:new" })
    #expect(!store.listings.contains { $0.id == "codex:old" })
    #expect(!store.isLoading)
  }

  @Test func declarationsAndDirectoryEntriesDoNotClaimConnectedState() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    let store = MarketplaceCatalogStore()
    store.publicDiscovery = { [] }
    store.inventory = { provider, _ in
      provider == .cursor
        ? [HarnessPlugin(name: "Slack", source: "Cursor", mark: "#", colorHex: "#000000")] : []
    }
    store.discover = { _ in [app(), app("enabled", callable: true)] }
    await store.load(accounts: accounts, accountID: nil, workspacePath: root.path)
    let directory = try #require(store.listings.first { $0.id == "codex:gmail" })
    // Directory entry's isAccessible=false is the normal pre-connect state.
    #expect(directory.canSetUp)
    #expect(directory.status == "Setup required")
    #expect(!directory.isInstalled)
    let local = try #require(store.listings.first { $0.provider == .cursor })
    #expect(local.status == "Configured")
    #expect(!local.canSetUp)
    #expect(
      store.filtered(
        search: "gmail", category: .communication, provider: .codex, installedOnly: true
      ).count == 1)
    #expect(
      store.filtered(search: "slack", category: .all, provider: .cursor, installedOnly: false).count
        == 1)
    #expect(!MarketplaceCatalogStore.providers.contains(.hermes))
  }

  @Test func failureDoesNotInventAnAccountCatalogue() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MarketplaceCatalogStore()
    store.publicDiscovery = { [] }
    store.inventory = { _, _ in [] }
    store.discover = { _ in nil }
    await store.load(accounts: accounts(root), accountID: nil, workspacePath: root.path)
    #expect(!store.listings.contains { $0.provider == .codex })
    #expect(store.codexNotice != nil)
    #expect(
      store.listings.allSatisfy {
        $0.provider == .claudeCode && $0.status == "Finish setup in Claude"
      })
  }

  @Test func publicCataloguesRemainMetadataForAPIKeyAccountsAndReportPartialFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    var account = try accounts.create(name: "API")
    account.credentialModes[.codex] = .apiKey
    try accounts.update(account)
    let store = MarketplaceCatalogStore()
    store.inventory = { _, _ in
      Issue.record("Named account must not borrow Mac inventory")
      return []
    }
    store.discover = { _ in
      Issue.record("API-key account must not borrow Codex apps")
      return nil
    }
    let plugin = PublicMarketplacePlugin(
      id: "slack", name: "Slack", summary: "Chat",
      provider: .grok, sourceURL: PublicPluginCatalog.feed(for: .grok)!,
      installSource:
        "https://github.com/vendor/plugin.git@0123456789012345678901234567890123456789",
      nativeInstall: true)
    store.publicDiscovery = {
      [
        PublicCatalogResult(provider: .grok, plugins: [plugin]),
        PublicCatalogResult(provider: .kimi, plugins: [], failed: true),
      ]
    }
    await store.load(accounts: accounts, accountID: account.id, workspacePath: root.path)
    let entry = try #require(store.listings.first { $0.plugin != nil })
    #expect(!entry.isInstalled)
    #expect(entry.status == "Official catalogue · Plugin")
    #expect(store.publicNotices.count == 1)
    #expect(store.codexNotice?.contains("API key") == true)
  }

  @Test func stalePublicResponseCannotReplaceNewAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = accounts(root)
    let store = MarketplaceCatalogStore()
    store.inventory = { _, _ in [] }
    store.discover = { _ in [] }
    var first: CheckedContinuation<[PublicCatalogResult], Never>?
    store.publicDiscovery = { await withCheckedContinuation { first = $0 } }
    let old = Task {
      await store.load(accounts: accounts, accountID: nil, workspacePath: root.path)
    }
    while first == nil { await Task.yield() }
    store.publicDiscovery = { [] }
    await store.load(accounts: accounts, accountID: UUID(), workspacePath: root.path)
    first?.resume(returning: [PublicCatalogResult(provider: .grok, plugins: [], failed: true)])
    await old.value
    #expect(store.listings.isEmpty)
    #expect(store.publicNotices.isEmpty)
    #expect(store.codexNotice?.contains("no longer exists") == true)
  }
}

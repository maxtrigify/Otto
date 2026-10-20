import Combine
import Foundation
import OttoModels
import OttoRuntime
import OttoServices

/// A unified presentation of provider-owned connections. Opening setup never changes state here.
struct MarketplaceListing: Identifiable, Equatable {
  let id: String
  let name: String
  let summary: String
  let provider: AgentProvider
  let category: MarketplaceCategory
  let setupURL: URL?
  let status: String
  let isInstalled: Bool
  let canSetUp: Bool
  var plugin: PublicMarketplacePlugin? = nil
  var authenticationServer: String? = nil
}

enum MarketplaceCategory: String, CaseIterable, Identifiable {
  case all = "All"
  case productivity = "Productivity"
  case communication = "Communication"
  case design = "Design"
  case code = "Code"
  case other = "More"
  var id: String { rawValue }

  static func classify(_ name: String) -> Self {
    let name = name.lowercased()
    if ["gmail", "outlook", "slack", "teams", "discord", "mail"].contains(where: name.contains) {
      return .communication
    }
    if ["figma", "canva", "design", "image"].contains(where: name.contains) { return .design }
    if ["github", "gitlab", "code", "supabase", "vercel", "aws", "cloudflare", "sentry"].contains(
      where: name.contains)
    {
      return .code
    }
    if ["notion", "drive", "calendar", "linear", "jira", "docs", "sheets", "microsoft", "dropbox"]
      .contains(where: name.contains)
    {
      return .productivity
    }
    return .other
  }
}

@MainActor
final class MarketplaceCatalogStore: ObservableObject {
  static let providers: [AgentProvider] = [.claudeCode, .codex, .cursor, .grok, .kimi, .openCode]
  @Published private(set) var listings: [MarketplaceListing] = []
  @Published private(set) var isLoading = false
  @Published private(set) var codexNotice: String?
  @Published private(set) var revision = 0
  @Published private(set) var publicNotices: [String] = []
  var publicDiscovery: () async -> [PublicCatalogResult] = {
    await withTaskGroup(of: PublicCatalogResult.self) { group in
      for provider in PublicPluginCatalog.providers {
        group.addTask {
          do {
            return PublicCatalogResult(
              provider: provider, plugins: try await PublicPluginCatalog.load(provider: provider))
          } catch { return PublicCatalogResult(provider: provider, plugins: [], failed: true) }
        }
      }
      group.addTask {
        do {
          return PublicCatalogResult(
            provider: .openCode, plugins: try await CommunityMCPCatalog.load())
        } catch { return PublicCatalogResult(provider: .openCode, plugins: [], failed: true) }
      }
      var results: [PublicCatalogResult] = []
      for await result in group { results.append(result) }
      return results
    }
  }
  private var requestID: UUID?
  private var subscriptions: Set<AnyCancellable> = []
  var discover: ([String: String]) async -> [ProviderMarketplaceApp]? = { environment in
    await CodexAdapter().discoverMarketplaceApps(environment: environment)
  }
  var inventory: (AgentProvider, String) -> [HarnessPlugin] = { provider, workspace in
    HarnessPluginCatalog.plugins(for: provider, workspacePath: workspace).filter {
      $0.source != HarnessPluginCatalog.ottoSource
    }
  }

  func observe(_ accounts: ProviderAccountStore) {
    guard subscriptions.isEmpty else { return }
    accounts.objectWillChange.sink { [weak self] in
      Task { @MainActor [weak self] in
        self?.requestID = nil
        self?.listings = []
        self?.revision += 1
      }
    }.store(in: &subscriptions)
  }

  func load(accounts: ProviderAccountStore, accountID: UUID?, workspacePath: String) async {
    let token = UUID()
    requestID = token
    isLoading = true
    listings = []
    codexNotice = nil
    publicNotices = []
    defer { if requestID == token { isLoading = false } }
    // Never silently replace a deleted or unresolvable named account with this Mac's login.
    if let accountID, accounts.account(id: accountID) == nil {
      codexNotice = "This account no longer exists. Choose another account."
      return
    }
    var entries: [MarketplaceListing] = []
    let claudeLogin =
      accountID.flatMap { accounts.account(id: $0)?.credentialMode(for: .claudeCode) } ?? .login
    if claudeLogin == .login {
      let url = URL(string: "https://claude.ai/customize/connectors")!
      // These routes are documented by Anthropic. This is a curated starting set, not a live
      // claim that every listed app is eligible under the selected user's plan or organisation.
      for (key, name, summary) in [
        ("gmail", "Gmail", "Read email and find conversations."),
        ("googlecalendar", "Google Calendar", "Look up meetings and manage your schedule."),
        ("microsoft365", "Microsoft 365", "Work with your Microsoft documents and email."),
      ] {
        entries.append(
          MarketplaceListing(
            id: "claude:\(key)", name: name, summary: summary,
            provider: .claudeCode, category: .classify(name), setupURL: url,
            status: "Finish setup in Claude", isInstalled: false, canSetUp: true))
      }
    }
    // Declarations are not proof of authentication. Named account configurations are not read
    // through the machine-default inventory, which would mix identities.
    if accountID == nil {
      for provider in Self.providers {
        for plugin in inventory(provider, workspacePath) {
          let server = HarnessPluginCatalog.authenticationServer(
            named: plugin.name,
            provider: provider, workspacePath: workspacePath)
          entries.append(
            MarketplaceListing(
              id: "local:\(provider.rawValue):\(plugin.id)", name: plugin.name,
              summary:
                "Already configured in \(provider.rawValue). Sign-in is managed by the provider.",
              provider: provider, category: .classify(plugin.name), setupURL: nil,
              status: "Configured", isInstalled: true, canSetUp: server != nil,
              authenticationServer: server))
        }
      }
    }
    // Public metadata does not borrow a login or claim selected-account eligibility.
    let publicResults = await publicDiscovery()
    guard requestID == token else { return }
    for result in publicResults {
      if result.failed {
        publicNotices.append(
          "Could not load \(result.provider.rawValue)'s public catalogue. Refresh to retry.")
      }
      entries += result.plugins.map { plugin in
        MarketplaceListing(
          id: "public:\(plugin.provider.rawValue):\(plugin.id)", name: plugin.name,
          summary: plugin.summary, provider: plugin.provider, category: .classify(plugin.name),
          setupURL: Self.guideURL(for: plugin.provider),
          status: plugin.remoteURL == nil
            ? "Official catalogue · Plugin" : "Community registry · Remote MCP",
          isInstalled: false, canSetUp: true, plugin: plugin)
      }
    }
    listings = entries.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }
    let environment: [String: String]
    if let accountID {
      guard accounts.account(id: accountID)?.credentialMode(for: .codex) == .login else {
        codexNotice = "Native Codex apps require a ChatGPT login, rather than an API key."
        return
      }
      do {
        guard let launch = try await accounts.launchContext(accountID: accountID, provider: .codex)
        else {
          codexNotice = "Could not resolve this account. Choose another account."
          return
        }
        guard requestID == token else { return }
        environment = launch.environment
      } catch {
        guard requestID == token else { return }
        codexNotice =
          "Could not load this account's Codex connections. Check its login in Settings → Accounts."
        return
      }
    } else {
      environment = [:]
    }
    let apps = await discover(environment)
    guard requestID == token else { return }
    guard let apps else {
      codexNotice =
        "Codex's catalogue could not be checked. Sign in to Codex or update its CLI, then refresh."
      return
    }
    entries += apps.map { app in
      MarketplaceListing(
        id: "codex:\(app.id)", name: app.name, summary: app.description,
        provider: .codex, category: .classify(app.name), setupURL: app.installURL,
        status: app.isCallable == true
          ? "Enabled" : (app.isAccessible ? "Available to your account" : "Setup required"),
        isInstalled: app.isCallable == true, canSetUp: app.installURL != nil)
    }
    listings = entries.sorted {
      ($0.name.localizedLowercase, $0.provider.rawValue) < (
        $1.name.localizedLowercase, $1.provider.rawValue
      )
    }
  }

  static func guideURL(for provider: AgentProvider) -> URL? {
    let url: String
    switch provider {
    case .claudeCode: url = "https://code.claude.com/docs/en/discover-plugins"
    case .cursor: url = "https://cursor.com/marketplace"
    case .grok: url = "https://github.com/xai-org/plugin-marketplace"
    case .kimi: url = "https://www.kimi.com/code/docs/en/kimi-code-cli/customization/plugins.html"
    case .openCode: url = "https://opencode.ai/docs/mcp-servers/"
    default: return nil
    }
    return URL(string: url)
  }

  func filtered(
    search: String, category: MarketplaceCategory, provider: AgentProvider?, installedOnly: Bool
  ) -> [MarketplaceListing] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return listings.filter { app in
      (provider == nil || app.provider == provider)
        && (category == .all || app.category == category)
        && (!installedOnly || app.isInstalled)
        && (query.isEmpty
          || "\(app.name) \(app.summary) \(app.provider.rawValue)".localizedCaseInsensitiveContains(
            query))
    }
  }
}

struct PublicCatalogResult: Sendable {
  let provider: AgentProvider
  let plugins: [PublicMarketplacePlugin]
  var failed = false
}

import AppKit
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

struct MarketplaceView: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var connections: AppConnectionsStore
  @ObservedObject var accounts: ProviderAccountStore
  let workspacePath: String
  var initialAccountID: UUID? = nil
  var onClose: (() -> Void)? = nil
  @StateObject private var catalog = MarketplaceCatalogStore()
  @State private var search = ""
  @State private var category: MarketplaceCategory = .all
  @State private var provider: AgentProvider?
  @State private var accountID: UUID?
  @State private var yourApps = false
  @State private var selected: MarketplaceListing?
  @State private var showingAdvanced = false
  @State private var notice: String?
  @State private var awaitingReturn = false
  @State private var workingID: String?
  @State private var actionMessage: String?
  @State private var cursorLinks: [CursorMCPInstallLink] = []

  init(
    connections: AppConnectionsStore, accounts: ProviderAccountStore, workspacePath: String,
    initialAccountID: UUID? = nil, onClose: (() -> Void)? = nil
  ) {
    self.connections = connections
    self.accounts = accounts
    self.workspacePath = workspacePath
    self.initialAccountID = initialAccountID
    self.onClose = onClose
    _accountID = State(initialValue: initialAccountID)
  }

  private var request: String { "\(accountID?.uuidString ?? "mac"):\(catalog.revision)" }
  private var visible: [MarketplaceListing] {
    catalog.filtered(
      search: search, category: category, provider: provider, installedOnly: yourApps)
  }

  private var popular: [MarketplaceListing] {
    guard !yourApps, search.isEmpty, category == .all else { return [] }
    let names = [
      "gmail", "googlecalendar", "slack", "notion", "googledrive", "github", "linear",
      "microsoft365",
    ]
    return Array(
      visible.filter { $0.canSetUp && names.contains(PluginBrand.normalize($0.name)) }.prefix(8))
  }
  private var remaining: [MarketplaceListing] {
    let popularIDs = Set(popular.map(\.id))
    return visible.filter { !popularIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Marketplace").font(.ottoDisplay(23).weight(.semibold))
        Spacer()
        Button {
          yourApps.toggle()
          category = .all
          search = ""
        } label: {
          HStack(spacing: 7) {
            Image(systemName: "square.stack.3d.up")
            Text(yourApps ? "Browse apps" : "Your apps")
            Image(systemName: "chevron.right").font(.system(size: 9))
          }
        }.buttonStyle(.plain).foregroundStyle(palette.muted)
          .accessibilityIdentifier("marketplace.your-apps")
        if let onClose {
          Button(action: onClose) { Image(systemName: "xmark") }
            .buttonStyle(.plain).padding(.leading, 12).accessibilityLabel("Close marketplace")
        }
      }
      HStack(spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
          TextField("Search apps and integrations", text: $search).textFieldStyle(.plain)
            .accessibilityIdentifier("marketplace.search")
        }.padding(10).background(palette.paper.opacity(0.055), in: Capsule())
        Picker("Provider", selection: $provider) {
          Text("All providers").tag(nil as AgentProvider?)
          ForEach(MarketplaceCatalogStore.providers, id: \.self) { item in
            Text(item.rawValue).tag(Optional(item))
          }
        }.labelsHidden().frame(width: 140).accessibilityLabel("Filter marketplace by provider")
      }
      HStack(spacing: 7) {
        ForEach(MarketplaceCategory.allCases) { item in
          Button(item.rawValue) { category = item }
            .buttonStyle(.plain).font(.ottoDisplay(12))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(category == item ? palette.surface : palette.paper.opacity(0.85))
            .background(
              category == item ? palette.paper : palette.paper.opacity(0.06), in: Capsule()
            )
            .accessibilityAddTraits(category == item ? .isSelected : [])
        }
        Spacer()
      }
      HStack {
        Text("Apps, plugins and connections from your providers.")
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        Spacer()
        Picker("Account", selection: $accountID) {
          Text("This Mac's login").tag(nil as UUID?)
          ForEach(accounts.accounts) { account in Text(account.name).tag(Optional(account.id)) }
        }.labelsHidden().frame(maxWidth: 160).accessibilityLabel("Provider account for marketplace")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let notice {
            Text(notice).font(.ottoDisplay(12)).foregroundStyle(palette.signal)
          }
          if yourApps, !connections.accounts.isEmpty {
            Button {
              showingAdvanced = true
            } label: {
              HStack {
                logo("Gmail")
                VStack(alignment: .leading, spacing: 3) {
                  Text("Gmail in Otto").font(.ottoDisplay(14).weight(.medium))
                  Text("\(connections.accounts.count) account(s) · Manage shared access")
                    .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
              }.padding(12)
            }.buttonStyle(.plain)
          }
          if !popular.isEmpty {
            Text("Popular apps").font(.ottoDisplay(14).weight(.medium))
            LazyVGrid(
              columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], spacing: 8
            ) {
              ForEach(popular) { app in row(app) }
            }
          }
          HStack {
            Text(yourApps ? "Your provider apps" : "Apps & integrations")
              .font(.ottoDisplay(14).weight(.medium))
            Spacer()
            if catalog.isLoading { ProgressView().controlSize(.small) }
            Text("\(visible.count)").font(.ottoMono(10)).foregroundStyle(palette.muted)
          }
          LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 22), GridItem(.flexible())], spacing: 8
          ) {
            ForEach(remaining) { app in row(app) }
          }
          if visible.isEmpty, !catalog.isLoading {
            VStack(alignment: .leading, spacing: 8) {
              Text(search.isEmpty ? "No apps to show yet" : "No results for “\(search)”")
                .font(.ottoDisplay(15).weight(.medium))
              Text(emptyExplanation).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
            }.padding(.vertical, 28)
          }
          ForEach(catalog.publicNotices, id: \.self) { message in
            Text(message).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          }
          if let provider, PublicPluginCatalog.providers.contains(provider) {
            Text(
              "Official plugin catalogue. Installing a plugin may still require account sign-in. Availability depends on the provider."
            )
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            if provider == .cursor {
              Text("Cursor's official repository is a subset of its marketplace.")
                .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
          }
          if provider == .openCode {
            Text(
              "Community remote MCP servers from the first 500 registry records, plus configured OpenCode tools. A listing may require a service plan, API key or custom setup."
            )
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            Button("Add an OpenCode connection ↗") {
              openSetup(MarketplaceCatalogStore.guideURL(for: .openCode)!)
            }.buttonStyle(.plain).font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
          }
          if let message = catalog.codexNotice, provider == nil || provider == .codex {
            Text(message).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            if accountID == nil
              || accounts.account(id: accountID)?.credentialMode(for: .codex) == .login
            {
              Button("Browse Codex connections ↗") {
                if NSWorkspace.shared.open(URL(string: "https://chatgpt.com/plugins")!) {
                  awaitingReturn = true
                }
              }.buttonStyle(.plain).font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
            }
          }
          if !yourApps, provider == nil || provider == .claudeCode,
            catalog.listings.contains(where: { $0.provider == .claudeCode })
          {
            Button("Browse all Claude connections ↗") { openClaudeDirectory() }
              .buttonStyle(.plain).font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
            Text(
              "Claude Code plugins and Claude account connectors have separate setup flows. Claude checks connector availability on its connection screen."
            )
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          }
        }.padding(.vertical, 5)
      }
      Divider()
      HStack {
        Button("Refresh") { refresh() }.disabled(catalog.isLoading)
          .accessibilityIdentifier("marketplace.refresh")
        Spacer()
        Text("Connections apply to the provider you choose.").font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
        Button("Advanced") { showingAdvanced = true }.accessibilityIdentifier(
          "marketplace.advanced")
      }.buttonStyle(.plain).font(.ottoDisplay(12))
    }
    .padding(28).frame(width: 800, height: 640)
    .foregroundStyle(palette.paper).background(palette.surface)
    .task {
      catalog.observe(accounts)
    }
    .task(id: request) {
      selected = nil
      actionMessage = nil
      await catalog.load(accounts: accounts, accountID: accountID, workspacePath: workspacePath)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active, awaitingReturn {
        awaitingReturn = false
        refresh()
      }
    }
    .sheet(item: $selected) { detail($0) }
    .interactiveDismissDisabled(workingID != nil)
    .sheet(isPresented: $showingAdvanced) {
      AppConnectionsView(connections: connections, onClose: { showingAdvanced = false })
    }
  }

  private var emptyExplanation: String {
    if provider == .openCode {
      return
        "Add a remote MCP server in OpenCode first, then refresh. Hermes manages its own connections."
    }
    if yourApps {
      return
        "Native sign-in is managed by your provider. Refresh after completing setup. Configured tools may still need authentication."
    }
    return "Try another category or provider, or refresh after signing in."
  }

  private func logo(_ name: String) -> some View {
    let brand = PluginBrand.style(for: name)
    return Group {
      if let spec = PluginBrand.logo(for: name),
        let image = PluginLogoAssets.image(named: spec.asset, kind: spec.kind)
      {
        Image(nsImage: image).resizable().scaledToFit().padding(7)
      } else {
        Text(brand.mark).font(.ottoDisplay(15).weight(.semibold))
      }
    }.frame(width: 40, height: 40)
      .background(palette.paper.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
  }

  private func row(_ app: MarketplaceListing) -> some View {
    Button {
      selected = app
      actionMessage = nil
      cursorLinks = []
    } label: {
      HStack(spacing: 10) {
        logo(app.name)
        VStack(alignment: .leading, spacing: 3) {
          Text(app.name).font(.ottoDisplay(13).weight(.medium)).lineLimit(1)
          Text(app.summary.isEmpty ? app.status : app.summary)
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted).lineLimit(1)
          Text(
            app.provider.rawValue
              + (app.plugin != nil
                ? (app.plugin?.remoteURL == nil ? " · Plugin" : " · Community MCP")
                : (app.isInstalled ? " · \(app.status)" : ""))
          )
          .font(.ottoDisplay(10)).foregroundStyle(palette.muted)
        }
        Spacer(minLength: 0)
        Text(rowAction(app))
          .font(.ottoDisplay(11)).padding(.horizontal, 10).padding(.vertical, 5)
          .background(palette.paper.opacity(0.06), in: Capsule())
      }.padding(.vertical, 9).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel("\(app.name), \(app.provider.rawValue), \(app.status)")
  }

  private func detail(_ app: MarketplaceListing) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          logo(app.name)
          Text(app.name).font(.ottoDisplay(22).weight(.semibold))
          Spacer()
        }
        Text(app.summary).font(.ottoDisplay(13)).foregroundStyle(palette.muted).lineLimit(6)
        Text(app.status).font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
        if let plugin = app.plugin, let url = plugin.remoteURL {
          Text(
            "Community MCP connection. This adds a remote server to this Mac's OpenCode configuration and starts OpenCode's browser sign-in flow. Your existing settings are preserved."
          )
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          Text(url.absoluteString).font(.ottoMono(11)).textSelection(.enabled)
          Link("View community registry ↗", destination: plugin.sourceURL)
          Text(
            "Registry presence does not guarantee OAuth support or free access. Some servers require an API key or their own setup; a successful setup command is not proof the tools are available."
          )
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          if accountID != nil {
            Text(
              "Choose This Mac's login to add this connection. Named accounts use separate authentication and are not changed here."
            )
            .font(.ottoDisplay(12)).foregroundStyle(palette.signal)
          }
        } else if let plugin = app.plugin {
          Text(
            "A plugin can add tools, skills or workflows. Installation does not connect your external account."
          )
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          Link("View official catalogue ↗", destination: plugin.sourceURL)
            .font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
          if plugin.nativeInstall {
            Text(
              "Install for this Mac's \(app.provider.rawValue) user. The provider may require trust or sign-in before tools become available."
            )
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
            if accountID != nil {
              Text(
                "Choose This Mac's login to install. Named account plugin folders may share files with the Mac, so Otto does not install through a named account."
              )
              .font(.ottoDisplay(12)).foregroundStyle(palette.signal)
            }
          } else {
            Text(
              app.provider == .kimi
                ? "Kimi installs plugins in its interactive plugin manager. Copy the setup command below and run it in Kimi."
                : "Find this plugin in Cursor's marketplace and complete its native installation there."
            )
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
            if app.provider == .cursor, !cursorLinks.isEmpty {
              Text(
                "Connect a remote tool directly through Cursor. This installs its MCP connection, rather than the full plugin package."
              )
              .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
              ForEach(cursorLinks) { link in
                VStack(alignment: .leading, spacing: 4) {
                  Text(link.serverURL.absoluteString).font(.ottoMono(10)).textSelection(.enabled)
                  Button("Connect \(link.id) with Cursor ↗") {
                    openSetup(link.installURL)
                  }.disabled(accountID != nil)
                }
              }
              if accountID != nil {
                Text(
                  "Direct Cursor install uses this Mac's Cursor account. Choose This Mac's login to continue."
                )
                .font(.ottoDisplay(11)).foregroundStyle(palette.signal)
              }
            }
            if app.provider == .kimi, let source = plugin.installSource {
              Text("/plugins install \(source)").font(.ottoMono(11)).textSelection(.enabled)
              Button("Copy Kimi setup command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("/plugins install \(source)", forType: .string)
              }
            }
          }
        } else if app.authenticationServer != nil {
          Text(
            "Open \(app.provider.rawValue)'s sign-in flow for this configured remote connection. If it needs an API key or custom setup, the provider will need to finish setup instead."
          )
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        } else {
          Text(
            app.canSetUp
              ? "Sign in on \(app.provider.rawValue)'s connection screen, then return to Otto."
              : "This integration is configured in \(app.provider.rawValue). Manage its sign-in and settings there."
          )
          .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          if app.provider == .claudeCode, app.canSetUp {
            Text(
              "Choose \(app.name) on Claude's connections page. Its availability depends on your plan and organisation."
            )
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          }
        }
        if let actionMessage {
          Text(actionMessage).font(.ottoDisplay(12)).foregroundStyle(palette.signal)
        }
        Text(
          "Available through \(app.provider.rawValue). Other providers use their own connections."
        )
        .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        if accountID != nil {
          Text("Check that the browser is signed in to the same account you selected in Otto.")
            .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        }
        HStack {
          Button("Back") { selected = nil }.disabled(workingID != nil)
          Spacer()
          if workingID == app.id { ProgressView().controlSize(.small) }
          Button(detailAction(app)) { perform(app) }
            .buttonStyle(.borderedProminent).tint(palette.cyan)
            .disabled(
              !app.canSetUp || workingID != nil
                || ((app.plugin?.nativeInstall == true || app.plugin?.remoteURL != nil)
                  && accountID != nil)
            )

        }
      }.padding(26)
    }.frame(width: 480, height: 600).foregroundStyle(palette.paper).background(palette.surface)
      .task(id: app.id) {
        cursorLinks = []
        if let plugin = app.plugin, plugin.provider == .cursor {
          let links = await CursorMCPInstallLinks.load(plugin)
          guard selected?.id == app.id else { return }
          cursorLinks = links
        }
      }
  }

  private func rowAction(_ app: MarketplaceListing) -> String {
    if let plugin = app.plugin {
      if plugin.remoteURL != nil { return "Connect" }
      return plugin.nativeInstall ? "Install" : "Set up"
    }
    if app.authenticationServer != nil { return "Sign in" }
    return app.canSetUp ? (app.isInstalled ? "Manage" : "Connect") : "Details"
  }

  private func detailAction(_ app: MarketplaceListing) -> String {
    if let plugin = app.plugin {
      if plugin.remoteURL != nil { return "Connect with OpenCode" }
      return plugin.nativeInstall
        ? "Install with \(app.provider.rawValue)" : "Set up with \(app.provider.rawValue) ↗"
    }
    if app.authenticationServer != nil { return "Sign in with \(app.provider.rawValue)" }
    return !app.canSetUp
      ? "No setup link"
      : "\(app.isInstalled ? "Manage" : "Connect") with \(app.provider.rawValue) ↗"
  }

  private func perform(_ app: MarketplaceListing) {
    guard app.canSetUp, workingID == nil else { return }
    if let plugin = app.plugin, plugin.remoteURL != nil {
      guard accountID == nil else { return }
      workingID = app.id
      actionMessage = "Complete the sign-in opened by OpenCode."
      Task {
        let result = await MarketplaceInstaller.connectRemote(plugin)
        workingID = nil
        actionMessage =
          result == .installed
          ? "OpenCode setup finished. Open a new session to check available tools."
          : "Setup needs attention in OpenCode. The server may need an API key or custom setup, or your configuration may require a manual addition. A newly added server remains configured for you to manage in OpenCode."
      }
    } else if let plugin = app.plugin, plugin.nativeInstall {
      guard accountID == nil else { return }
      workingID = app.id
      actionMessage = "Installing with \(app.provider.rawValue)…"
      Task {
        let result = await MarketplaceInstaller.install(plugin)
        workingID = nil
        switch result {
        case .installed:
          actionMessage =
            "Installed. Open a new provider session; complete any trust or account sign-in it requests."
          notice =
            "\(app.name) installed with \(app.provider.rawValue). Account sign-in may still be required."
        case .unavailable:
          actionMessage = "The provider CLI is unavailable. Install or update it, then retry."
        case .needsProviderSetup:
          actionMessage =
            "Installation needs attention in the provider. Use its plugin manager to review trust, setup or installation errors."
        case .timedOut:
          actionMessage =
            "Installation timed out. Check the provider's plugin manager before retrying."
        }
      }
    } else if let server = app.authenticationServer {
      guard accountID == nil else { return }
      workingID = app.id
      actionMessage = "Complete sign-in in the browser opened by \(app.provider.rawValue)."
      Task {
        let result = await MarketplaceInstaller.authenticate(
          provider: app.provider, server: server,
          workspace: workspacePath)
        workingID = nil
        actionMessage =
          result == .installed
          ? "Provider sign-in finished. Open a new provider session to check available tools."
          : "Sign-in did not finish. Check this connection in the provider; it may require an API key, custom setup or an updated CLI."
      }
    } else if let url = app.setupURL {
      openSetup(url)
    }
  }

  private func openSetup(_ url: URL) {
    if NSWorkspace.shared.open(url) {
      notice = "Finish setup in your provider, then return and refresh."
      awaitingReturn = true
      selected = nil
    } else {
      actionMessage = "Could not open setup. Please try again."
    }
  }

  private func refresh() {
    Task {
      await catalog.load(accounts: accounts, accountID: accountID, workspacePath: workspacePath)
    }
  }
  private func openClaudeDirectory() {
    if NSWorkspace.shared.open(URL(string: "https://claude.ai/customize/connectors")!) {
      awaitingReturn = true
    }
  }
}

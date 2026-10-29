import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI

/// Account data and actions for agent cards and composers, injected once at the window root so
/// every card can show and switch its provider account without threading extra closures.
@MainActor
final class ProviderAccountUIContext {
  let store: ProviderAccountStore
  let effectiveAccountID: (UUID) -> UUID?
  /// The account the node would use without its own choice (project, then global default).
  let inheritedAccountID: (UUID) -> UUID?
  let setAccount: (UUID?, UUID) -> Void
  let limits: ProviderUsageLimitCenter
  let continueOnAccount: (UUID, UUID) -> Void
  let waitForReset: (UUID) -> Void
  let dismissLimit: (UUID) -> Void

  init(
    store: ProviderAccountStore,
    limits: ProviderUsageLimitCenter = ProviderUsageLimitCenter(),
    continueOnAccount: @escaping (UUID, UUID) -> Void = { _, _ in },
    waitForReset: @escaping (UUID) -> Void = { _ in },
    dismissLimit: @escaping (UUID) -> Void = { _ in },
    effectiveAccountID: @escaping (UUID) -> UUID?,
    inheritedAccountID: @escaping (UUID) -> UUID?,
    setAccount: @escaping (UUID?, UUID) -> Void
  ) {
    self.store = store
    self.limits = limits
    self.continueOnAccount = continueOnAccount
    self.waitForReset = waitForReset
    self.dismissLimit = dismissLimit
    self.effectiveAccountID = effectiveAccountID
    self.inheritedAccountID = inheritedAccountID
    self.setAccount = setAccount
  }

  convenience init(services: ApplicationServices) {
    self.init(
      store: services.providerAccounts,
      limits: services.usageLimits,
      continueOnAccount: { [weak services] nodeID, accountID in
        Task { await services?.continueAfterUsageLimit(nodeID: nodeID, accountID: accountID) }
      },
      waitForReset: { [weak services] nodeID in
        Task { await services?.waitForUsageLimitReset(nodeID: nodeID) }
      },
      dismissLimit: { [weak services] in services?.dismissUsageLimit(nodeID: $0) },
      effectiveAccountID: { [weak services] in services?.effectiveAccountID(nodeID: $0) },
      inheritedAccountID: { [weak services] in
        services?.effectiveAccountID(nodeID: $0, ignoringAgentChoice: true)
      },
      setAccount: { [weak services] accountID, nodeID in
        Task { try? await services?.setAccount(accountID, forAgent: nodeID) }
      })
  }
}

extension ProviderAccountUIContext {
  private static var cache: [ObjectIdentifier: ProviderAccountUIContext] = [:]

  /// One stable context per services instance, so injecting it never invalidates card views.
  static func shared(for services: ApplicationServices) -> ProviderAccountUIContext {
    let key = ObjectIdentifier(services)
    if let existing = cache[key] { return existing }
    let context = ProviderAccountUIContext(services: services)
    cache[key] = context
    return context
  }
}

private struct ProviderAccountUIContextKey: EnvironmentKey {
  static let defaultValue: ProviderAccountUIContext? = nil
}

extension EnvironmentValues {
  var providerAccounts: ProviderAccountUIContext? {
    get { self[ProviderAccountUIContextKey.self] }
    set { self[ProviderAccountUIContextKey.self] = newValue }
  }
}

extension ProviderAccountColor {
  var color: Color {
    let value = UInt32(hex, radix: 16) ?? 0
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

/// Which account an agent bills to, as a chip (composer) or badge (canvas footer). Hidden until
/// the user has created at least one account, so single-subscription users see nothing new.
struct AgentAccountChip: View {
  enum Style { case composer, badge }

  let node: OttoNode
  let scale: Double
  var style: Style = .composer

  @Environment(\.providerAccounts) private var context
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    if let context, let definition = node.agentDefinition,
      definition.provider.supportsProviderAccounts
    {
      AccountChipContent(
        store: context.store, context: context, node: node, definition: definition,
        scale: scale, style: style, palette: palette)
    }
  }
}

private struct AccountChipContent: View {
  @ObservedObject var store: ProviderAccountStore
  let context: ProviderAccountUIContext
  let node: OttoNode
  let definition: AgentDefinition
  let scale: Double
  let style: AgentAccountChip.Style
  let palette: OttoPalette
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    if !store.accounts.isEmpty {
      let effective = store.account(id: context.effectiveAccountID(node.id))
      Menu {
        Button {
          context.setAccount(nil, node.id)
        } label: {
          menuLabel(inheritedTitle, checked: definition.accountID == nil)
        }
        Divider()
        ForEach(store.accounts) { account in
          Button {
            context.setAccount(account.id, node.id)
          } label: {
            menuLabel(account.name, checked: definition.accountID == account.id)
          }
        }
        Divider()
        Button("Manage accounts…") { openSettings() }
      } label: {
        label(for: effective)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(
        "Provider account for this agent. Switching starts a fresh provider session on the next run."
      )
      .accessibilityLabel("Account: \(effective?.name ?? "This Mac's login")")
    }
  }

  private var inheritedTitle: String {
    let inherited = store.account(id: context.inheritedAccountID(node.id))
    return "Use default (\(inherited?.name ?? "this Mac's login"))"
  }

  @ViewBuilder private func label(for account: ProviderAccount?) -> some View {
    let tint = account?.color.color ?? palette.muted
    HStack(spacing: 4 * scale) {
      Circle()
        .fill(tint)
        .frame(width: 6 * scale, height: 6 * scale)
      Text(account?.name ?? "Mac login")
        .font(.ottoMono(max(6, 7 * scale), weight: .bold))
        .lineLimit(1)
    }
    .foregroundStyle(account == nil ? palette.muted : tint)
    .padding(.horizontal, 7 * scale)
    .frame(height: (style == .composer ? 17 : 15) * scale)
    .background(
      (account.map { $0.color.color.opacity(0.14) } ?? palette.raised.opacity(0.75)),
      in: Capsule())
  }

  @ViewBuilder private func menuLabel(_ title: String, checked: Bool) -> some View {
    if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
  }
}

/// Shown above the composer when the agent's last run stopped on an account usage limit.
struct AgentUsageLimitCard: View {
  let nodeID: UUID
  let scale: Double
  @Environment(\.providerAccounts) private var context

  var body: some View {
    if let context {
      UsageLimitCardContent(limits: context.limits, context: context, nodeID: nodeID, scale: scale)
    }
  }
}

private struct UsageLimitCardContent: View {
  @ObservedObject var limits: ProviderUsageLimitCenter
  let context: ProviderAccountUIContext
  let nodeID: UUID
  let scale: Double
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    if let notice = limits.notices[nodeID] {
      VStack(alignment: .leading, spacing: 8 * scale) {
        HStack(spacing: 6 * scale) {
          Circle().fill(palette.amber).frame(width: 7 * scale, height: 7 * scale)
          Text("\(notice.accountName) reached its usage limit")
            .font(.ottoDisplay(max(10, 12 * scale)))
            .foregroundStyle(palette.paper)
          Spacer()
          if let resetsAt = notice.limit.resetsAt {
            Text("Resets \(resetsAt.formatted(date: .omitted, time: .shortened))")
              .font(.ottoMono(max(7, 8 * scale), weight: .medium))
              .foregroundStyle(palette.muted)
          }
          Button {
            context.dismissLimit(nodeID)
          } label: {
            Image(systemName: "xmark").font(.system(size: max(8, 9 * scale)))
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.muted)
          .help("Dismiss")
        }
        Text(summary(notice))
          .font(.system(size: max(9, 11 * scale)))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8 * scale) {
          if let first = notice.alternatives.first {
            Button {
              context.continueOnAccount(nodeID, first.id)
            } label: {
              HStack(spacing: 5 * scale) {
                Circle().fill(first.color.color).frame(width: 6 * scale, height: 6 * scale)
                Text("Continue on \(first.name)")
              }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            if notice.alternatives.count > 1 {
              Menu("Other account") {
                ForEach(notice.alternatives.dropFirst()) { account in
                  Button(account.name) { context.continueOnAccount(nodeID, account.id) }
                }
              }
              .controlSize(.small)
              .fixedSize()
            }
          }
          if notice.limit.resetsAt != nil, notice.scheduledResumeAt == nil, !notice.prompt.isEmpty {
            Button("Wait and resume") { context.waitForReset(nodeID) }
              .controlSize(.small)
          }
        }
      }
      .padding(10 * scale)
      .background(palette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10 * scale))
      .overlay(
        RoundedRectangle(cornerRadius: 10 * scale).stroke(palette.amber.opacity(0.35), lineWidth: 1)
      )
      .padding(.horizontal, 12 * scale)
      .padding(.top, 8 * scale)
    }
  }

  private func summary(_ notice: ProviderUsageLimitNotice) -> String {
    if let resumeAt = notice.scheduledResumeAt {
      return
        "Otto will re-run your last message on \(notice.accountName) at \(resumeAt.formatted(date: .omitted, time: .shortened)). Your conversation and files are safe."
    }
    if notice.alternatives.isEmpty {
      return
        "\(notice.limit.message)\nAdd another account in Settings → Accounts to continue on a different subscription."
    }
    return
      "The run stopped. Your conversation and files are safe — continue on another account, or wait for the reset."
  }
}

// MARK: - Settings

struct ProviderAccountsSettingsView: View {
  let services: ApplicationServices
  @ObservedObject private var store: ProviderAccountStore
  @State private var newAccountName = ""
  @State private var message: String?
  @State private var isError = false

  init(services: ApplicationServices) {
    self.services = services
    self.store = services.providerAccounts
  }

  var body: some View {
    Form {
      Section {
        Text(
          "Use more than one subscription — for example your company's Claude and ChatGPT seats and your own. Each agent runs on the account you choose; projects can set a default. Otto never sees provider logins: each provider signs in with its own login, stored separately per account."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Picker(
          "Default account",
          selection: Binding(
            get: { store.defaultAccountID },
            set: { id in perform { try store.setDefault(id) } })
        ) {
          Text("This Mac's existing logins").tag(UUID?.none)
          ForEach(store.accounts) { account in
            Text(account.name).tag(UUID?.some(account.id))
          }
        }
        Text("Agents without their own account or project default use this.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(store.accounts) { account in
        ProviderAccountSection(
          account: account, store: store, services: services,
          report: { text, error in
            message = text
            isError = error
          })
      }

      Section("Add account") {
        HStack {
          TextField("Name, e.g. Work or Personal", text: $newAccountName)
            .textFieldStyle(.roundedBorder)
            .onSubmit(addAccount)
          Button("Add", action: addAccount)
            .disabled(newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }

      if let message {
        Text(message).foregroundStyle(isError ? Color.red : Color.secondary)
      }
      if let error = store.persistenceError {
        Text(error).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .frame(width: 760, height: 650)
  }

  private func addAccount() {
    perform {
      try store.create(name: newAccountName)
      newAccountName = ""
    }
  }

  private func perform(_ action: () throws -> Void) {
    do {
      try action()
      message = nil
    } catch {
      message = error.localizedDescription
      isError = true
    }
  }
}

private struct ProviderAccountSection: View {
  let account: ProviderAccount
  let store: ProviderAccountStore
  let services: ApplicationServices
  let report: (String, Bool) -> Void

  @State private var name = ""
  @State private var keyStatus: [String: Bool] = [:]
  @State private var keyDrafts: [String: String] = [:]
  @State private var confirmingDelete = false
  @State private var refreshToken = 0
  /// Per-provider login feedback shown under that row, not at the bottom of the form.
  @State private var loginNotes: [AgentProvider: String] = [:]
  @State private var loginErrors: Set<AgentProvider> = []
  /// Re-evaluates "Signed in" while Settings is open so a finished Terminal login shows up.
  @State private var loginTick = 0

  private static let providers: [AgentProvider] = [
    .claudeCode, .codex, .grok, .kimi, .cursor, .openCode, .pi, .hermes,
  ]
  private static let harnessBackends: [(key: String, name: String)] = [
    ("openai.api-key", "OpenAI"), ("anthropic.api-key", "Anthropic"), ("xai.api-key", "xAI"),
    ("moonshot.api-key", "Moonshot"),
  ]

  var body: some View {
    Section {
      HStack(spacing: 10) {
        Picker("", selection: colorBinding) {
          ForEach(ProviderAccountColor.allCases, id: \.self) { color in
            Label(color.rawValue.capitalized, systemImage: "circle.fill")
              .foregroundStyle(color.color)
              .tag(color)
          }
        }
        .labelsHidden()
        .frame(width: 110)
        TextField("Account name", text: $name)
          .textFieldStyle(.roundedBorder)
          .onSubmit { update { $0.name = name } }
        if store.defaultAccountID == account.id {
          Text("Default").font(.caption).foregroundStyle(.secondary)
        }
        Button("Delete…", role: .destructive) { confirmingDelete = true }
      }
      Toggle(
        "Share settings, skills and instructions with this Mac's main login",
        isOn: Binding(
          get: { account.sharesProviderConfiguration },
          set: { value in update { $0.sharesProviderConfiguration = value } })
      )
      .font(.callout)

      ForEach(Self.providers, id: \.self) { provider in
        providerRow(provider)
      }

      DisclosureGroup("Otto Harness API keys") {
        ForEach(Self.harnessBackends, id: \.key) { backend in
          keyRow(
            id: "harness.\(backend.key)", title: backend.name,
            save: { value in
              try await store.setHarnessKey(
                value, accountID: account.id, credentialKey: backend.key)
            })
        }
        Text("Used by OpenAI API agents on this account. Empty falls back to Settings → Models.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      HStack(spacing: 6) {
        Circle().fill(account.color.color).frame(width: 9, height: 9)
        Text(account.name)
      }
    }
    .onAppear { name = account.name }
    .task(id: refreshToken) { await refreshKeys() }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        loginTick &+= 1
      }
    }
    .confirmationDialog(
      "Delete \(account.name)?", isPresented: $confirmingDelete, titleVisibility: .visible
    ) {
      Button("Delete account and its logins", role: .destructive) {
        Task {
          do { try await store.delete(account.id) } catch {
            report(error.localizedDescription, true)
          }
        }
      }
    } message: {
      Text(
        "Removes this account's stored API keys and provider logins from this Mac. Agents using it fall back to their default account."
      )
    }
  }

  @ViewBuilder private func providerRow(_ provider: AgentProvider) -> some View {
    let isolation = ProviderAccountIsolation.descriptor(for: provider)
    let mode = account.credentialMode(for: provider)
    let _ = loginTick
    let status =
      mode == .login
      ? store.loginStatus(accountID: account.id, provider: provider) : .signedOut
    let signedIn = status != .signedOut
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        AgentProviderLogo(provider: provider, size: 14, color: .primary)
        Text(provider.rawValue).frame(width: 110, alignment: .leading)
        Picker("", selection: modeBinding(provider)) {
          if isolation.supportsLogin { Text("Own login").tag(ProviderAccountCredentialMode.login) }
          if isolation.supportsAPIKey { Text("API key").tag(ProviderAccountCredentialMode.apiKey) }
          Text("This Mac's").tag(ProviderAccountCredentialMode.systemDefault)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
        Spacer()
        if mode == .login {
          loginBadge(status)
          Button(signedIn ? "Log in again" : "Log in") { startLogin(provider) }
        }
      }
      Text(modeExplanation(mode, provider: provider))
        .font(.caption)
        .foregroundStyle(.secondary)
      if case .sameAsMac(let identity) = status {
        Text(
          "This is the same \(provider.rawValue) account this Mac already uses\(identity.label.map { " (\($0))" } ?? ""), so \(account.name) isn't separate. Your browser was probably still signed in to it. Choose Log in again and sign in to the other account in a private browser window."
        )
        .font(.caption)
        .foregroundStyle(Color.orange)
        .fixedSize(horizontal: false, vertical: true)
      }
      if let note = loginNotes[provider], !(signedIn && !loginErrors.contains(provider)) {
        Text(note)
          .font(.caption)
          .foregroundStyle(loginErrors.contains(provider) ? Color.red : Color.accentColor)
      }
      if mode == .apiKey {
        keyRow(
          id: "cli.\(provider.rawValue)", title: "\(provider.rawValue) API key",
          save: { value in
            try await store.setAPIKey(value, accountID: account.id, provider: provider)
          })
      }
    }
    .id("\(provider.rawValue)-\(refreshToken)")
  }

  @ViewBuilder private func loginBadge(_ status: ProviderLoginStatus) -> some View {
    switch status {
    case .signedOut:
      Label("Not signed in", systemImage: "person.crop.circle.badge.exclamationmark")
        .font(.caption)
        .foregroundStyle(Color.orange)
    case .signedIn(let identity):
      Label(
        identity?.label.map { "Signed in as \($0)" } ?? "Signed in",
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption)
      .foregroundStyle(Color.green)
      .lineLimit(1)
      .truncationMode(.middle)
      .help(identity?.label ?? "Signed in")
    case .sameAsMac:
      Label("Same as this Mac's login", systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(Color.orange)
    }
  }

  private func modeExplanation(_ mode: ProviderAccountCredentialMode, provider: AgentProvider)
    -> String
  {
    switch mode {
    case .login:
      "Signs in to \(provider.rawValue) separately for \(account.name). Agents on this account use that login, not the one already on this Mac."
    case .apiKey:
      "Agents on \(account.name) use this API key, billed per use instead of a subscription."
    case .systemDefault:
      "Not separated: agents on \(account.name) use whichever \(provider.rawValue) login this Mac already has."
    }
  }

  private func keyRow(
    id: String, title: String, save: @escaping (String?) async throws -> Void
  ) -> some View {
    HStack {
      SecureField(title, text: draftBinding(id))
        .textFieldStyle(.roundedBorder)
      Button("Save") {
        let value = keyDrafts[id]
        Task {
          do {
            try await save(value)
            keyDrafts[id] = ""
            refreshToken += 1
          } catch { report(error.localizedDescription, true) }
        }
      }
      .disabled((keyDrafts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
      if keyStatus[id] == true {
        Button("Remove", role: .destructive) {
          Task {
            try? await save(nil)
            refreshToken += 1
          }
        }
      }
      Image(systemName: keyStatus[id] == true ? "checkmark.shield.fill" : "key.slash")
        .foregroundStyle(keyStatus[id] == true ? Color.green : Color.secondary)
    }
  }

  private func refreshKeys() async {
    var status: [String: Bool] = [:]
    for provider in Self.providers {
      status["cli.\(provider.rawValue)"] = await store.hasAPIKey(
        accountID: account.id, provider: provider)
    }
    for backend in Self.harnessBackends {
      status["harness.\(backend.key)"] = await store.hasHarnessKey(
        accountID: account.id, credentialKey: backend.key)
    }
    keyStatus = status
  }

  private func startLogin(_ provider: AgentProvider) {
    loginErrors.remove(provider)
    loginNotes[provider] = "Opening Terminal…"
    Task {
      do {
        try await services.startProviderLogin(accountID: account.id, provider: provider)
        loginNotes[provider] =
          "Finish signing in in the Terminal window. Use a private browser window so you don't reuse the account your browser is already signed in to. This updates automatically."
      } catch {
        loginErrors.insert(provider)
        loginNotes[provider] = error.localizedDescription
      }
    }
  }

  private var colorBinding: Binding<ProviderAccountColor> {
    Binding(get: { account.color }, set: { color in update { $0.color = color } })
  }

  private func modeBinding(_ provider: AgentProvider) -> Binding<ProviderAccountCredentialMode> {
    Binding(
      get: { account.credentialMode(for: provider) },
      set: { mode in update { $0.credentialModes[provider] = mode } })
  }

  private func draftBinding(_ id: String) -> Binding<String> {
    Binding(get: { keyDrafts[id] ?? "" }, set: { keyDrafts[id] = $0 })
  }

  private func update(_ change: (inout ProviderAccount) -> Void) {
    var next = account
    change(&next)
    do { try store.update(next) } catch { report(error.localizedDescription, true) }
  }
}

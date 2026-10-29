import OttoModels
import OttoServices
import SwiftUI

/// Every connector Otto can use, shown as tiles. Each tile opens that connector's setup and the
/// list of Otto bots allowed to use it.
struct ConnectorsSettingsView: View {
  let services: ApplicationServices
  @ObservedObject private var access: ConnectorAccessStore
  @State private var selected: ConnectorKind?

  init(services: ApplicationServices) {
    self.services = services
    _access = ObservedObject(wrappedValue: services.connectorAccess)
  }

  var body: some View {
    Group {
      if let kind = selected {
        ConnectorDetail(kind: kind, services: services, access: access, onBack: { selected = nil })
      } else {
        grid
      }
    }
    .frame(minWidth: 780, minHeight: 710)
  }

  private var grid: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Connectors").font(.title2.weight(.semibold))
        Text("Connect the services Otto uses. Each one lists the Otto bots allowed to use it.")
          .font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
          ForEach(ConnectorKind.allCases) { kind in
            Button {
              selected = kind
            } label: {
              ConnectorTile(
                kind: kind, botCount: access.bots(for: kind).count,
                restricted: access.isRestricted(kind))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connector-tile-\(kind.rawValue)")
          }
        }
      }
      .padding(28)
    }
  }
}

extension ConnectorKind {
  fileprivate var symbol: String {
    switch self {
    case .telegram: "paperplane.fill"
    case .iMessage: "message.fill"
    case .mobile: "iphone"
    case .gmail: "envelope.fill"
    case .calendar: "calendar"
    case .email: "tray.and.arrow.up.fill"
    }
  }
}

private struct ConnectorTile: View {
  let kind: ConnectorKind
  let botCount: Int
  let restricted: Bool

  private var accessSummary: String {
    guard restricted else { return "All bots" }
    return botCount == 0 ? "No bots allowed" : "\(botCount) bot\(botCount == 1 ? "" : "s") allowed"
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: kind.symbol)
        .font(.system(size: 14))
        .frame(width: 30, height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 1) {
        Text(kind.title).font(.subheadline.weight(.semibold)).lineLimit(1)
        Text(accessSummary).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
  }
}

private struct ConnectorDetail: View {
  let kind: ConnectorKind
  let services: ApplicationServices
  @ObservedObject var access: ConnectorAccessStore
  let onBack: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button(action: onBack) {
          Label("Connectors", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connector-back")
        Spacer()
        Text(kind.title).font(.headline)
        Spacer()
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 14)
      Divider()
      setup
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      Divider()
      BotAccessSection(kind: kind, services: services, access: access)
        .frame(height: 200)
    }
  }

  @ViewBuilder private var setup: some View {
    switch kind {
    case .telegram:
      TelegramConnectionSettings(telegram: services.telegram)
    case .iMessage:
      MessagingSettingsView(messaging: services.messaging)
    case .mobile:
      MobileSettingsView(services: services)
    case .gmail:
      AppConnectionsView(connections: services.appConnections, embedded: true)
    case .calendar:
      CalendarConnectionSettings(connections: services.appConnections)
    case .email:
      SMTPConnectionSettings(smtp: services.smtp)
    }
  }
}

/// Multi-select list of Otto bots allowed to use one connector. Nothing is allowed by default.
private struct BotAccessSection: View {
  let kind: ConnectorKind
  let services: ApplicationServices
  @ObservedObject var access: ConnectorAccessStore
  @State private var error: String?

  var body: some View {
    let bots = services.botRoster().map(\.profile).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("OTTO BOTS THAT CAN USE \(kind.title.uppercased())")
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      if bots.isEmpty {
        Text("Create a bot in Chat → Bots first.").foregroundStyle(.secondary)
      } else {
        List(bots) { bot in
          Toggle(isOn: binding(for: bot, everyBot: Set(bots.map(\.id)))) {
            VStack(alignment: .leading, spacing: 2) {
              Text(bot.name)
              Text("@\(bot.handle)").font(.caption).foregroundStyle(.secondary)
            }
          }
          .accessibilityIdentifier("access-\(kind.rawValue)-\(bot.handle)")
        }
      }
      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Text(
        access.isRestricted(kind)
          ? "A bot only reaches \(kind.title) when it is ticked here."
          : "Every bot can use \(kind.title) until you untick one."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    .padding(28)
  }

  private func binding(for bot: AgentProfile, everyBot: Set<UUID>) -> Binding<Bool> {
    Binding(
      get: { access.canUse(kind, profileID: bot.id) },
      set: { allowed in
        do {
          try access.setAllowed(allowed, profileID: bot.id, for: kind, everyBot: everyBot)
          error = nil
        } catch {
          self.error = error.localizedDescription
        }
      })
  }
}

/// Google Calendar uses the Google account connected for Gmail, with calendar access added.
private struct CalendarConnectionSettings: View {
  @ObservedObject var connections: AppConnectionsStore

  var body: some View {
    Form {
      Section("Google Calendar") {
        Text(
          "Calendar uses your Google account. Grant calendar access so allowed bots can list events and create them on your primary calendar."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let error = connections.error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        Button(connections.accounts.isEmpty ? "Connect Google Calendar" : "Grant calendar access") {
          Task { await connections.connect(allowCalendar: true) }
        }
        .disabled(connections.isConnecting)
        .accessibilityIdentifier("calendar-connect")
      }
    }
    .formStyle(.grouped)
  }
}

/// Telegram credentials never leave the secure secret store; only the
/// one-time pairing code is rendered in the Settings UI.
private struct TelegramConnectionSettings: View {
  @ObservedObject var telegram: TelegramConnector
  @State private var botToken = ""
  @State private var busy = false

  var body: some View {
    Form {
      Section("Telegram bot") {
        Label(telegram.status, systemImage: "paperplane.circle")
          .accessibilityIdentifier("telegram-connector-status")
        Text(
          "Telegram can reach the Otto bots you allow below. Private chats and approved groups are supported. Group access is limited to the Telegram member who pairs it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let username = telegram.username {
          LabeledContent("Telegram bot", value: "@\(username)")
        } else {
          Text("1. Create a Telegram bot using @BotFather, then paste the bot token below.")
            .font(.caption).foregroundStyle(.secondary)
          SecureField("Telegram bot token · stored in Mac Keychain", text: $botToken)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("telegram-bot-token")
          Button("Connect Telegram") {
            busy = true
            let token = botToken
            botToken = ""
            Task {
              await telegram.connect(token: token)
              busy = false
            }
          }
          .disabled(busy || botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Link("Open BotFather", destination: URL(string: "https://t.me/BotFather")!)
        }
      }

      if telegram.username != nil {
        Section("Private chat pairing") {
          if let approved = telegram.approvedChatID {
            Label("Paired chat ID: \(approved)", systemImage: "checkmark.shield.fill")
              .foregroundStyle(.green)
            Text("Only this paired one-to-one chat can dispatch private messages.")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Text(
              "2. Open your Telegram bot and send this exact one-time message within 10 minutes."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let pairingCode = telegram.pairingCode {
              Text("/pair \(pairingCode)")
                .textSelection(.enabled)
                .font(.system(.callout, design: .monospaced))
            }
            Button("Generate new pairing code") { telegram.issuePairingCode() }
            if let pending = telegram.pendingChatID {
              LabeledContent("Waiting for approval", value: String(pending))
              Button("Approve this Telegram chat") { telegram.approvePendingChat() }
                .accessibilityIdentifier("telegram-approve-chat")
              Text("Approve only the chat ID that belongs to your own Telegram account.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        Section("Approved Telegram group") {
          if let group = telegram.approvedGroupID,
            let sender = telegram.approvedGroupSenderID
          {
            Label("Approved group: \(group)", systemImage: "person.3.fill")
              .foregroundStyle(.green)
            LabeledContent("Allowed Telegram sender", value: String(sender))
            Text("Only this group member may send instructions to Otto; other members are ignored.")
              .font(.caption).foregroundStyle(.secondary)
            Button("Revoke group access", role: .destructive) { telegram.revokeGroup() }
          } else {
            Text(
              "To connect a group, generate a group code, add your Telegram bot to the group, then send /pair CODE in that group. Approve the group and sender here on your Mac."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let code = telegram.groupPairingCode {
              Text("/pair \(code)")
                .textSelection(.enabled)
                .font(.system(.callout, design: .monospaced))
            }
            Button("Generate group pairing code") { telegram.issueGroupPairingCode() }
              .accessibilityIdentifier("telegram-group-pair")
            if let group = telegram.pendingGroupID,
              let sender = telegram.pendingGroupSenderID
            {
              LabeledContent("Group ID requesting access", value: String(group))
              LabeledContent("Telegram sender requesting access", value: String(sender))
              Button("Approve this group and sender") { telegram.approvePendingGroup() }
                .accessibilityIdentifier("telegram-approve-group")
            }
            Text(
              "For ordinary messages like 'Test', disable group privacy in BotFather (/setprivacy → Disable), then remove and re-add the Telegram bot to the group. With privacy enabled, group commands like /bots@YourBot usually work, but ordinary text may not reach it."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Bots") {
          Text(
            "Choose which Otto bots Telegram can reach in the bot access list below. Chats switch between them with /use."
          )
          .font(.caption).foregroundStyle(.secondary)
          Text(
            "Telegram is not an approval channel. Permission prompts and sensitive actions must be reviewed in Otto on the Mac."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Manage") {
          Button("Disconnect Telegram", role: .destructive) {
            busy = true
            Task {
              await telegram.disconnect()
              busy = false
            }
          }.disabled(busy)
          Text(
            "Disconnect removes local pairing and the saved token. To revoke a leaked token, rotate it through BotFather as well."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }

    }
    .formStyle(.grouped)
    // Fill the connector page; a fixed minimum height overflows it and hides the back button.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// SMTP sends mail on the user's behalf. The password is written to the Keychain and is
/// never shown again once saved.
private struct SMTPConnectionSettings: View {
  let smtp: SMTPConnector
  @State private var host = ""
  @State private var port = "587"
  @State private var username = ""
  @State private var fromAddress = ""
  @State private var useImplicitTLS = false
  @State private var password = ""
  @State private var status = ""
  @State private var busy = false
  @State private var testing = false
  @State private var isConfigured = false

  var body: some View {
    Form {
      Section("Outgoing mail (SMTP)") {
        Label(
          isConfigured ? "Connected. Agents can send mail with smtp.send." : "Not connected",
          systemImage: "envelope"
        )
        TextField("Server", text: $host)
        TextField("Port", text: $port)
        Toggle("Use implicit TLS (port 465)", isOn: $useImplicitTLS)
        TextField("Username", text: $username)
        TextField("From address", text: $fromAddress)
        SecureField("Password or app password", text: $password)
      }
      Section {
        HStack {
          Button("Save") { Task { await save() } }
            .disabled(
              busy || host.isEmpty || username.isEmpty || fromAddress.isEmpty || password.isEmpty)
          if isConfigured {
            Button("Test connection") { Task { await test() } }
              .disabled(testing || busy)
              .accessibilityIdentifier("smtp-test-connection")
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
              .disabled(busy)
          }
        }
        if !status.isEmpty {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .task { await load() }
  }

  private func load() async {
    guard let config = await smtp.configuration else { return }
    isConfigured = true
    host = config.host
    port = String(config.port)
    username = config.username
    fromAddress = config.fromAddress
    useImplicitTLS = config.security == .tls
  }

  private func save() async {
    busy = true
    defer { busy = false }
    guard let portNumber = Int(port) else {
      status = "Port must be a number."
      return
    }
    let config = SMTPConfiguration(
      host: host.trimmingCharacters(in: .whitespaces),
      port: portNumber,
      username: username.trimmingCharacters(in: .whitespaces),
      fromAddress: fromAddress.trimmingCharacters(in: .whitespaces),
      security: useImplicitTLS ? .tls : .startTLS)
    do {
      try await smtp.save(config, password: password)
      password = ""
      isConfigured = true
      status = "Saved. The password is stored in the Keychain."
    } catch {
      status = error.localizedDescription
    }
  }

  private func test() async {
    testing = true
    defer { testing = false }
    do {
      try await smtp.testConnection()
      status = "Connected. The server accepted the login. No mail was sent."
    } catch {
      status = error.localizedDescription
    }
  }

  private func disconnect() async {
    busy = true
    defer { busy = false }
    do {
      try await smtp.disconnect()
      isConfigured = false
      status = "Disconnected."
    } catch {
      status = error.localizedDescription
    }
  }
}

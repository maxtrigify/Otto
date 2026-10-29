import OttoServices
import SwiftUI

/// Keep every phone and messaging integration under a single Settings page.
/// Reuse the existing Mobile and Photon views so their saved state and
/// permission flows remain unchanged.
struct ConnectorsSettingsView: View {
  let services: ApplicationServices
  @State private var selected: ConnectorDestination = .telegram

  private enum ConnectorDestination: String, CaseIterable, Identifiable {
    case telegram, messaging, email, mobile
    var id: Self { self }
    var label: String {
      switch self {
      case .telegram: "Telegram"
      case .messaging: "iMessage"
      case .email: "Email"
      case .mobile: "Mobile"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Label(selected.label, systemImage: "point.3.connected.trianglepath.dotted")
          .font(.headline)
        Spacer()
        Picker("Connector", selection: $selected) {
          ForEach(ConnectorDestination.allCases) { destination in
            Text(destination.label).tag(destination)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 390)
        .accessibilityIdentifier("connector-destinations")
      }
      .padding(.horizontal, 28)
      .padding(.vertical, 14)
      Text(
        "One place for Otto's messaging and mobile connections. Other integrations, such as WhatsApp, can be added here in the future."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 28)
      .padding(.bottom, 10)
      Divider()
      Group {
        switch selected {
        case .telegram:
          TelegramConnectionSettings(telegram: services.telegram)
        case .messaging:
          MessagingSettingsView(messaging: services.messaging)
        case .email:
          SMTPConnectionSettings(smtp: services.smtp)
        case .mobile:
          MobileSettingsView(services: services)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(minWidth: 780, minHeight: 710)
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
          "Telegram can message one Otto bot you choose below. Private chats and approved groups are supported. Group access is limited to the Telegram member who pairs it."
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
        Section("Connected Otto bot") {
          if telegram.bots.isEmpty {
            Text("Create a saved bot in Otto → Chat → Bots first.")
              .foregroundStyle(.secondary)
          } else {
            Picker(
              "Allow Telegram to talk to",
              selection: Binding<UUID?>(
                get: { telegram.selectedBotID },
                set: { telegram.selectBot($0) })
            ) {
              Text("No bot selected (messages disabled)").tag(UUID?.none)
              ForEach(telegram.bots) { bot in
                Text("\(bot.name) (@\(bot.handle))").tag(Optional(bot.id))
              }
            }
            .accessibilityIdentifier("telegram-otto-bot-picker")
            Text(
              "Only the chosen bot is accessible from Telegram. Telegram /use and /bot commands cannot switch bots. Send /bots to check the selected bot, then send a message."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
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
    .frame(minWidth: 610, minHeight: 560)
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
            .disabled(busy || host.isEmpty || username.isEmpty || fromAddress.isEmpty || password.isEmpty)
          if isConfigured {
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


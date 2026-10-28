import OttoServices
import SwiftUI

/// Keep every phone and messaging integration under a single Settings page.
/// Reuse the existing Mobile and Photon views so their saved state and
/// permission flows remain unchanged.
struct ConnectorsSettingsView: View {
  let services: ApplicationServices
  @State private var selected: ConnectorDestination = .telegram

  private enum ConnectorDestination: String, CaseIterable, Identifiable {
    case telegram, messaging, mobile
    var id: Self { self }
    var label: String {
      switch self {
      case .telegram: "Telegram"
      case .messaging: "iMessage"
      case .mobile: "Mobile"
      }
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted")
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
      Divider()
      Group {
        switch selected {
        case .telegram:
          TelegramConnectionSettings(telegram: services.telegram)
        case .messaging:
          MessagingSettingsView(messaging: services.messaging)
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
      Section {
        Label("Connectors", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.title3.weight(.semibold))
        Text("Connect Otto to your messaging apps and route private requests to saved bots.")
          .foregroundStyle(.secondary)
      }

      Section("Telegram") {
        Label(telegram.status, systemImage: "paperplane.circle")
          .accessibilityIdentifier("telegram-connector-status")
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
        Section("Private pairing") {
          if let approved = telegram.approvedChatID {
            Label("Paired chat ID: \(approved)", systemImage: "checkmark.shield.fill")
              .foregroundStyle(.green)
            Text("Only this one-to-one Telegram chat can dispatch bot messages.")
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
        Section("Otto bots") {
          if telegram.bots.isEmpty {
            Text("Create a saved bot in Otto → Chat → Bots first.")
              .foregroundStyle(.secondary)
          } else {
            Text(
              "3. Send /bots in Telegram, then /use @handle to select an Otto bot. You can also send /bot @handle your message."
            )
            .font(.caption).foregroundStyle(.secondary)
            ForEach(telegram.bots) { bot in
              HStack {
                Text(bot.name)
                Spacer()
                Text("@\(bot.handle)").font(.caption).foregroundStyle(.secondary)
              }
            }
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

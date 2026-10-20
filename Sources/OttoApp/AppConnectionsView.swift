import OttoModels
import OttoServices
import SwiftUI

struct AppConnectionsView: View {
  @Environment(\.ottoPalette) private var palette
  @ObservedObject var connections: AppConnectionsStore
  var onClose: (() -> Void)? = nil
  @State private var search = ""
  @State private var allowSending = false
  @State private var showingSetup = false
  @State private var clientID = ""
  @State private var clientSecret = ""
  @State private var notice: String?
  @State private var busyAccount: UUID?
  @State private var disconnecting: GmailConnection?

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("Connect apps").font(.ottoDisplay(25).weight(.semibold))
          Text("Connect once. Use across your Otto agents.")
            .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
        }
        Spacer()
        Text("\(connections.accounts.count) connected")
          .font(.ottoMono(10)).foregroundStyle(palette.muted)
        if let onClose {
          Button(action: onClose) { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("Close app connections")
        }
      }
      HStack(spacing: 9) {
        Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
        TextField("Search apps", text: $search).textFieldStyle(.plain)
      }
      .padding(12).background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if search.isEmpty || "gmail google email".contains(search.lowercased()) {
            gmailCard
          } else {
            ContentUnavailableView.search(text: search)
          }
          if !connections.accounts.isEmpty {
            Text("CONNECTED ACCOUNTS")
              .font(.ottoMono(9, weight: .bold)).foregroundStyle(palette.muted)
            ForEach(connections.accounts) { account in accountRow(account) }
          }
        }
      }
      if let message = notice ?? connections.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle")
          Text(message).font(.ottoDisplay(12)).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button {
            notice = nil
            connections.clearError()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain).accessibilityLabel("Dismiss connection notice")
        }
        .foregroundStyle(palette.signal).padding(12)
        .background(palette.signal.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
      }
      Divider()
      HStack {
        Text("Claude Code · Codex · Cursor · Grok · Kimi · OpenCode")
          .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
        Spacer()
        Button("Advanced") {
          clientID = connections.googleClientID
          showingSetup = true
        }
        .font(.ottoDisplay(11)).buttonStyle(.plain).foregroundStyle(palette.muted)
      }
      Text(
        "Hermes uses its own connections. Connected email content is shared with the model handling your request."
      )
      .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
    }
    .padding(26).frame(width: 660, height: 560)
    .foregroundStyle(palette.paper).background(palette.surface)
    .sheet(isPresented: $showingSetup) { setupSheet }
    .confirmationDialog(
      "Disconnect Gmail?",
      isPresented: Binding(
        get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Disconnect", role: .destructive) {
        if let account = disconnecting {
          busyAccount = account.id
          Task {
            defer { busyAccount = nil }
            do { try await connections.disconnect(accountID: account.id) } catch {
              notice = "Could not disconnect Gmail. Please try again."
            }
          }
        }
        disconnecting = nil
      }
      Button("Cancel", role: .cancel) { disconnecting = nil }
    } message: {
      Text("All Otto agents will lose access to this account.")
    }
  }

  private var gmailCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        Group {
          if let logo = PluginLogoAssets.image(named: "gmail", kind: .mark) {
            Image(nsImage: logo).resizable().scaledToFit().padding(9)
          } else {
            Image(systemName: "envelope.fill").font(.system(size: 25))
              .foregroundStyle(Color(red: 0.92, green: 0.26, blue: 0.21))
          }
        }
        .frame(width: 48, height: 48).background(
          .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 4) {
          Text("Gmail").font(.ottoDisplay(17).weight(.semibold))
          Text("Search your inbox, read conversations and prepare replies.")
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        }
        Spacer()
        if connections.isConnecting {
          ProgressView().controlSize(.small)
          Button("Cancel") { connections.cancelConnect() }.buttonStyle(.plain)
        } else {
          Button(connections.accounts.isEmpty ? "Connect" : "Add account") {
            if connections.isConfigured {
              Task { await connections.connect(allowSending: allowSending) }
            } else {
              clientID = connections.googleClientID
              showingSetup = true
            }
          }
          .buttonStyle(.borderedProminent).tint(palette.cyan)
          .accessibilityIdentifier("apps.gmail.connect")
        }
      }
      Toggle("Allow saving drafts and sending email", isOn: $allowSending)
        .font(.ottoDisplay(12)).toggleStyle(.switch).controlSize(.small)
        .disabled(connections.isConnecting)
      Text(
        allowSending
          ? "Otto asks before an agent sends an email."
          : "Read access only. You can reconnect to enable drafts and sending later."
      )
      .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle")
        Text("Automatically available across supported agents")
      }
      .font(.ottoDisplay(11)).foregroundStyle(palette.cyan)
    }
    .padding(18).background(palette.paper.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.paper.opacity(0.08)))
  }

  private func accountRow(_ account: GmailConnection) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Circle().fill(account.needsReconnect ? palette.signal : palette.cyan).frame(
          width: 6, height: 6)
        Text(account.email).font(.ottoDisplay(13).weight(.semibold))
        Spacer()
        if busyAccount == account.id { ProgressView().controlSize(.small) }
        Button("Reconnect") {
          Task {
            await connections.connect(
              allowSending: allowSending || account.scopes.contains(AppConnectionsStore.sendScope),
              reconnecting: account.id)
          }
        }.disabled(connections.isConnecting || busyAccount != nil)
        Button("Disconnect") { disconnecting = account }
          .disabled(busyAccount != nil).foregroundStyle(palette.muted)
      }
      Text(
        account.needsReconnect
          ? "Sign-in expired. Reconnect to restore access."
          : (account.scopes.contains(AppConnectionsStore.sendScope)
            ? "Search · Read · Draft · Send with approval" : "Search · Read")
      )
      .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
      Toggle(
        "Share with supported Otto agents",
        isOn: Binding(
          get: { account.shared },
          set: { next in
            do { try connections.setShared(next, accountID: account.id) } catch {
              notice = "Could not save agent access. Please try again."
            }
          })
      )
      .font(.ottoDisplay(11)).toggleStyle(.switch).controlSize(.mini)
    }
    .buttonStyle(.plain).padding(14)
    .background(palette.paper.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
  }

  private var setupSheet: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Google sign-in setup").font(.title2.weight(.semibold))
      Text(
        "This Otto installation needs a Google Desktop OAuth app before Gmail can connect. This is installation setup; users then connect through Google's sign-in screen."
      )
      .font(.callout).foregroundStyle(.secondary)
      TextField("Google OAuth client ID", text: $clientID)
      SecureField("Client secret, if required", text: $clientSecret)
      Text("Credentials stay in Keychain. Passwords and Google tokens never belong in chat.")
        .font(.caption).foregroundStyle(.secondary)
      if let notice { Text(notice).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("Cancel") {
          clientSecret = ""
          showingSetup = false
        }
        Spacer()
        Button("Save setup") {
          Task {
            do {
              try await connections.configureGoogle(
                clientID: clientID, clientSecret: clientSecret.isEmpty ? nil : clientSecret)
              clientSecret = ""
              notice = nil
              showingSetup = false
            } catch { notice = "Enter a valid Google Desktop OAuth client ID." }
          }
        }.buttonStyle(.borderedProminent).disabled(clientID.isEmpty)
      }
    }.padding(24).frame(width: 480)
  }
}

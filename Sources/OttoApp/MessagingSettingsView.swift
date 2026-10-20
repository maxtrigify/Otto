import AppKit
import OttoServices
import SwiftUI

struct MessagingSettingsView: View {
  @ObservedObject var messaging: MessagingService
  @State private var setup = false
  @State private var account = ""
  @State private var secret = ""
  @State private var sender = ""
  @State private var destination = ""
  @State private var teamID: UUID?
  @State private var busy = false

  var body: some View {
    Form {
      Section {
        Label("iMessage via Photon", systemImage: "message.fill").font(.headline)
        Text("Experimental · Uses your Photon account")
        Text(
          "Photon carries your messages. Otto must be running on your Mac. Your provider’s pricing and limits apply."
        )
        .font(.callout).foregroundStyle(.secondary)
        Text(messaging.status).textSelection(.enabled).accessibilityIdentifier("messaging-status")
      }
      if setup {
        Section("1. Your Photon account") {
          Link("Open Photon dashboard", destination: URL(string: "https://app.photon.codes")!)
          Text(
            "In your existing Photon project, open Settings and copy its project ID and secret. Add your phone in Photon and copy its assigned destination number. Otto does not create accounts or buy lines."
          )
          .font(.caption).foregroundStyle(.secondary)
          TextField("Photon project ID", text: $account)
          SecureField("Project secret · stored in Keychain", text: $secret)
          TextField("Your phone number (+country code)", text: $sender)
          TextField("Assigned Photon destination (+country code)", text: $destination)
        }
        Section("2. Default routing") {
          LabeledContent("Project", value: messaging.projectName)
          Picker("Team", selection: $teamID) {
            Text("Select a team").tag(nil as UUID?)
            ForEach(messaging.teams) { team in Text(team.name ?? "Team").tag(Optional(team.id)) }
          }
          if let team = messaging.teams.first(where: { $0.id == teamID }) {
            LabeledContent("Coordinator", value: messaging.coordinatorName(team))
          }
          Button("Open team in Otto") { openTeam() }
          Text("Messages use a separate conversation for this team. Approvals stay in Otto.")
            .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Cancel") {
            secret = ""
            setup = false
          }
          Button("Connect and pair") {
            guard let teamID else { return }
            busy = true
            let credential = secret
            secret = ""
            Task {
              await messaging.connect(
                accountID: account.trimmingCharacters(in: .whitespacesAndNewlines),
                secret: credential, sender: sender, destination: destination, teamID: teamID)
              busy = false
              if messaging.binding?.enabled == true { setup = false }
            }
          }.disabled(
            busy || account.isEmpty || secret.isEmpty || sender.isEmpty || destination.isEmpty
              || teamID == nil)
        }
      } else if let binding = messaging.binding, binding.enabled {
        Section("Connection") {
          LabeledContent("Provider", value: "Photon · user-owned project")
          LabeledContent(
            "Default project", value: (binding.projectPath as NSString).lastPathComponent)
          LabeledContent(
            "Default team",
            value: messaging.teams.first(where: { $0.id == binding.teamID })?.name ?? "Unavailable")
          LabeledContent(
            "Paired sender", value: binding.sender.map { "•••" + $0.suffix(4) } ?? "Not paired")
          LabeledContent("Destination", value: binding.destination)
          if let activity = messaging.lastActivity {
            LabeledContent("Last successful exchange", value: activity.formatted())
          }
          if let code = messaging.pairingCode {
            Text("3. Pair your phone").font(.headline)
            Text(
              "From your phone, send this message to the destination above within five minutes. Each code works once."
            )
            .font(.caption)
            Text("PAIR " + code).font(.system(.caption, design: .monospaced)).textSelection(
              .enabled)
            if let url = URL(string: "sms:\(binding.destination)&body=PAIR%20\(code)") {
              Link("Open pairing message", destination: url)
            }
            Button("New pairing code") { messaging.newPairingCode() }
          }
          Text(
            "4. Send a text request. Success appears only after Otto receives it and Photon accepts the team’s response; this is not a handset delivery receipt."
          )
          .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Reconnect") { Task { await messaging.reconnect() } }
            Button("Open team in Otto") { openTeam() }
            Button("Disconnect", role: .destructive) { Task { await messaging.disconnect() } }
          }
          Text(
            "To change the account, project or team, disconnect and pair again. Previous conversations are retained separately."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        if !messaging.jobs.isEmpty {
          Section("Recent delivery") {
            ForEach(Array(messaging.jobs.suffix(5))) { job in
              LabeledContent(
                job.createdAt.formatted(date: .abbreviated, time: .shortened),
                value: job.state.rawValue.capitalized)
            }
          }
        }
      } else {
        Button("Connect iMessage") {
          setup = true
          teamID = messaging.teams.first?.id
        }
      }
      if messaging.cleanupRequired {
        Button("Retry disconnect") { Task { await messaging.disconnect() } }
      }
      Section("Troubleshooting") {
        Text(
          "Install Node.js 22 or later, then install the connector. If Photon cannot connect, check your project credentials and account access, then reconnect. Uncertain sends are never retried automatically. Website sign-in and website approvals arrive as private links in Messages. Other approvals and interrupted tasks may need review in Otto."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Install Photon connector") {
          busy = true
          Task {
            await messaging.install()
            busy = false
          }
        }.disabled(busy)
        Link(
          "Photon setup documentation",
          destination: URL(string: "https://photon.codes/docs/spectrum-ts/getting-started")!)
      }
    }
    .formStyle(.grouped)
    .frame(width: 620, height: 650)
  }
  private func openTeam() {
    messaging.openTeam()
    // Reveal the selected team in the main workspace instead of leaving Settings in front.
    if let window = NSApp.keyWindow,
      window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
    {
      window.close()
    }
  }

}

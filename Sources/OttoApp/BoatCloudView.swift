import OttoServices
import SwiftUI

struct BoatCloudView: View {
  @ObservedObject var cloud: BoatCloudStore
  @Environment(\.openURL) private var openURL
  @State private var key = ""
  @State private var selected: String?
  @State private var draft = ""
  @State private var provider = "codex"
  @State private var useEnvironment = false
  @AppStorage("otto.boat.trialOnly") private var trialOnly = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Cloud running").font(.title2)
        Text(
          "Run a task on your own Boat machine while your Mac is away. This is a separate cloud conversation; your local files, bot memory and Mac permissions are not transferred."
        )
        .foregroundStyle(.secondary)
        HStack {
          Button("Open Boat setup") {
            openURL(URL(string: "https://boat.dev/dashboard?tab=agents")!)
          }
          Button("Pricing & trial") { openURL(URL(string: "https://docs.boat.dev/pricing")!) }
          Spacer()
          if cloud.busy { ProgressView().controlSize(.small) }
        }
        if !cloud.connected {
          SecureField("Boat API key", text: $key).textFieldStyle(.roundedBorder)
            .accessibilityLabel("Boat API key stored in Keychain")
          Text(
            "Create an API key in Boat, then enter it here—not in chat. Otto stores it in macOS Keychain. Connect your AI provider in Boat's Agents page."
          )
          .font(.caption).foregroundStyle(.secondary)
          Button("Connect Boat") {
            let entered = key
            key = ""
            Task { await cloud.connect(key: entered.isEmpty ? nil : entered) }
          }.disabled(cloud.busy)
        } else {
          Text("Connected to your personal Boat account").font(.headline)
          if let limits = cloud.limits {
            Text(
              "\(limits.accessTier ?? "Account") · \(limits.activeSandboxes) / \(limits.maxActiveSandboxes) active machines"
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          Toggle("Only start machines on a free trial", isOn: $trialOnly)
          Text(
            "Boat's trial is limited. Turning this off allows compute charges to your Boat account. Otto does not purchase credits or change billing. New and resumed machines auto-stop after one hour; stopping preserves disk, but ends running processes."
          )
          .font(.caption).foregroundStyle(.secondary)
          Toggle("Use my configured Boat environment for new machines", isOn: $useEnvironment)
          Text(
            "Off: create an isolated machine with no account secrets. On: Boat may copy your configured repositories and credentials into this personal machine. Configure and review these in Boat before enabling."
          )
          .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button(cloud.pendingCreate == nil ? "Create cloud machine" : "Retry machine creation") {
              Task {
                await cloud.create(trialOnly: trialOnly, useAccountEnvironment: useEnvironment)
              }
            }
            Button("Refresh") { Task { await cloud.refresh(machineID: selected) } }
            Spacer()
            Button("Disconnect & forget key") { Task { await cloud.disconnect() } }
          }.disabled(cloud.busy)
          if cloud.pendingCreate != nil {
            Text(
              "A creation attempt is pending. Retry reuses its original options and identifier to avoid a duplicate machine."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
          if !cloud.machines.isEmpty {
            Picker("Cloud machine", selection: $selected) {
              Text("Choose a machine").tag(String?.none)
              ForEach(cloud.machines) { machine in
                Text(
                  "\(cloud.sandboxes[machine.id]?.name ?? machine.id) · \(cloud.sandboxes[machine.id]?.state ?? "Refresh needed")"
                )
                .tag(Optional(machine.id))
              }
            }
            .onChange(of: selected) { _, value in Task { await cloud.refresh(machineID: value) } }
          }
          if let id = selected, let machine = cloud.machines.first(where: { $0.id == id }) {
            if let sandbox = cloud.sandboxes[id] {
              Text("\(id) · \(sandbox.state)").font(.caption.monospaced())
              if let deadline = sandbox.archiveAfter {
                Text("Auto-stop: \(deadline)").font(.caption)
              }
              HStack {
                if sandbox.state == "archived" {
                  Button("Resume for one hour") {
                    Task { await cloud.resume(id, trialOnly: trialOnly) }
                  }
                } else {
                  Button("Stop cloud machine") { Task { await cloud.stop(id) } }
                }
                Button("View in Boat") { openURL(URL(string: "https://boat.dev/dashboard")!) }
              }.disabled(cloud.busy)
            }
            if machine.uncertainSubmission {
              Text(
                "The last send has an uncertain outcome. Check Boat before sending again; Otto will not automatically retry it."
              )
              .foregroundStyle(.orange)
              Button("I checked Boat — allow another send") {
                cloud.acknowledgeUncertainSubmission(id)
              }
              .disabled(cloud.busy)
            }
            Picker("Agent", selection: $provider) {
              Text("Codex").tag("codex")
              Text("Claude Code").tag("claude-code")
            }
            TextEditor(text: $draft).frame(height: 100).border(.secondary.opacity(0.3))
              .accessibilityLabel("Cloud task")
            Button("Send cloud task") {
              Task {
                await cloud.send(draft, to: id, provider: provider)
                if cloud.error == nil {
                  draft = ""
                  await cloud.refresh(machineID: id)
                }
              }
            }
            .disabled(
              cloud.busy || machine.uncertainSubmission || cloud.sandboxes[id]?.canPrompt != true
                || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Text("Cloud responses").font(.headline)
            if let status = cloud.taskStatus[id] { Text("Last task: \(status)").font(.caption) }
            if cloud.eventMachineID != id || cloud.events.isEmpty {
              Text("Refresh to read responses from this conversation.").foregroundStyle(.secondary)
            }
            ForEach(
              Array((cloud.eventMachineID == id ? cloud.events : []).enumerated()), id: \.offset
            ) { _, event in
              VStack(alignment: .leading, spacing: 4) {
                Text(event.data?.status ?? event.type).font(.caption).foregroundStyle(.secondary)
                if let content = event.data?.content, !content.isEmpty {
                  Text(content).textSelection(.enabled)
                }
              }
            }
          }
        }
        if let error = cloud.error { Text(error).foregroundStyle(.orange) }
      }.padding(24)
    }
    .frame(minWidth: 640, minHeight: 520)
    .task {
      // UI owns observation only. Closing it does not stop the Boat agent.
      while !Task.isCancelled {
        if cloud.connected && cloud.error == nil { await cloud.refresh(machineID: selected) }
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
      }
    }
  }
}

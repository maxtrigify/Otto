#if DEBUG
  import Foundation
  import OttoCore
  import OttoModels
  import OttoSecurity
  import OttoServices
  import SwiftUI

  /// Explicit opt-in, isolated native UI fixture. Never connects to a provider or keychain.
  @MainActor
  enum MessagingPreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--messaging-preview") }
    static func configure(_ services: ApplicationServices, root: URL) {
      let lead = try! services.saveAgentProfile(
        AgentProfile(name: "Coordinator", instructions: "Preview fixture", provider: .codex))
      let worker = try! services.saveAgentProfile(
        AgentProfile(name: "Researcher", instructions: "Preview fixture", provider: .codex))
      _ = try! services.botChannels.createGroupChannel(
        memberProfileIDs: [lead.id, worker.id], name: "Personal team",
        orchestratorProfileID: lead.id)
      services.messaging = MessagingService(
        services: services, adapter: PreviewPhotonAdapter(),
        secrets: PreviewMessagingSecrets(), url: root.appending(path: "messaging.json"),
        simulation: true)
    }
  }

  private actor PreviewMessagingSecrets: SecretStore {
    var value: String?
    var failNextDelete = ProcessInfo.processInfo.arguments.contains(
      "--messaging-preview-cleanup-failure")
    func set(_ value: String, for key: String) { self.value = value }
    func value(for key: String) -> String? { value }
    func delete(_ key: String) throws {
      if failNextDelete {
        failNextDelete = false
        throw MessagingError.providerUnavailable
      }
      value = nil
    }
  }

  @MainActor
  private final class PreviewPhotonAdapter: MessagingProviderAdapter {
    var onEvent: ((Data) -> Void)?
    func connect(accountID: String, secret: String) throws {
      Task { onEvent?(Data("{\"kind\":\"ready\"}".utf8)) }
    }
    func send(_ job: MessagingJob) throws {}
    func disconnect() {}
  }

  struct MessagingPreviewView: View {
    @ObservedObject var services: ApplicationServices
    let store: CanvasStore
    var body: some View {
      VStack(spacing: 0) {
        Text("SIMULATED PROVIDER · Native Settings preview · No network or Keychain")
          .font(.caption.bold()).padding(12).frame(maxWidth: .infinity).background(
            .yellow.opacity(0.15))
        if ProcessInfo.processInfo.arguments.contains("--team-approval-preview") {
          TeamApprovalPreview(services: services, store: store)
        } else {
          MessagingSettingsView(messaging: services.messaging)
            .frame(width: 620, height: 650)
        }
      }
    }
  }
#endif

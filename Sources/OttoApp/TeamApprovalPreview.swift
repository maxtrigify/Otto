#if DEBUG
  import Foundation
  import OttoCore
  import OttoModels
  import OttoRuntime
  import OttoServices
  import SwiftUI

  /// Explicit isolated acceptance fixture. No model, network, Keychain, or external action.
  struct TeamApprovalPreview: View {
    @ObservedObject var services: ApplicationServices
    let store: CanvasStore
    @State private var channelID: UUID?
    @State private var result = "Starting synthetic team…"

    var body: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text("SIMULATED TEAM · No external action").font(.headline)
        if let channelID { TeamApprovalView(services: services, channelID: channelID) }
        Text(result).accessibilityIdentifier("team-approval-result")
      }
      .padding(24).frame(width: 620, height: 300)
      .task { await runFixture() }
    }

    @MainActor private func runFixture() async {
      var runtimeID: UUID?
      do {
        await services.start()
        let lead = try services.saveAgentProfile(
          AgentProfile(
            name: "Approval fixture", instructions: "Synthetic test", provider: .claudeCode))
        let worker = try services.saveAgentProfile(
          AgentProfile(name: "Fixture helper", instructions: "Synthetic test", provider: .codex))
        let node = try store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
          .affectedNodeIDs.first.unwrap()
        runtimeID = node
        _ = try services.botChannels.bindNode(profileID: lead.id, nodeID: node)
        _ = try await services.supervisor.spawn(
          provider: .shell,
          specification: ProcessLaunchSpec(
            executable: "/bin/sh",
            arguments: [
              "-c",
              "printf 'OTTO_STATUS:IDLE\\r\\n'; while IFS= read -r line; do [ \"$line\" = '[OTTO TEAM PROMPT END]' ] && break; done; printf 'OTTO_STATUS:WORKING\\r\\n'; sleep 180",
            ],
            workingDirectory: services.documents.rootPath), id: node)
        for _ in 0..<100 {
          if (try? await services.supervisor.snapshot(agentID: node).state) == .idle { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        let team = try services.botChannels.createGroupChannel(
          memberProfileIDs: [lead.id, worker.id], name: "Approval fixture",
          orchestratorProfileID: lead.id)
        channelID = team.id
        try await services.sendTeamMessage(
          channelID: team.id, text: "Synthetic approval test", at: WorldPoint(x: 0, y: 0))
        result = "Waiting for your decision"
        let approved = try await services.supervisor.requestPermission(
          agentID: node, toolName: "Synthetic test",
          detail: "Show a test result locally. No files, messages, or permissions will change.")
        result = approved ? "Approved test request" : "Denied test request"
      } catch { result = "Fixture failed: \(error.localizedDescription)" }
      if let runtimeID { try? await services.supervisor.stop(agentID: runtimeID) }
      await services.shutdown()
    }
  }

  extension Optional {
    fileprivate func unwrap() throws -> Wrapped {
      guard let self else { throw CocoaError(.coderInvalidValue) }
      return self
    }
  }
#endif

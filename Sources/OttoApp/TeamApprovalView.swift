import Foundation
import OttoRuntime
import OttoServices
import SwiftUI

struct TeamApprovalView: View {
  @ObservedObject var services: ApplicationServices
  let channelID: UUID
  @State private var request: AgentPendingPermission?
  @State private var resolving = false
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let request {
        Text("Approval needed").font(.headline)
        Text(request.reason).textSelection(.enabled)
        HStack {
          Button("Deny", role: .destructive) { resolve(request, approved: false) }
          Button("Approve") { resolve(request, approved: true) }
        }
        .disabled(resolving)
      } else if services.teamSession(channelID: channelID)?.needsUser == true {
        Text("This team needs your review").font(.headline)
        Text(
          "Review the last response and any changes. Send a new message below when you are ready to continue. Messaging requests wait here until review is resolved."
        )
        .font(.callout)
      }
      if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(
      request != nil || services.teamSession(channelID: channelID)?.needsUser == true ? 16 : 0
    )
    .task(id: channelID) {
      while !Task.isCancelled {
        let next = await services.teamPermission(channelID: channelID)
        if next != request { request = next }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      }
    }
  }

  private func resolve(_ request: AgentPendingPermission, approved: Bool) {
    resolving = true
    failure = nil
    Task {
      defer { resolving = false }
      do {
        try await services.resolveTeamPermission(
          channelID: channelID, request: request, approved: approved)
        self.request = await services.teamPermission(channelID: channelID)
      } catch {
        failure = "This request changed or is no longer pending. Review the current request."
        self.request = await services.teamPermission(channelID: channelID)
      }
    }
  }
}

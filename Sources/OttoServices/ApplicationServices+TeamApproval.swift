import Foundation
import OttoRuntime

extension ApplicationServices {
  public func teamPermission(channelID: UUID) async -> AgentPendingPermission? {
    guard let runtimeID = activeTeamRuntimeID(channelID: channelID) else { return nil }
    return await supervisor.pendingPermission(agentID: runtimeID)
  }

  public func resolveTeamPermission(
    channelID: UUID, request: AgentPendingPermission, approved: Bool
  ) async throws {
    guard let runtimeID = activeTeamRuntimeID(channelID: channelID),
      let current = await supervisor.pendingPermission(agentID: runtimeID),
      current == request
    else { throw RuntimeError.noPendingPermission(channelID) }
    try await supervisor.resolvePermission(
      agentID: runtimeID, requestID: request.requestID, nonce: request.nonce, approved: approved)
    acknowledgeAttention(nodeID: runtimeID)
  }
}

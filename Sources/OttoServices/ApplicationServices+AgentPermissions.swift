import Foundation
import OttoModels
import OttoRuntime
import OttoTools

extension ApplicationServices {
  public func changeAgentPermissionMode(_ mode: AgentPermissionMode, agentID: UUID) async {
    do { try await setAgentPermissionMode(mode, agentID: agentID) } catch {
      errorMessage = error.localizedDescription
    }
  }

  /// Persist the policy at the conversation's source of truth before updating its live run.
  /// A task session with a profile stays independent of the canonical bot conversation.
  public func setAgentPermissionMode(_ mode: AgentPermissionMode, agentID: UUID) async throws {
    guard
      let canvas = store.snapshot.canvases.first(where: {
        $0.nodes.contains(where: { $0.id == agentID })
      }), var definition = canvas.nodes.first(where: { $0.id == agentID })?.agentDefinition
    else {
      throw ToolRegistryError.invalidInput("This agent has no saved launch configuration")
    }
    if let channel = botChannels.channels.first(where: {
      $0.nodeID == agentID && $0.kind == .botChannel && !$0.archived
    }), var profile = agentProfiles.profile(id: channel.profileID) {
      profile.permissionMode = mode.rawValue
      let saved = try saveAgentProfile(profile)
      definition.profileRevision = saved.revision
    }
    definition.permissionMode = mode.rawValue
    store.dispatch(
      .setAgentDefinition(id: agentID, definition: definition), targetCanvasID: canvas.id)
    if let snapshot = try? await supervisor.snapshot(agentID: agentID), snapshot.exitCode == nil {
      try await supervisor.setProviderPermissionBypass(
        agentID: agentID, enabled: mode == .unrestricted)
    }
  }

  /// One ordered action: save the policy, enable it on the run, then answer any remaining card.
  public func alwaysAllowAgentPermission(agentID: UUID) async {
    do {
      let pending = await supervisor.pendingPermission(agentID: agentID)
      try await setAgentPermissionMode(.unrestricted, agentID: agentID)
      if let pending,
        await supervisor.pendingPermission(agentID: agentID)?.requestID == pending.requestID
      {
        try await supervisor.resolvePermission(agentID: agentID, approved: true)
      } else if let snapshot = try? await supervisor.snapshot(agentID: agentID),
        snapshot.executionMode == .interactiveProvider
      {
        try await supervisor.sendBytes(agentID: agentID, data: Data("\r".utf8))
      }
      acknowledgeAttention(nodeID: agentID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

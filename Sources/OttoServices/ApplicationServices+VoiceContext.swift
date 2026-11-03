import Foundation
import OttoModels
import OttoVoice

extension ApplicationServices {
  /// What Otto's voice knows about the workspace: the canvas, saved bots, teams and standalone
  /// sessions. Talk, local Command voice and Otto Desktop's voice all receive this same projection.
  public func voiceContext(
    snapshot: WorkspaceSnapshot, canvas: OttoCanvas, workspacePath: String,
    knownWorkspaces: [String]
  ) -> VoiceContext {
    let roster = botRoster()
    let profilesByID = Dictionary(uniqueKeysWithValues: roster.map { ($0.profile.id, $0.profile) })
    var context = VoiceContext(
      canvas: canvas,
      workspace: workspacePath,
      knownWorkspaces: knownWorkspaces,
      canvases: snapshot.canvases
    )
    let botNodeIDs = Set(roster.compactMap(\.nodeID))
    context.sessions = snapshot.canvases.flatMap { canvas in
      canvas.nodes.compactMap { node -> VoiceSessionContext? in
        guard node.kind == .agent, !botNodeIDs.contains(node.id) else { return nil }
        return VoiceSessionContext(
          id: node.id,
          name: node.displayName,
          canvasID: canvas.id,
          provider: Self.declaredProvider(of: node),
          status: node.status
        )
      }
    }
    context.bots = roster.map { entry in
      VoiceBotContext(
        id: entry.profile.id,
        name: entry.profile.name,
        handle: entry.profile.handle,
        jobTitle: entry.profile.jobTitle,
        nodeID: entry.nodeID
      )
    }
    context.teams = teamChannels().map { channel in
      let members = channel.memberProfileIDs.compactMap { profilesByID[$0] }
      let names = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
      return VoiceTeamContext(
        id: channel.id,
        name: channel.displayTitle(profileNames: names),
        memberHandles: members.map(\.handle),
        orchestratorHandle: channel.orchestratorProfileID.flatMap { profilesByID[$0]?.handle }
      )
    }
    return context
  }

  /// The provider a session node was declared with (OttoApp's `declaredAgentProvider`).
  nonisolated static func declaredProvider(of node: OttoNode) -> AgentProvider? {
    if let provider = node.agentDefinition?.provider { return provider }
    guard case .agent(let provider) = node.content else { return nil }
    return provider
  }
}

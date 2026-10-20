import Foundation
import OttoModels

/// A saved bot and a one-off session remain different identities even with the same UUID.
enum HomeConversationTarget: Equatable, Hashable, Sendable {
  case newSession
  case bot(UUID)
  case session(UUID)
}

func homeSessionNodes(
  canvases: [OttoCanvas], botProfileIDs: Set<UUID>, botNodeIDs: Set<UUID>,
  // Dashboard and document helpers and card updates live beside their work, not here.
  backgroundNodeIDs: Set<UUID> = []
) -> [OttoNode] {
  canvases.flatMap(\.nodes).filter { node in
    node.isStandaloneAgent && node.agentDefinition != nil && !botNodeIDs.contains(node.id)
      && !backgroundNodeIDs.contains(node.id)
      && !(node.agentDefinition?.profileID.map { botProfileIDs.contains($0) } ?? false)
  }.sorted {
    let left = $0.lastOpenedAt ?? .distantPast
    let right = $1.lastOpenedAt ?? .distantPast
    return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
  }
}

/// Validate the roster's canonical node across every canvas before reusing its conversation.
func existingHomeBotNodeID(
  profileID: UUID, canonicalNodeID: UUID?, canvases: [OttoCanvas]
) -> UUID? {
  guard let canonicalNodeID,
    let node = canvases.flatMap(\.nodes).first(where: { $0.id == canonicalNodeID }),
    node.isStandaloneAgent, node.agentDefinition?.profileID == profileID
  else { return nil }
  return node.id
}

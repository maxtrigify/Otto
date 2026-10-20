import Foundation
import Testing

@testable import OttoApplicationTools

@Suite("Agent actor IDs from before the rename")
struct LegacyActorIDTests {
  @Test("Both otto-agent- and muse-agent- control tokens resolve to their node")
  func actorPrefixes() {
    let node = UUID()
    #expect(AgentRequestPermissionTool.nodeID(fromActorID: "otto-agent-\(node.uuidString)") == node)
    #expect(AgentRequestPermissionTool.nodeID(fromActorID: "muse-agent-\(node.uuidString)") == node)
    #expect(AgentRequestPermissionTool.nodeID(fromActorID: "otto-app") == nil)
  }
}

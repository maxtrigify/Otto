import OttoModels
import Testing

@Suite("Ambient agent status")
struct AmbientAgentStatusTests {
  @Test("Detailed lifecycle states project into honest user-facing states")
  func displayStatusProjection() {
    #expect(AgentDisplayStatus(.waiting) == .needsYou)
    #expect(AgentDisplayStatus(.starting) == .working)
    #expect(AgentDisplayStatus(.working) == .working)
    #expect(AgentDisplayStatus(.done) == .idle)
    #expect(AgentDisplayStatus(.stopped) == .idle)
    #expect(AgentDisplayStatus(.failed) == .failed)
    #expect(
      AgentDisplayStatus.allCases.sorted { $0.sortOrder < $1.sortOrder } == [
        .needsYou, .failed, .working, .idle,
      ])
  }

  @Test("Status disappears when no agent needs ambient attention")
  func emptyStatus() {
    let nodes = [
      node(.agent, "Ready", .idle),
      node(.terminal, "Shell", .working),
    ]
    let status = AmbientAgentStatus(nodes: nodes)
    #expect(status.isEmpty)
    #expect(status.label.isEmpty)
  }

  @Test("Working, queued, and waiting agents are summarized independently")
  func activeStatus() {
    let nodes = [
      node(.agent, "One", .working),
      node(.agent, "Two", .starting),
      node(.agent, "Three", .waiting),
    ]
    let status = AmbientAgentStatus(nodes: nodes)
    #expect(status == AmbientAgentStatus(working: 1, queued: 1, waiting: 1))
    #expect(status.label == "1 working · 1 queued · 1 waiting")
  }

  @Test("Stage rail groups attention, agents, and windows in honest order")
  func stageRailSections() {
    let nodes = [
      node(.agent, "Idle", .idle),
      node(.browser, "Browser", .idle),
      node(.agent, "Question", .waiting),
      node(.agent, "Build", .working),
      node(.terminal, "Terminal", .working),
      node(.label, "Canvas label", .idle),
      node(.agent, "Broken", .failed),
    ]

    let sections = StageRailSections(nodes: nodes)
    #expect(sections.needsYou.map(\.displayName) == ["Question"])
    #expect(sections.agents.map(\.displayName) == ["Broken", "Build", "Idle"])
    #expect(sections.windows.map(\.displayName) == ["Terminal", "Browser"])
  }

  private func node(_ kind: NodeKind, _ name: String, _ status: NodeStatus) -> OttoNode {
    OttoNode(
      kind: kind,
      displayName: name,
      subtitle: "LOCAL",
      frame: WorldRect(x: 0, y: 0, width: 320, height: 220),
      zIndex: 0,
      status: status
    )
  }
}

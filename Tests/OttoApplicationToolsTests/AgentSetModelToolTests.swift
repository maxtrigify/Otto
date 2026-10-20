import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Agent set-model tool")
struct AgentSetModelToolTests {
  private var context: ToolContext {
    ToolContext(actorID: "test", scopes: Set(ToolScope.allCases), source: .userInterface)
  }

  @MainActor
  private func makeAgentNode(provider: AgentProvider, store: CanvasStore) throws -> UUID {
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 10, y: 10)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: nodeID,
        definition: AgentDefinition(
          provider: provider,
          workingDirectory: "/tmp",
          launchCommand: provider.rawValue,
          permissionMode: AgentPermissionMode.workspaceWrite.rawValue
        )
      ))
    return nodeID
  }

  @Test("Model and effort persist onto the saved configuration; default clears them")
  func persistsModelAndEffort() async throws {
    let store = await MainActor.run { CanvasStore() }
    let nodeID = try await makeAgentNode(provider: .codex, store: store)
    let tool = AgentSetModelTool(store: store)

    let set = try await tool.call(
      AgentSetModelInput(agentID: nodeID, model: "gpt-5-codex", effort: "high"),
      context: context
    )
    #expect(set.model == "gpt-5-codex")
    #expect(set.effort == "high")
    let saved = await MainActor.run {
      store.activeCanvas.nodes.first { $0.id == nodeID }?.agentDefinition
    }
    #expect(saved?.model == "gpt-5-codex")
    #expect(saved?.effort == "high")

    let cleared = try await tool.call(
      AgentSetModelInput(agentID: nodeID, model: "default", effort: "default"),
      context: context
    )
    #expect(cleared.model == nil)
    #expect(cleared.effort == nil)
  }

  @Test("Invalid effort and unswitchable providers are rejected")
  func rejectsInvalidRequests() async throws {
    let store = await MainActor.run { CanvasStore() }
    let codexID = try await makeAgentNode(provider: .codex, store: store)
    let tool = AgentSetModelTool(store: store)
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        AgentSetModelInput(agentID: codexID, effort: "extreme"), context: context)
    }

    let hermesID = try await makeAgentNode(provider: .hermes, store: store)
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        AgentSetModelInput(agentID: hermesID, model: "gpt-5"), context: context)
    }

    // Claude accepts its documented effort ladder and rejects made-up levels.
    let claudeID = try await makeAgentNode(provider: .claudeCode, store: store)
    let claude = try await tool.call(
      AgentSetModelInput(agentID: claudeID, model: "claude-opus-4-8", effort: "xhigh"),
      context: context)
    #expect(claude.model == "claude-opus-4-8")
    #expect(claude.effort == "xhigh")
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        AgentSetModelInput(agentID: claudeID, effort: "ultra"), context: context)
    }
  }

  @Test("Switching Otto Harness vendors clears an incompatible effort")
  func clearsIncompatibleHarnessEffort() async throws {
    let store = await MainActor.run { CanvasStore() }
    let nodeID = try await makeAgentNode(provider: .openAI, store: store)
    let tool = AgentSetModelTool(store: store)

    _ = try await tool.call(
      AgentSetModelInput(agentID: nodeID, model: "openai/gpt-5.6", effort: "xhigh"),
      context: context)
    let switched = try await tool.call(
      AgentSetModelInput(agentID: nodeID, model: "moonshot/kimi-k2.5"),
      context: context)

    #expect(switched.model == "moonshot/kimi-k2.5")
    #expect(switched.effort == nil)
  }
}

import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Agent execution strategy tool")
struct AgentSetExecutionStrategyToolTests {
  private var context: ToolContext {
    ToolContext(actorID: "test", scopes: Set(ToolScope.allCases), source: .userInterface)
  }

  @Test("Persists supported provider-native execution strategies")
  func persistsSupportedStrategies() async throws {
    let store = await MainActor.run { CanvasStore() }
    let claudeID = try await makeAgentNode(provider: .claudeCode, store: store)
    let codexID = try await makeAgentNode(provider: .codex, store: store)
    let tool = AgentSetExecutionStrategyTool(store: store)

    let workflow = try await tool.call(
      AgentSetExecutionStrategyInput(
        agentID: claudeID, executionStrategy: .scriptedWorkflow),
      context: context
    )
    #expect(workflow.executionStrategy == .scriptedWorkflow)

    let delegated = try await tool.call(
      AgentSetExecutionStrategyInput(agentID: codexID, executionStrategy: .delegated),
      context: context
    )
    #expect(delegated.executionStrategy == .delegated)

    let saved = await MainActor.run {
      store.activeCanvas.nodes.first { $0.id == claudeID }?.agentDefinition
    }
    #expect(saved?.effectiveExecutionStrategy == .scriptedWorkflow)
  }

  @Test("Rejects Claude workflows for Codex and delegation for shells")
  func rejectsUnsupportedStrategies() async throws {
    let store = await MainActor.run { CanvasStore() }
    let codexID = try await makeAgentNode(provider: .codex, store: store)
    let shellID = try await makeAgentNode(provider: .shell, store: store)
    let tool = AgentSetExecutionStrategyTool(store: store)

    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        AgentSetExecutionStrategyInput(
          agentID: codexID, executionStrategy: .scriptedWorkflow),
        context: context)
    }
    await #expect(throws: ToolRegistryError.self) {
      _ = try await tool.call(
        AgentSetExecutionStrategyInput(agentID: shellID, executionStrategy: .delegated),
        context: context)
    }
  }

  @Test("Every AI harness supports delegation")
  func allHarnessesDelegate() async throws {
    let store = await MainActor.run { CanvasStore() }
    let tool = AgentSetExecutionStrategyTool(store: store)
    for provider in AgentProvider.allCases where provider != .shell {
      let id = try await makeAgentNode(provider: provider, store: store)
      let result = try await tool.call(
        AgentSetExecutionStrategyInput(agentID: id, executionStrategy: .delegated), context: context
      )
      #expect(result.executionStrategy == .delegated)
    }
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
}

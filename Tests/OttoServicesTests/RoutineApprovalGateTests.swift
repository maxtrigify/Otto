import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoServices

struct RoutineApprovalGateTests {
  @MainActor @Test func agentSourcedCreateCannotArmRoutine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-routine-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Routine gate")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let services = ApplicationServices(store: store, registry: registry, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let routine = Routine(
      name: "Agent proposal", instruction: "Run later",
      trigger: .schedule(cron: nil, intervalSeconds: 300),
      target: .existingAgent(nodeID: UUID()), enabled: true)
    let result = try await registry.call(
      name: "routine.create", input: try JSONValue.encode(RoutineMutationInput(routine: routine)),
      context: ToolContext(
        actorID: "test-agent", scopes: [.canvasWrite], source: .agent,
        sourceNodeID: UUID(), sourceCanvasID: store.activeCanvas.id))
    let saved = try result.decode(Routine.self)
    #expect(saved.enabled == false)
  }

  @MainActor @Test func agentSourcedUpdateCannotEnableDisabledRoutine() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-routine-update-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Routine gate")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let services = ApplicationServices(store: store, registry: registry, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    var routine = try await services.saveRoutine(
      Routine(
        name: "Disabled", instruction: "Run later",
        trigger: .schedule(cron: nil, intervalSeconds: 300),
        target: .existingAgent(nodeID: UUID()), enabled: false))
    routine.enabled = true
    let result = try await registry.call(
      name: "routine.update", input: try JSONValue.encode(RoutineMutationInput(routine: routine)),
      context: ToolContext(actorID: "test-agent", scopes: [.canvasWrite], source: .agent))
    #expect(try result.decode(Routine.self).enabled == false)
  }

  @MainActor @Test func automationCannotInvokeConfirmationTool() async throws {
    let registry = ToolRegistry()
    try await registry.register(RoutineDeleteTool { _ in true })
    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: "routine.delete", input: try JSONValue.encode(RoutineDeleteInput(id: UUID())),
        context: ToolContext(
          actorID: "routine", scopes: [.globalDestructive], source: .automation,
          interactionPrivileges: []))
    }
  }
}

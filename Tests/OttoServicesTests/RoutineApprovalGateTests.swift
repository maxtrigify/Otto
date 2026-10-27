import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

struct RoutineApprovalGateTests {
  @MainActor @Test(arguments: [ToolInvocationSource.agent, .automation, .voice, .userInterface])
  func authorizedSourcesCanCreateAndToggleAutomation(source: ToolInvocationSource) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-routine-enable-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Routine controls")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let services = ApplicationServices(
      store: store, registry: registry, secrets: InMemorySecretStore(), workspacePath: root.path)
    try await services.registerRoutineTools()
    let context = ToolContext(
      actorID: "test-\(source.rawValue)", scopes: [.canvasWrite], source: source,
      sourceNodeID: UUID(), sourceCanvasID: canvas.id)
    let routine = Routine(
      name: "Meeting learning", instruction: "Read yesterday's meeting transcripts",
      trigger: .schedule(cron: "0 7 * * *", intervalSeconds: nil),
      target: .spawnProfile(profileID: UUID()), enabled: true)
    let created = try await registry.call(
      name: "routine.create", input: try JSONValue.encode(RoutineMutationInput(routine: routine)),
      context: context)
    var saved = try created.decode(Routine.self)
    #expect(saved.enabled)
    #expect(services.routines.routine(id: saved.id)?.enabled == true)

    // Pausing and re-enabling must preserve the definition and survive a store reload.
    for enabled in [false, true] {
      saved.enabled = enabled
      let result = try await registry.call(
        name: "routine.update", input: try JSONValue.encode(RoutineMutationInput(routine: saved)),
        context: context)
      saved = try result.decode(Routine.self)
      let persisted = RoutineStore(workspacePath: root.path).routine(id: saved.id)
      #expect(saved.enabled == enabled)
      #expect(persisted?.enabled == enabled)
      #expect(persisted?.instruction == routine.instruction)
      #expect(persisted?.trigger == routine.trigger)
      #expect(persisted?.target == routine.target)
    }
  }

  @MainActor @Test(arguments: [ToolInvocationSource.agent, .automation])
  func webhookStillNeedsSigningSecret(source: ToolInvocationSource) async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-routine-webhook-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Webhook controls")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    let services = ApplicationServices(
      store: store, registry: registry, secrets: InMemorySecretStore(), workspacePath: root.path)
    try await services.registerRoutineTools()
    let context = ToolContext(actorID: "test", scopes: [.canvasWrite], source: source)
    var routine = Routine(
      name: "Webhook", instruction: "Process the event",
      trigger: .webhook(slug: "meeting", filter: nil),
      target: .existingAgent(nodeID: UUID()), enabled: true)
    for tool in ["routine.create", "routine.update"] {
      routine.enabled = true
      let result = try await registry.call(
        name: tool, input: try JSONValue.encode(RoutineMutationInput(routine: routine)),
        context: context)
      routine = try result.decode(Routine.self)
      #expect(routine.enabled == false)
      #expect(services.routines.routine(id: routine.id)?.enabled == false)
    }
  }

  @MainActor @Test(arguments: ["routine.create", "routine.update"])
  func enablingRequiresWriteScope(tool: String) async throws {
    let registry = ToolRegistry()
    try await registry.register(RoutineCreateTool { routine, _ in routine })
    try await registry.register(RoutineUpdateTool { routine, _ in routine })
    let routine = Routine(
      name: "Unauthorized", instruction: "Run later",
      trigger: .schedule(cron: nil, intervalSeconds: 300),
      target: .existingAgent(nodeID: UUID()), enabled: true)
    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: tool, input: try JSONValue.encode(RoutineMutationInput(routine: routine)),
        context: ToolContext(actorID: "read-only", scopes: [.agentRead], source: .agent))
    }
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

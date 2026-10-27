import Foundation
import OttoCore
import OttoModels
import OttoPersistence
import OttoRuntime
import OttoTools
import Testing

@testable import OttoApp
@testable import OttoServices

@Suite("Live space switching", .serialized)
@MainActor
struct SpaceSwitchingTests {
  @Test("An agent keeps its PID and output across A to B to A, with isolated persisted stores")
  func runningAgentSurvivesSwitch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-space-switch-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = OttoProfileRegistry(
      applicationSupport: root,
      originalWorkspacePath: root.appending(path: "A").path)
    let a = try #require(registry.active)
    let b = try registry.create(name: "B", symbol: "heart", folder: root.appending(path: "B"))
    let location = registry.locations(for: a)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: location.databasePath).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let database = SQLiteWorkspaceStore(path: location.databasePath)
    let store = CanvasStore(persistence: database)
    let tools = ToolRegistry()
    let services = ApplicationServices(
      store: store, registry: tools, workspacePath: a.workspacePath,
      personalMemoryPath: location.personalMemoryPath, profiles: registry)
    let voice = VoiceController(
      registry: tools, store: store, services: services, workspacePath: a.workspacePath)
    let original = OttoSpaceRuntime(store: store, services: services, voice: voice)
    let controller = OttoSpaceController(
      initial: original, registry: registry, presentationEnabled: false)
    controller.startActive()
    await original.ready()
    let receipt = store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
    let nodeID = try #require(receipt.affectedNodeIDs.first)
    let release = root.appending(path: "release")
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "printf 'OTTO_STATUS:WORKING\\nbefore-switch\\n'; while [ ! -f \"$1\" ]; do sleep 0.05; done; printf 'after-switch\\nOTTO_STATUS:DONE\\n'",
          "fixture", release.path,
        ], workingDirectory: root.path), id: nodeID, successfulExitState: .done)
    try await waitUntil { services.fleet[nodeID]?.output.contains("before-switch") == true }
    let pid = try #require(services.fleet[nodeID]?.processID)
    let runID = services.fleet[nodeID]?.runID
    let socket = services.controlSocketPath
    try await controller.switchTo(b)
    #expect(controller.switcherProfiles.map(\.id) == [b.id, a.id])
    let second = controller.active
    await second.ready()
    #expect(second !== original)
    #expect(second.services.controlSocketPath != socket)
    #expect(!second.store.activeCanvas.nodes.contains { $0.id == nodeID })
    #expect(controller.activeProcessCount > 0)
    #expect(await controller.busyProcessCount() > 0)
    #expect(services.fleet[nodeID]?.processID == pid)
    try await controller.switchTo(a)
    #expect(controller.active === original)
    #expect(controller.switcherProfiles.map(\.id) == [a.id, b.id])
    #expect(services.fleet[nodeID]?.processID == pid)
    #expect(services.fleet[nodeID]?.runID == runID)
    try await controller.switchTo(b)
    // Complete while A is hidden; no restart or resumed replacement process is involved.
    try Data().write(to: release)
    try await waitUntil {
      services.fleet[nodeID]?.state == .done && services.fleet[nodeID]?.processID == nil
    }
    try await controller.switchTo(a)
    #expect(controller.active === original)
    #expect(controller.active.services === services)
    #expect(services.controlSocketPath == socket)
    #expect(services.fleet[nodeID]?.processID == nil)
    #expect(services.fleet[nodeID]?.runID == runID)
    #expect(services.fleet[nodeID]?.output.contains("before-switch") == true)
    #expect(services.fleet[nodeID]?.output.contains("after-switch") == true)
    for _ in 0..<3 {
      try await controller.switchTo(b)
      try await controller.switchTo(a)
    }
    #expect(controller.opened.count == 2)
    #expect(controller.opened[1] === second)
    await controller.flushPersistence()
    let restored = CanvasStore(persistence: SQLiteWorkspaceStore(path: location.databasePath))
    await restored.restore()
    #expect(restored.activeCanvas.nodes.contains { $0.id == nodeID })
    for runtime in controller.opened { await runtime.services.shutdown() }
  }

  @Test("Deleting or re-pointing a space closes its background runtime and spares the open one")
  func deleteAndRelocateThroughController() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-space-delete-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = OttoProfileRegistry(
      applicationSupport: root, originalWorkspacePath: root.appending(path: "A").path)
    let a = try #require(registry.active)
    let b = try registry.create(name: "B", symbol: "heart", folder: root.appending(path: "B"))
    let c = try registry.create(name: "C", symbol: "leaf", folder: root.appending(path: "C"))
    let store = CanvasStore()
    let tools = ToolRegistry()
    let services = ApplicationServices(
      store: store, registry: tools, workspacePath: a.workspacePath, profiles: registry)
    let runtime = OttoSpaceRuntime(
      store: store, services: services,
      voice: VoiceController(
        registry: tools, store: store, services: services, workspacePath: a.workspacePath))
    let controller = OttoSpaceController(
      initial: runtime, registry: registry, presentationEnabled: false)
    controller.startActive()
    await runtime.ready()

    await #expect(throws: OttoProfileRegistry.RegistryError.activeProfile) {
      _ = try await controller.delete(a, removingOttoData: true)
    }
    try await controller.switchTo(b)
    try await controller.switchTo(c)
    #expect(controller.opened.count == 3)
    // The launch space backs Settings and app commands, so it waits for a relaunch.
    await #expect(throws: OttoProfileRegistry.RegistryError.openedAtLaunch) {
      _ = try await controller.delete(a, removingOttoData: false)
    }
    let moved = root.appending(path: "B moved")
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    let relocated = try await controller.relocate(b, to: moved)
    #expect(relocated.workspacePath == moved.standardizedFileURL.path)
    #expect(controller.opened.count == 2)
    #expect(!controller.opened.contains { $0.id == b.workspacePath })

    let report = try await controller.delete(relocated, removingOttoData: false)
    #expect(report.discarded.isEmpty)
    #expect(registry.profiles.map(\.id) == [a.id, c.id])
    #expect(controller.switcherProfiles.map(\.id) == [c.id, a.id])
    #expect(FileManager.default.fileExists(atPath: moved.path))
    for runtime in controller.opened { await runtime.services.shutdown() }
  }

  @Test("An invalid destination leaves the current runtime and active preference alone")
  func invalidDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-space-invalid-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = OttoProfileRegistry(applicationSupport: root, originalWorkspacePath: root.path)
    let originalProfile = registry.active
    let store = CanvasStore()
    let tools = ToolRegistry()
    let services = ApplicationServices(store: store, registry: tools, workspacePath: root.path)
    let runtime = OttoSpaceRuntime(
      store: store, services: services,
      voice: VoiceController(
        registry: tools, store: store, services: services, workspacePath: root.path))
    let controller = OttoSpaceController(
      initial: runtime, registry: registry, presentationEnabled: false)
    await #expect(throws: OttoProfileRegistry.RegistryError.unknownProfile) {
      try await controller.switchTo(
        OttoProfile(name: "Unknown", symbol: "heart", workspacePath: "/missing"))
    }
    #expect(controller.active === runtime)
    #expect(controller.opened.count == 1)
    #expect(registry.active == originalProfile)
    let broken = try registry.create(
      name: "Unreadable", symbol: "heart", folder: root.appending(path: "broken"))
    let path = URL(fileURLWithPath: registry.locations(for: broken).databasePath)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalBytes = Data("unreadable database fixture".utf8)
    try originalBytes.write(to: path)
    await #expect(throws: (any Error).self) { try await controller.switchTo(broken) }
    #expect(controller.active === runtime)
    #expect(controller.opened.count == 1)
    #expect(registry.active == originalProfile)
    #expect(controller.switcherProfiles.first?.id == originalProfile?.id)
    #expect(try Data(contentsOf: path) == originalBytes)

  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition())
  }
}

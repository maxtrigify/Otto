import Foundation
import OttoCore
import OttoMemory
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

@MainActor
@Suite("Automatic run logging")
struct AutoRunLoggingTests {
  @Test("Completed structured runs land in the Project Brain log exactly once")
  func autoLogsCompletedRunsOnce() async throws {
    let workspace = FileManager.default.temporaryDirectory
      .appending(path: "otto-autolog-\(UUID().uuidString)", directoryHint: .isDirectory).path
    try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: workspace) }

    let canvas = OttoCanvas(name: "Auto log")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(
      store: store, secrets: InMemorySecretStore(), workspacePath: workspace)
    let brain = try #require(services.brain)

    let nodeID = try #require(
      store.dispatch(
        .createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))
      ).affectedNodeIDs.first)
    let captured = try services.conversationProjects.capture(nodeID: nodeID, channelID: nodeID)
    #expect(
      captured.context.projectID
        == services.conversationProjects.projects.first { $0.isLegacyWorkspace }?.id)
    var snapshot = AgentRuntimeSnapshot(
      id: nodeID,
      provider: .claudeCode,
      state: .done,
      confidence: 1,
      structuredResult: AgentResult(
        status: .done,
        summaryCandidate: "Shipped the memory layer with citations.",
        rawText: "Shipped the memory layer with citations.",
        filesChanged: ["Sources/OttoMemory/MemoryModels.swift"],
        commandsRun: ["swift test"]
      ),
      lastPrompt: "Wire the memory layer end to end"
    )

    services.autoLogRunCompletion(snapshot)
    try await waitUntil {
      (try? await brain.list(type: .log).records.count) == 1
    }
    let logged = try await brain.list(type: .log).records
    #expect(logged[0].title == "Wire the memory layer end to end")
    #expect(logged[0].author == "otto:auto-log")
    #expect(logged[0].tags.contains("auto"))
    #expect(logged[0].sourceIDs == ["agent:\(snapshot.id.uuidString)"])
    #expect(logged[0].body.contains("Files changed:"))

    // The same outcome never logs twice, no matter how many lifecycle events replay it.
    services.autoLogRunCompletion(snapshot)
    services.autoLogRunCompletion(snapshot)
    try await Task.sleep(for: .milliseconds(250))
    let afterReplay = try await brain.list(type: .log).records.count
    #expect(afterReplay == 1)

    // A genuinely new outcome for the same node logs again.
    snapshot.structuredResult = AgentResult(
      status: .done,
      summaryCandidate: "Fixed the follow-up review notes.",
      rawText: "Fixed the follow-up review notes."
    )
    services.autoLogRunCompletion(snapshot)
    try await waitUntil {
      (try? await brain.list(type: .log).records.count) == 2
    }

    // Interactive scrapes (no structured result) and failed runs never auto-log.
    var unstructured = snapshot
    unstructured.structuredResult = nil
    services.autoLogRunCompletion(unstructured)
    var failed = snapshot
    failed.state = .failed
    services.autoLogRunCompletion(failed)
    try await Task.sleep(for: .milliseconds(250))
    let finalCount = try await brain.list(type: .log).records.count
    #expect(finalCount == 2)

    // Explicitly unassigned future work must not write into the workspace brain.
    try services.selectProject(channelID: nodeID, projectID: nil)
    _ = try services.conversationProjects.capture(nodeID: nodeID, channelID: nodeID)
    snapshot.structuredResult = AgentResult(
      status: .done, summaryCandidate: "Unassigned result", rawText: "Unassigned result")
    services.autoLogRunCompletion(snapshot)
    try await Task.sleep(for: .milliseconds(250))
    #expect(try await brain.list(type: .log).records.count == 2)
  }

  private func waitUntil(
    _ condition: @escaping () async -> Bool, timeout: Duration = .seconds(5)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(Bool(false), "Timed out waiting for condition")
  }
}

import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Agent resource scheduler")
struct AgentResourceSchedulerTests {
  #if os(macOS)
    @Test("Combined resource pressure uses the most restrictive signal")
    @MainActor
    func combinedPressure() {
      #expect(
        AgentResourcePressureMonitor.combined(memory: .nominal, thermal: .elevated)
          == .elevated)
      #expect(
        AgentResourcePressureMonitor.combined(memory: .critical, thermal: .nominal)
          == .critical)
      #expect(
        AgentResourcePressureMonitor.combined(memory: .nominal, thermal: .nominal)
          == .nominal)
    }
  #endif

  @Test("Workers queue FIFO and release admits the next worker")
  func queuesFIFO() async throws {
    let scheduler = AgentResourceScheduler(
      configuration: .init(nominalLimit: 2, elevatedLimit: 1, criticalLimit: 1))
    let first = UUID()
    let second = UUID()
    let third = UUID()
    try await scheduler.acquire(first)
    try await scheduler.acquire(second)
    let waiting = Task { try await scheduler.acquire(third) }

    await Task.yield()
    var snapshot = await scheduler.snapshot()
    #expect(Set(snapshot.running) == [first, second])
    #expect(snapshot.queued == [third])

    await scheduler.release(first)
    try await waiting.value
    snapshot = await scheduler.snapshot()
    #expect(Set(snapshot.running) == [second, third])
    #expect(snapshot.queued.isEmpty)
  }

  @Test("Pressure reductions hold new workers without killing active work")
  func pressureReducesAdmission() async throws {
    let scheduler = AgentResourceScheduler(
      configuration: .init(nominalLimit: 3, elevatedLimit: 2, criticalLimit: 1))
    let ids = (0..<4).map { _ in UUID() }
    try await scheduler.acquire(ids[0])
    try await scheduler.acquire(ids[1])
    await scheduler.updatePressure(.critical)
    let waiting = Task { try await scheduler.acquire(ids[2]) }

    await Task.yield()
    var snapshot = await scheduler.snapshot()
    #expect(snapshot.running.count == 2)
    #expect(snapshot.queued == [ids[2]])

    await scheduler.release(ids[0])
    await Task.yield()
    snapshot = await scheduler.snapshot()
    #expect(snapshot.running == [ids[1]])
    #expect(snapshot.queued == [ids[2]])

    await scheduler.release(ids[1])
    try await waiting.value
    let finalSnapshot = await scheduler.snapshot()
    #expect(finalSnapshot.running == [ids[2]])
  }

  @Test("Cancelling a queued worker removes it without consuming capacity")
  func cancellation() async throws {
    let scheduler = AgentResourceScheduler(
      configuration: .init(nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
    let running = UUID()
    let cancelled = UUID()
    try await scheduler.acquire(running)
    let waiting = Task { try await scheduler.acquire(cancelled) }
    await Task.yield()
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }

    let snapshot = await scheduler.snapshot()
    #expect(snapshot.running == [running])
    #expect(snapshot.queued.isEmpty)
  }

  @Test("One-shot process exit releases capacity to the next supervised worker")
  func supervisorReleasesPermitOnExit() async throws {
    let scheduler = AgentResourceScheduler(
      configuration: .init(nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
    let supervisor = AgentSupervisor(resourceScheduler: scheduler)
    let first = UUID()
    let second = UUID()
    let request = AgentLaunchRequest(
      workspacePath: FileManager.default.currentDirectoryPath,
      prompt: "work",
      permissionMode: .readOnly
    )

    // The first worker must still hold the only slot when the second one is spawned and queued;
    // on a loaded CI runner that can take well over a second, so give it ample time.
    _ = try await supervisor.spawnOneShot(
      adapter: DelayedOneShotAdapter(delay: 5), request: request, id: first)
    try await waitForSchedulerRunning(first, scheduler: scheduler)
    let secondSpawn = Task {
      try await supervisor.spawnOneShot(
        adapter: DelayedOneShotAdapter(delay: 3), request: request, id: second)
    }

    try await waitForSchedulerQueue(second, scheduler: scheduler)
    var schedulerSnapshot = await scheduler.snapshot()
    #expect(schedulerSnapshot.running == [first])
    _ = try await secondSpawn.value
    #expect(try await supervisor.snapshot(agentID: first).exitCode == 0)
    schedulerSnapshot = await scheduler.snapshot()
    #expect(schedulerSnapshot.running == [second])

    try await waitForSchedulerIdle(scheduler)
    #expect(try await supervisor.snapshot(agentID: second).exitCode == 0)
  }
}

private struct DelayedOneShotAdapter: AgentAdapter {
  let provider = AgentProvider.codex
  let delay: Double

  func detectInstallation() async -> InstallationStatus {
    .installed(path: "/bin/sh", version: "fixture")
  }

  func availableModels() async -> [AgentModel] { [] }

  func buildLaunchSpec(_ request: AgentLaunchRequest) async throws -> ProcessLaunchSpec {
    ProcessLaunchSpec(
      executable: "/bin/sh",
      arguments: ["-c", "sleep \(delay); printf '{\"type\":\"turn.completed\"}\\n'"],
      workingDirectory: request.workspacePath
    )
  }
}

private func waitForSchedulerQueue(
  _ id: UUID,
  scheduler: AgentResourceScheduler
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if await scheduler.snapshot().queued.contains(id) { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for scheduler queue")
}

private func waitForSchedulerRunning(
  _ id: UUID,
  scheduler: AgentResourceScheduler
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if await scheduler.snapshot().running.contains(id) { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for scheduler admission")
}

private func waitForSchedulerIdle(_ scheduler: AgentResourceScheduler) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while ContinuousClock.now < deadline {
    let snapshot = await scheduler.snapshot()
    if snapshot.running.isEmpty, snapshot.queued.isEmpty { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Timed out waiting for scheduler to become idle")
}

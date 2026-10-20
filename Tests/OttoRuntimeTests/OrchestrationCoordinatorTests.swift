import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Orchestration coordinator")
struct OrchestrationCoordinatorTests {
  @Test("Two workers converge through one reviewer under scheduler control")
  func twoWorkersOneReviewer() async throws {
    let fixture = fixtureURL()
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let assignments = [
      OrchestrationAssignment(title: "Implementation", expectedOutput: "Patch"),
      OrchestrationAssignment(title: "Validation", expectedOutput: "Test evidence"),
    ]
    let store = OrchestrationRunStore(fileURL: fixture)
    _ = try await store.create(
      OrchestrationRun(
        objective: "Complete one acceptance scenario",
        acceptanceCriteria: ["Both outputs exist", "Reviewer passes"],
        assignments: assignments,
        reviewer: .simplicityAware(provider: .codex),
        permissionGrant: .workspaceWrite,
        spendPolicy: OrchestrationSpendPolicy(maximumWorkers: 2)))
    let scheduler = AgentResourceScheduler(
      configuration: .init(nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
    let worker = RecordingWorker()
    let reviewer = RecordingReviewer()

    let result = try await OrchestrationCoordinator(store: store, scheduler: scheduler)
      .run(worker: worker, reviewer: reviewer)

    #expect(result.phase == .passed)
    #expect(result.assignments.allSatisfy { $0.status == .completed })
    #expect(await worker.executionCount == 2)
    #expect(await worker.maximumConcurrency == 1)
    #expect(await reviewer.reviewCount == 1)
    #expect((result.checkpointSequence ?? 0) >= 6)
  }

  @Test("Reviewer disagreement stops for the user instead of looping")
  func reviewerDisagreement() async throws {
    let assignment = OrchestrationAssignment(title: "Review", expectedOutput: "Evidence")
    let store = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await store.create(
      OrchestrationRun(
        objective: "Surface disagreement",
        acceptanceCriteria: ["Stop safely"],
        assignments: [assignment],
        reviewer: .simplicityAware(provider: .codex),
        permissionGrant: .workspaceWrite,
        spendPolicy: OrchestrationSpendPolicy(maximumWorkers: 1)))

    let result = try await OrchestrationCoordinator(
      store: store, scheduler: AgentResourceScheduler()
    )
    .run(worker: RecordingWorker(), reviewer: WrongRoundReviewer())

    #expect(result.phase == .needsUser)
    #expect(result.handoff?.reason == "Reviewer disagreement")
  }

  @Test("A correction targets one worker and still terminates")
  func correctionRound() async throws {
    let first = OrchestrationAssignment(title: "First", expectedOutput: "Patch")
    let second = OrchestrationAssignment(title: "Second", expectedOutput: "Tests")
    let store = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await store.create(
      OrchestrationRun(
        objective: "Correct one output",
        acceptanceCriteria: ["Pass"],
        assignments: [first, second],
        reviewer: .simplicityAware(provider: .codex),
        maximumRounds: 2,
        permissionGrant: .workspaceWrite,
        spendPolicy: OrchestrationSpendPolicy(maximumWorkers: 2)))
    let reviewer = CorrectOnceReviewer(correctionID: first.id)
    let worker = RecordingWorker()

    let result = try await OrchestrationCoordinator(
      store: store, scheduler: AgentResourceScheduler()
    )
    .run(worker: worker, reviewer: reviewer)

    #expect(result.phase == .passed)
    #expect(result.currentRound == 2)
    #expect(await worker.count(for: first.id) == 2)
    #expect(await worker.count(for: second.id) == 1)
    #expect(await reviewer.reviewCount == 2)
  }

  private func fixtureURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "otto-coordinator-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "run.json")
  }
}

private actor RecordingWorker: OrchestrationWorkerExecutor {
  private var active = 0
  private(set) var maximumConcurrency = 0
  private(set) var executionCount = 0
  private var counts: [UUID: Int] = [:]

  func execute(
    assignment: OrchestrationAssignment,
    contract: OrchestrationRun,
    executionID: UUID
  ) async throws -> OrchestrationWorkerOutput {
    active += 1
    maximumConcurrency = max(maximumConcurrency, active)
    executionCount += 1
    counts[assignment.id, default: 0] += 1
    try await Task.sleep(for: .milliseconds(10))
    active -= 1
    return OrchestrationWorkerOutput(
      result: "Completed \(assignment.title)",
      evidence: ["fixture://\(contract.currentRound)/\(executionID.uuidString)"],
      completedRevision: "revision-\(contract.currentRound)")
  }

  func count(for assignmentID: UUID) -> Int { counts[assignmentID, default: 0] }
}

private actor RecordingReviewer: OrchestrationReviewExecutor {
  private(set) var reviewCount = 0

  func review(contract: OrchestrationRun) -> OrchestrationReview {
    reviewCount += 1
    return OrchestrationReview(
      round: contract.currentRound,
      verdict: .pass,
      findings: [],
      simplicityFinding: "The result is appropriately small",
      evidence: ["review://\(contract.currentRound)"])
  }
}

private actor CorrectOnceReviewer: OrchestrationReviewExecutor {
  let correctionID: UUID
  private(set) var reviewCount = 0

  init(correctionID: UUID) { self.correctionID = correctionID }

  func review(contract: OrchestrationRun) -> OrchestrationReview {
    reviewCount += 1
    if contract.currentRound == 1 {
      return OrchestrationReview(
        round: 1,
        verdict: .correctionsRequired,
        findings: ["First output needs correction"],
        simplicityFinding: "Remove one layer",
        evidence: ["review://1"],
        correctionAssignmentIDs: [correctionID])
    }
    return OrchestrationReview(
      round: contract.currentRound,
      verdict: .pass,
      findings: [],
      simplicityFinding: "Correction is simple",
      evidence: ["review://2"])
  }
}

private struct WrongRoundReviewer: OrchestrationReviewExecutor {
  func review(contract: OrchestrationRun) -> OrchestrationReview {
    OrchestrationReview(
      round: contract.currentRound + 1,
      verdict: .pass,
      findings: [],
      simplicityFinding: "Conflicting round",
      evidence: ["review://wrong-round"])
  }
}

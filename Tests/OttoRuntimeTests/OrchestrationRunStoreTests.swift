import Foundation
import OttoModels
import OttoRuntime
import Testing

@Suite("Durable orchestration pipe")
struct OrchestrationRunStoreTests {
  @Test("One record survives reload and advances only through explicit calls")
  func durableFlow() async throws {
    let fixture = fixtureURL()
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let assignment = OrchestrationAssignment(
      title: "Implement status", expectedOutput: "Passing tests and screenshot")
    let contract = makeContract(assignments: [assignment], maximumRounds: 2)
    let store = OrchestrationRunStore(fileURL: fixture)

    _ = try await store.create(contract)
    #expect(try await store.current()?.phase == .planning)
    _ = try await store.beginWorkers()
    let reviewed = try await store.recordWorkerResult(
      assignmentID: assignment.id, result: "Implemented", succeeded: true)
    #expect(reviewed.phase == .review)

    let reloaded = try #require(await OrchestrationRunStore(fileURL: fixture).current())
    #expect(reloaded.id == contract.id)
    #expect(reloaded.phase == .review)
  }

  @Test("Reviewer corrections are bounded and escalate instead of looping forever")
  func boundedCorrections() async throws {
    let fixture = fixtureURL()
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let assignment = OrchestrationAssignment(title: "Simplify", expectedOutput: "Small solution")
    let store = OrchestrationRunStore(fileURL: fixture)
    _ = try await store.create(makeContract(assignments: [assignment], maximumRounds: 1))
    _ = try await store.beginWorkers()
    _ = try await store.recordWorkerResult(
      assignmentID: assignment.id, result: "Too complex", succeeded: true)
    let result = try await store.submitReview(
      OrchestrationReview(
        round: 1,
        verdict: .correctionsRequired,
        findings: ["Acceptance evidence is incomplete"],
        simplicityFinding: "The solution has unnecessary layers",
        correctionAssignmentIDs: [assignment.id]
      ))

    #expect(result.phase == .escalated)
    #expect(result.escalationReason == "Maximum correction rounds reached")
    #expect(result.reviews.count == 1)
  }

  @Test("Default reviewer contract explicitly checks simplicity")
  func simplicityReviewer() {
    let reviewer = OrchestrationReviewer.simplicityAware(provider: .codex)
    #expect(reviewer.rubric.contains { $0.localizedCaseInsensitiveContains("complicated") })
    #expect(reviewer.rubric.contains { $0.localizedCaseInsensitiveContains("simplified") })
  }

  @Test("Passing requires fresh worker and reviewer evidence")
  func evidenceGate() async throws {
    let fixture = fixtureURL()
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let assignment = OrchestrationAssignment(title: "Verify", expectedOutput: "Evidence")
    let store = OrchestrationRunStore(fileURL: fixture)
    _ = try await store.create(makeContract(assignments: [assignment], maximumRounds: 2))
    _ = try await store.beginWorkers()
    _ = try await store.recordWorkerResult(
      assignmentID: assignment.id, result: "Done", succeeded: true)

    await #expect(throws: OrchestrationRunError.self) {
      try await store.submitReview(
        OrchestrationReview(
          round: 1, verdict: .pass, findings: [], simplicityFinding: "Simple"))
    }

    let executionID = UUID()
    let retryStore = OrchestrationRunStore(fileURL: fixtureURL())
    let retryAssignment = OrchestrationAssignment(title: "Verify", expectedOutput: "Evidence")
    _ = try await retryStore.create(
      makeContract(assignments: [retryAssignment], maximumRounds: 2))
    _ = try await retryStore.beginWorkers()
    _ = try await retryStore.claimAssignment(
      assignmentID: retryAssignment.id, executionID: executionID)
    _ = try await retryStore.recordWorkerResult(
      assignmentID: retryAssignment.id,
      result: "Done",
      succeeded: true,
      executionID: executionID,
      evidence: ["test://passing"])
    let passed = try await retryStore.submitReview(
      OrchestrationReview(
        round: 1,
        verdict: .pass,
        findings: [],
        simplicityFinding: "No unnecessary layers",
        evidence: ["review://fresh"])
    )
    #expect(passed.phase == .passed)
  }

  @Test("A durable execution claim resumes without duplicate effects")
  func idempotentRecovery() async throws {
    let fixture = fixtureURL()
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let assignment = OrchestrationAssignment(title: "Write once", expectedOutput: "One mutation")
    let executionID = UUID()
    let store = OrchestrationRunStore(fileURL: fixture)
    _ = try await store.create(makeContract(assignments: [assignment], maximumRounds: 2))
    _ = try await store.beginWorkers()
    _ = try await store.claimAssignment(
      assignmentID: assignment.id, executionID: executionID)

    let reloaded = OrchestrationRunStore(fileURL: fixture)
    let resumed = try #require(await reloaded.resume())
    #expect(resumed.assignments[0].executionID == executionID)
    let replay = try await reloaded.claimAssignment(
      assignmentID: assignment.id, executionID: executionID)
    #expect(replay.checkpointSequence == resumed.checkpointSequence)
    await #expect(throws: OrchestrationRunError.self) {
      try await reloaded.claimAssignment(assignmentID: assignment.id, executionID: UUID())
    }
  }

  @Test("Failure, cancellation, timeout, and quota are explicit terminal states")
  func terminalStates() async throws {
    let failureAssignment = OrchestrationAssignment(title: "Fail", expectedOutput: "Result")
    let failureStore = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await failureStore.create(
      makeContract(assignments: [failureAssignment], maximumRounds: 2))
    _ = try await failureStore.beginWorkers()
    let failed = try await failureStore.recordWorkerResult(
      assignmentID: failureAssignment.id, result: "Provider failed", succeeded: false)
    #expect(failed.phase == .failed)

    let cancelStore = try await activeStore()
    #expect(try await cancelStore.cancel(reason: "User stopped").phase == .cancelled)

    let timeoutStore = try await activeStore()
    #expect(try await timeoutStore.timeout().assignments[0].status == .timedOut)

    let quotaStore = try await activeStore()
    let quota = try await quotaStore.reportQuotaHandoff(details: ["Reset at 13:00"])
    #expect(quota.phase == .needsUser)
    #expect(quota.handoff?.details == ["Reset at 13:00"])
  }

  @Test("Permission grants cannot expand themselves")
  func permissionCeiling() async throws {
    let store = OrchestrationRunStore(fileURL: fixtureURL())
    let assignment = OrchestrationAssignment(title: "Read", expectedOutput: "Report")
    _ = try await store.create(
      OrchestrationRun(
        objective: "Inspect",
        acceptanceCriteria: ["Report exists"],
        assignments: [assignment],
        reviewer: .simplicityAware(provider: .codex),
        permissionGrant: .readOnly,
        spendPolicy: OrchestrationSpendPolicy(maximumWorkers: 1)))
    try await store.authorize(.readOnly)
    await #expect(throws: OrchestrationRunError.self) {
      try await store.authorize(.workspaceWrite)
    }
  }

  @Test("Metered work requires and obeys a spend ceiling")
  func spendCeiling() async throws {
    let assignment = OrchestrationAssignment(title: "Metered", expectedOutput: "Result")
    let deniedStore = OrchestrationRunStore(fileURL: fixtureURL())
    await #expect(throws: OrchestrationRunError.self) {
      try await deniedStore.create(
        OrchestrationRun(
          objective: "Run metered work",
          acceptanceCriteria: ["Done"],
          assignments: [assignment],
          reviewer: .simplicityAware(provider: .codex),
          permissionGrant: .workspaceWrite,
          spendPolicy: OrchestrationSpendPolicy(
            maximumWorkers: 1, billingMode: .metered)))
    }

    let boundedStore = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await boundedStore.create(
      OrchestrationRun(
        objective: "Run bounded work",
        acceptanceCriteria: ["Done"],
        assignments: [assignment],
        reviewer: .simplicityAware(provider: .codex),
        permissionGrant: .workspaceWrite,
        spendPolicy: OrchestrationSpendPolicy(
          maximumWorkers: 1,
          maximumEstimatedCost: 2,
          billingMode: .metered)))
    let exhausted = try await boundedStore.recordSpend(2)
    #expect(exhausted.phase == .budgetExhausted)
    #expect(exhausted.handoff?.reason == "Configured spend ceiling reached")

    let subscriptionStore = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await subscriptionStore.create(
      makeContract(assignments: [assignment], maximumRounds: 2))
    #expect(
      try await subscriptionStore.current()?.spendPolicy.effectiveBillingMode == .subscription)
  }

  @Test("Only one assignment owns merge integration")
  func mergeOwnership() async throws {
    let first = OrchestrationAssignment(title: "First", expectedOutput: "Patch")
    let second = OrchestrationAssignment(title: "Second", expectedOutput: "Patch")
    let store = OrchestrationRunStore(fileURL: fixtureURL())
    _ = try await store.create(makeContract(assignments: [first, second], maximumRounds: 2))
    _ = try await store.claimMergeOwnership(assignmentID: first.id)
    _ = try await store.claimMergeOwnership(assignmentID: first.id)
    await #expect(throws: OrchestrationRunError.self) {
      try await store.claimMergeOwnership(assignmentID: second.id)
    }
  }

  @Test("Repeated correction runs always terminate within their configured bound")
  func boundedEndurance() async throws {
    for _ in 0..<25 {
      let assignment = OrchestrationAssignment(title: "Bounded", expectedOutput: "Patch")
      let store = OrchestrationRunStore(fileURL: fixtureURL())
      _ = try await store.create(makeContract(assignments: [assignment], maximumRounds: 3))
      for round in 1...3 {
        _ = try await store.beginWorkers()
        _ = try await store.recordWorkerResult(
          assignmentID: assignment.id,
          result: "Round \(round)",
          succeeded: true,
          evidence: ["round://\(round)"])
        let run = try await store.submitReview(
          OrchestrationReview(
            round: round,
            verdict: .correctionsRequired,
            findings: ["Try again"],
            simplicityFinding: "Still too complex",
            evidence: ["review://\(round)"],
            correctionAssignmentIDs: [assignment.id]))
        if round < 3 {
          #expect(run.phase == .corrections)
        } else {
          #expect(run.phase == .escalated)
        }
      }
    }
  }

  private func makeContract(
    assignments: [OrchestrationAssignment], maximumRounds: Int
  ) -> OrchestrationRun {
    OrchestrationRun(
      objective: "Ship the scoped change",
      acceptanceCriteria: ["Tests pass", "Visual evidence matches"],
      assignments: assignments,
      reviewer: .simplicityAware(provider: .codex),
      maximumRounds: maximumRounds,
      permissionGrant: .workspaceWrite,
      spendPolicy: OrchestrationSpendPolicy(maximumWorkers: 4)
    )
  }

  private func fixtureURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "otto-orchestration-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "run.json")
  }

  private func activeStore() async throws -> OrchestrationRunStore {
    let store = OrchestrationRunStore(fileURL: fixtureURL())
    let assignment = OrchestrationAssignment(title: "Active", expectedOutput: "Result")
    _ = try await store.create(makeContract(assignments: [assignment], maximumRounds: 2))
    _ = try await store.beginWorkers()
    return store
  }
}

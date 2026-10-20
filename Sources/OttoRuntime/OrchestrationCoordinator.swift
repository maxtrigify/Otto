import Foundation
import OttoModels

public struct OrchestrationWorkerOutput: Sendable, Equatable {
  public var result: String
  public var evidence: [String]
  public var completedRevision: String?
  public var estimatedCost: Decimal

  public init(
    result: String,
    evidence: [String],
    completedRevision: String? = nil,
    estimatedCost: Decimal = 0
  ) {
    self.result = result
    self.evidence = evidence
    self.completedRevision = completedRevision
    self.estimatedCost = estimatedCost
  }
}

public protocol OrchestrationWorkerExecutor: Sendable {
  func execute(
    assignment: OrchestrationAssignment,
    contract: OrchestrationRun,
    executionID: UUID
  ) async throws -> OrchestrationWorkerOutput
}

public protocol OrchestrationReviewExecutor: Sendable {
  func review(contract: OrchestrationRun) async throws -> OrchestrationReview
}

/// Runs one bounded, durable orchestration loop. Every assignment is checkpointed before effects,
/// admitted through the shared resource scheduler, and reviewed by exactly one designated reviewer.
public actor OrchestrationCoordinator {
  private struct ClaimedJob: Sendable {
    let assignment: OrchestrationAssignment
    let executionID: UUID
  }

  private enum WorkerResult: Sendable {
    case success(OrchestrationAssignment, UUID, OrchestrationWorkerOutput)
    case failure(OrchestrationAssignment, UUID, String)
  }

  private let store: OrchestrationRunStore
  private let scheduler: AgentResourceScheduler

  public init(store: OrchestrationRunStore, scheduler: AgentResourceScheduler) {
    self.store = store
    self.scheduler = scheduler
  }

  public func run(
    worker: any OrchestrationWorkerExecutor,
    reviewer: any OrchestrationReviewExecutor
  ) async throws -> OrchestrationRun {
    do {
      while let current = try await store.current() {
        try Task.checkCancellation()
        if let deadline = current.deadline, deadline <= .now {
          return try await store.timeout()
        }
        switch current.phase {
        case .planning, .corrections:
          _ = try await store.beginWorkers()
        case .workers:
          _ = try await executeWorkerRound(current, worker: worker)
        case .review:
          do {
            let review = try await reviewer.review(contract: current)
            _ = try await store.submitReview(review)
          } catch {
            return try await store.reportNeedsUser(
              reason: "Reviewer disagreement", details: [error.localizedDescription])
          }
        case .passed, .escalated, .failed, .cancelled, .budgetExhausted, .needsUser:
          return current
        }
      }
      throw OrchestrationRunError.invalidContract("No orchestration run exists")
    } catch is CancellationError {
      return try await store.cancel(reason: "Orchestration task cancelled")
    }
  }

  private func executeWorkerRound(
    _ contract: OrchestrationRun,
    worker: any OrchestrationWorkerExecutor
  ) async throws -> OrchestrationRun {
    var jobs: [ClaimedJob] = []
    for assignment in contract.assignments
    where assignment.status == .pending || assignment.status == .running {
      let executionID = assignment.executionID ?? UUID()
      let claimed = try await store.claimAssignment(
        assignmentID: assignment.id, executionID: executionID)
      let durableAssignment =
        claimed.assignments.first(where: { $0.id == assignment.id }) ?? assignment
      jobs.append(ClaimedJob(assignment: durableAssignment, executionID: executionID))
    }

    await withTaskGroup(of: WorkerResult.self) { group in
      for job in jobs {
        group.addTask { [scheduler] in
          do {
            try await scheduler.acquire(job.assignment.id)
            do {
              let output = try await worker.execute(
                assignment: job.assignment,
                contract: contract,
                executionID: job.executionID)
              await scheduler.release(job.assignment.id)
              return .success(job.assignment, job.executionID, output)
            } catch {
              await scheduler.release(job.assignment.id)
              throw error
            }
          } catch {
            return .failure(job.assignment, job.executionID, error.localizedDescription)
          }
        }
      }

      for await result in group {
        switch result {
        case .success(let assignment, let executionID, let output):
          _ = try? await store.recordWorkerResult(
            assignmentID: assignment.id,
            result: output.result,
            succeeded: true,
            executionID: executionID,
            evidence: output.evidence,
            completedRevision: output.completedRevision)
          if output.estimatedCost > 0 {
            _ = try? await store.recordSpend(output.estimatedCost)
          }
        case .failure(let assignment, let executionID, let message):
          _ = try? await store.recordWorkerResult(
            assignmentID: assignment.id,
            result: message,
            succeeded: false,
            executionID: executionID)
        }
      }
    }
    return try await store.current() ?? contract
  }
}

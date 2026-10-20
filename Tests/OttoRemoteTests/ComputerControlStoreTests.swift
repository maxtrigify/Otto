import Foundation
import OttoModels
import OttoRemote
import Testing

@Suite("Lease-bound computer takeover")
struct ComputerControlStoreTests {
  @Test("Only one device controls a paused run and handback resumes it once")
  func exclusiveLeaseAndResume() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = try ComputerControlStore(stateDirectory: root)
    let runID = UUID()
    let firstDevice = UUID()
    let secondDevice = UUID()
    let now = Date(timeIntervalSince1970: 100)
    let request = try await store.request(
      runID: runID, profileID: UUID(), checkpointID: "checkpoint-17",
      reason: "Complete sign-in", now: now)
    let lease = try await store.acquire(
      requestID: request.id, deviceID: firstDevice, now: now)
    #expect(lease.owner == .user)
    #expect(lease.runID == runID)
    await #expect(throws: ComputerControlError.leaseUnavailable) {
      try await store.acquire(requestID: request.id, deviceID: secondDevice, now: now)
    }
    await #expect(throws: ComputerControlError.wrongDevice) {
      try await store.handBack(
        requestID: request.id, deviceID: secondDevice, outcome: .done, now: now)
    }
    let handback = try await store.handBack(
      requestID: request.id, deviceID: firstDevice, outcome: .done, now: now)
    let token = try #require(handback.resumeToken)
    #expect(handback.phase == .resuming)

    store = try ComputerControlStore(stateDirectory: root)
    let resumed = try await store.claimResume(requestID: request.id, token: token, now: now)
    #expect(resumed.phase == .completed)
    #expect(resumed.runID == runID)
    #expect(resumed.pausedCheckpointID == "checkpoint-17")
    await #expect(throws: ComputerControlError.resumeAlreadyClaimed) {
      try await store.claimResume(requestID: request.id, token: token, now: now)
    }
  }

  @Test("Expired leases hand control back without accepting stale input")
  func expiry() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try ComputerControlStore(stateDirectory: root)
    let now = Date(timeIntervalSince1970: 100)
    let request = try await store.request(
      runID: UUID(), profileID: nil, checkpointID: "checkpoint", reason: "Captcha", now: now)
    _ = try await store.acquire(
      requestID: request.id, deviceID: UUID(), lifetime: 30, now: now)
    let expired = try await store.expire(
      requestID: request.id, now: now.addingTimeInterval(31))
    #expect(expired.phase == .expired)
    #expect(expired.owner == .bot)
    #expect(expired.handbackOutcome == .expired)
    #expect(expired.resumeToken != nil)
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-takeover-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

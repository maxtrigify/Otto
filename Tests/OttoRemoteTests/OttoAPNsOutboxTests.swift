import Foundation
import OttoModels
import OttoRemote
import Testing

@Suite("Otto APNs durable outbox")
struct OttoAPNsOutboxTests {
  @Test("Per-device event keys dedupe and interrupted sends become uncertain")
  func durability() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-apns-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let event = RunEvent(
      threadID: UUID(), sequence: 1, kind: .runCompleted,
      content: RunEventContent(notification: .completion))
    let notification = try #require(OttoAPNsNotification(event: event, threadTitle: "Ada"))
    let deviceID = UUID()
    var outbox = try OttoAPNsOutbox(stateDirectory: root)
    try await outbox.enqueue(notification, deviceIDs: [deviceID, deviceID])
    #expect(await outbox.all().count == 1)
    let claimed = try #require(try await outbox.claimNext())
    #expect(claimed.attemptCount == 1)

    outbox = try OttoAPNsOutbox(stateDirectory: root)
    #expect(await outbox.all().first?.state == .uncertain)
    #expect(try await outbox.claimNext() == nil)
  }

  @Test("Known transient failures back off while permanent failures stop")
  func transitions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-apns-transitions-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let event = RunEvent(
      threadID: UUID(), sequence: 1, kind: .runFailed,
      content: RunEventContent(notification: .failure))
    let notification = try #require(OttoAPNsNotification(event: event, threadTitle: "Ada"))
    let outbox = try OttoAPNsOutbox(stateDirectory: root)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try await outbox.enqueue(notification, deviceIDs: [UUID()], now: now)
    let record = try #require(try await outbox.claimNext(now: now))
    try await outbox.markRetryable(id: record.id, error: "HTTP 503", now: now)
    #expect(try await outbox.claimNext(now: now) == nil)
    #expect(try await outbox.claimNext(now: now.addingTimeInterval(2))?.id == record.id)
    try await outbox.markFailed(id: record.id, error: "Unregistered", now: now)
    #expect(await outbox.all().first?.state == .failed)
  }
}

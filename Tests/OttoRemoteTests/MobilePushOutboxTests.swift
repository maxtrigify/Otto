import Foundation
import OttoModels
import OttoRemote
import Testing

@Suite("Durable mobile push outbox")
struct MobilePushOutboxTests {
  @Test("Transition keys dedupe and interrupted sends become uncertain without replay")
  func interruptedDelivery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-push-outbox-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let envelope = MobilePushEnvelope(
      transitionKey: "effect:7:needsUser", environmentID: UUID(), activityID: "effect:7",
      threadID: UUID(), state: .needsUser, preview: nil,
      deepLink: .effect(effectID: UUID()))
    var store = try MobilePushOutbox(stateDirectory: root)
    let first = try await store.enqueue(envelope, now: Date(timeIntervalSince1970: 1))
    let duplicate = try await store.enqueue(envelope, now: Date(timeIntervalSince1970: 2))
    #expect(first.id == duplicate.id)
    #expect(try await store.claimNext(now: Date(timeIntervalSince1970: 3))?.id == first.id)

    store = try MobilePushOutbox(stateDirectory: root)
    #expect(await store.all().first?.state == .uncertain)
    #expect(try await store.claimNext() == nil)
    _ = try await store.requeueUncertain(id: first.id)
    let retry = try #require(try await store.claimNext())
    #expect(retry.attemptCount == 2)
    _ = try await store.markDelivered(id: first.id)

    store = try MobilePushOutbox(stateDirectory: root)
    #expect(await store.all().first?.state == .delivered)
    #expect(try await store.claimNext() == nil)
  }
}

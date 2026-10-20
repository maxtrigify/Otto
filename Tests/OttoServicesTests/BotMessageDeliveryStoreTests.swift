import Foundation
import OttoModels
import OttoServices
import Testing

@MainActor
@Suite("Durable bot message delivery store")
struct BotMessageDeliveryStoreTests {
  @Test("Enqueue is idempotent, durable, and detects key collisions")
  func idempotentPersistence() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotMessageDeliveryStore(workspacePath: root.path)
    let delivery = fixture(key: "turn-1:message-1")

    let first = try store.enqueue(delivery)
    let repeated = try store.enqueue(delivery)
    #expect(first.id == repeated.id)
    #expect(store.deliveries.count == 1)

    var collision = delivery
    collision.id = UUID()
    collision.body = "Different request"
    #expect(throws: BotStoreError.deliveryKeyCollision) { try store.enqueue(collision) }

    let reloaded = BotMessageDeliveryStore(workspacePath: root.path)
    #expect(reloaded.delivery(idempotencyKey: delivery.idempotencyKey)?.id == first.id)
    #expect(reloaded.queued().map(\.id) == [first.id])
  }

  @Test("Terminal delivery writes matching sender and receiver receipts atomically")
  func atomicReceipts() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotMessageDeliveryStore(workspacePath: root.path)
    let queued = try store.enqueue(fixture(key: "turn-2:message-1"))

    _ = try store.beginDispatch(id: queued.id)
    let delivered = try store.markDelivered(id: queued.id)
    #expect(delivered.state == .delivered)
    #expect(Set(delivered.receipts.map(\.side)) == Set(BotMessageReceiptSide.allCases))
    #expect(delivered.receipts.count == 2)

    let reloaded = BotMessageDeliveryStore(workspacePath: root.path)
    #expect(reloaded.delivery(id: queued.id)?.state == .delivered)
    #expect(reloaded.delivery(id: queued.id)?.receipts.count == 2)
  }

  @Test("Interrupted dispatch becomes uncertain and is never queued for replay")
  func interruptedDispatchRecovery() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = BotMessageDeliveryStore(workspacePath: root.path)
    let queued = try store.enqueue(fixture(key: "turn-3:message-1"))
    _ = try store.beginDispatch(id: queued.id)

    store = BotMessageDeliveryStore(workspacePath: root.path)
    let recovered = try #require(store.delivery(id: queued.id))
    #expect(recovered.state == .uncertain)
    #expect(store.queued().isEmpty)
    #expect(recovered.failureReason?.contains("Verify the receiver") == true)
    let retry = try store.enqueue(fixtureMatching(recovered))
    #expect(retry.id == recovered.id)
    #expect(retry.state == .uncertain)
  }

  @Test("Hop caps and malformed keys are rejected before persistence")
  func validation() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotMessageDeliveryStore(workspacePath: root.path)
    var excessive = fixture(key: "too-deep")
    excessive.hopCount = BotMessageDelivery.maxHopCount + 1
    #expect(throws: BotStoreError.messageHopLimit) { try store.enqueue(excessive) }

    var keyless = fixture(key: " ")
    keyless.id = UUID()
    #expect(throws: BotStoreError.invalidDeliveryKey) { try store.enqueue(keyless) }
    #expect(store.deliveries.isEmpty)
  }

  private func fixture(key: String) -> BotMessageDelivery {
    BotMessageDelivery(
      idempotencyKey: key,
      humanTurnID: UUID(),
      senderProfileID: UUID(),
      receiverProfileID: UUID(),
      channelID: UUID(),
      body: "Please draft the brief.",
      trust: .peerUntrusted
    )
  }

  private func fixtureMatching(_ delivery: BotMessageDelivery) -> BotMessageDelivery {
    BotMessageDelivery(
      idempotencyKey: delivery.idempotencyKey,
      humanTurnID: delivery.humanTurnID,
      replyToDeliveryID: delivery.replyToDeliveryID,
      senderProfileID: delivery.senderProfileID,
      receiverProfileID: delivery.receiverProfileID,
      channelID: delivery.channelID,
      body: delivery.body,
      trust: delivery.trust,
      hopCount: delivery.hopCount
    )
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-delivery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

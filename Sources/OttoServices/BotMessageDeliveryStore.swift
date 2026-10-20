import Combine
import Foundation
import OttoModels

private struct PersistedBotMessageDeliveries: Codable {
  var schemaVersion: Int
  var deliveries: [BotMessageDelivery]
}

@MainActor
public final class BotMessageDeliveryStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var deliveries: [BotMessageDelivery] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-message-deliveries.json")
    load()
    recoverInterruptedDispatches()
  }

  public func delivery(id: UUID) -> BotMessageDelivery? {
    deliveries.first { $0.id == id }
  }

  public func delivery(idempotencyKey: String) -> BotMessageDelivery? {
    deliveries.first { $0.idempotencyKey == idempotencyKey }
  }

  public func queued(receiverProfileID: UUID? = nil) -> [BotMessageDelivery] {
    deliveries.filter {
      $0.state == .queued
        && (receiverProfileID == nil || $0.receiverProfileID == receiverProfileID)
    }
  }

  @discardableResult
  public func enqueue(_ candidate: BotMessageDelivery) throws -> BotMessageDelivery {
    let key = candidate.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.utf8.count <= 200 else { throw BotStoreError.invalidDeliveryKey }
    guard candidate.hopCount >= 0, candidate.hopCount <= BotMessageDelivery.maxHopCount else {
      throw BotStoreError.messageHopLimit
    }
    if let existing = delivery(idempotencyKey: key) {
      guard
        existing.senderProfileID == candidate.senderProfileID,
        existing.receiverProfileID == candidate.receiverProfileID,
        existing.channelID == candidate.channelID,
        existing.body == candidate.body,
        existing.humanTurnID == candidate.humanTurnID,
        existing.replyToDeliveryID == candidate.replyToDeliveryID,
        existing.hopCount == candidate.hopCount
      else { throw BotStoreError.deliveryKeyCollision }
      return existing
    }
    var record = candidate
    record.idempotencyKey = key
    record.state = .queued
    record.receipts = []
    try mutate { $0.append(record) }
    return record
  }

  @discardableResult
  public func markDelivered(id: UUID, at date: Date = .now) throws -> BotMessageDelivery {
    try update(id: id) { record in
      guard record.state == .dispatching else { return }
      record.state = .delivered
      record.deliveredAt = date
      record.updatedAt = date
      record.failureReason = nil
      record.receipts = [
        BotMessageReceipt(side: .sender, profileID: record.senderProfileID, createdAt: date),
        BotMessageReceipt(side: .receiver, profileID: record.receiverProfileID, createdAt: date),
      ]
    }
  }

  @discardableResult
  public func beginDispatch(id: UUID, at date: Date = .now) throws -> BotMessageDelivery {
    guard let record = delivery(id: id), record.state == .queued else {
      throw BotStoreError.invalidDeliveryTransition
    }
    return try update(id: id) { record in
      record.state = .dispatching
      record.updatedAt = date
    }
  }

  @discardableResult
  public func markUncertain(id: UUID, reason: String) throws -> BotMessageDelivery {
    try update(id: id) { record in
      guard record.state == .dispatching else { return }
      record.state = .uncertain
      record.failureReason = String(reason.prefix(500))
      record.updatedAt = .now
    }
  }

  @discardableResult
  public func markFailed(id: UUID, reason: String, at date: Date = .now) throws
    -> BotMessageDelivery
  {
    try update(id: id) { record in
      guard record.state == .queued || record.state == .dispatching else { return }
      record.state = .failed
      record.failureReason = String(reason.prefix(500))
      record.updatedAt = date
      record.receipts = [
        BotMessageReceipt(side: .sender, profileID: record.senderProfileID, createdAt: date),
        BotMessageReceipt(side: .receiver, profileID: record.receiverProfileID, createdAt: date),
      ]
    }
  }

  private func update(
    id: UUID,
    mutation: (inout BotMessageDelivery) -> Void
  ) throws -> BotMessageDelivery {
    guard let index = deliveries.firstIndex(where: { $0.id == id }) else {
      throw BotStoreError.profileNotFound
    }
    try mutate { mutation(&$0[index]) }
    return deliveries[index]
  }

  private func mutate(_ mutation: (inout [BotMessageDelivery]) -> Void) throws {
    let previous = deliveries
    mutation(&deliveries)
    do {
      try persist()
    } catch {
      deliveries = previous
      throw error
    }
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotMessageDeliveries.self, from: fileURL, fileManager: fileManager)
      {
        deliveries = persisted.deliveries
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot message deliveries: \(error.localizedDescription)"
    }
  }

  private func recoverInterruptedDispatches() {
    guard deliveries.contains(where: { $0.state == .dispatching }) else { return }
    let previous = deliveries
    for index in deliveries.indices where deliveries[index].state == .dispatching {
      deliveries[index].state = .uncertain
      deliveries[index].failureReason =
        "Otto stopped while dispatching. Verify the receiver before sending again."
      deliveries[index].updatedAt = .now
    }
    do {
      try persist()
    } catch {
      deliveries = previous
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotMessageDeliveries(
          schemaVersion: Self.currentSchemaVersion,
          deliveries: deliveries
        ),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot message deliveries: \(error.localizedDescription)"
      throw error
    }
  }
}

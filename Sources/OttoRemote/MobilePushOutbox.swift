import Foundation

public enum MobilePushDeliveryState: String, Codable, CaseIterable, Sendable {
  case pending
  case sending
  case delivered
  case uncertain
}

public struct MobilePushDeliveryRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var envelope: MobilePushEnvelope
  public var state: MobilePushDeliveryState
  public var attemptCount: Int
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), envelope: MobilePushEnvelope,
    state: MobilePushDeliveryState = .pending, attemptCount: Int = 0,
    createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.envelope = envelope
    self.state = state
    self.attemptCount = attemptCount
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

private struct PersistedMobilePushOutbox: Codable {
  var schemaVersion: Int
  var records: [MobilePushDeliveryRecord]
}

public enum MobilePushOutboxError: Error, Equatable, Sendable {
  case recordNotFound
  case invalidTransition
}

public actor MobilePushOutbox {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private var records: [MobilePushDeliveryRecord]

  public init(stateDirectory: URL) throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    fileURL = stateDirectory.appending(path: "mobile-push-outbox.json")
    if let data = try? Data(contentsOf: fileURL),
      let value = try? MobileChatCodec.decode(PersistedMobilePushOutbox.self, from: data)
    {
      records = value.records.map { record in
        guard record.state == .sending else { return record }
        var recovered = record
        recovered.state = .uncertain
        return recovered
      }
      if records != value.records {
        try MobileChatCodec.encode(
          PersistedMobilePushOutbox(
            schemaVersion: Self.currentSchemaVersion, records: records)
        ).write(to: fileURL, options: [.atomic])
      }
    } else {
      records = []
    }
  }

  public func all() -> [MobilePushDeliveryRecord] { records }

  @discardableResult
  public func enqueue(
    _ envelope: MobilePushEnvelope, now: Date = .now
  ) throws -> MobilePushDeliveryRecord {
    if let existing = records.first(where: {
      $0.envelope.transitionKey == envelope.transitionKey
    }) {
      return existing
    }
    let record = MobilePushDeliveryRecord(
      envelope: envelope, createdAt: now, updatedAt: now)
    records.append(record)
    try persist()
    return record
  }

  public func claimNext(now: Date = .now) throws -> MobilePushDeliveryRecord? {
    guard let index = records.firstIndex(where: { $0.state == .pending }) else { return nil }
    records[index].state = .sending
    records[index].attemptCount += 1
    records[index].updatedAt = now
    try persist()
    return records[index]
  }

  @discardableResult
  public func markDelivered(id: UUID, now: Date = .now) throws -> MobilePushDeliveryRecord {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw MobilePushOutboxError.recordNotFound
    }
    guard records[index].state == .sending else {
      throw MobilePushOutboxError.invalidTransition
    }
    records[index].state = .delivered
    records[index].updatedAt = now
    try persist()
    return records[index]
  }

  @discardableResult
  public func requeueUncertain(id: UUID, now: Date = .now) throws -> MobilePushDeliveryRecord {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw MobilePushOutboxError.recordNotFound
    }
    guard records[index].state == .uncertain else {
      throw MobilePushOutboxError.invalidTransition
    }
    records[index].state = .pending
    records[index].updatedAt = now
    try persist()
    return records[index]
  }

  private func persist() throws {
    try MobileChatCodec.encode(
      PersistedMobilePushOutbox(
        schemaVersion: Self.currentSchemaVersion, records: records)
    ).write(to: fileURL, options: [.atomic])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

import Foundation

public enum OttoAPNsDeliveryState: String, Codable, CaseIterable, Sendable {
  case pending
  case sending
  case delivered
  case uncertain
  case failed
}

public struct OttoAPNsDeliveryRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var deviceID: UUID
  public var notification: OttoAPNsNotification
  public var state: OttoAPNsDeliveryState
  public var attemptCount: Int
  public var nextAttemptAt: Date?
  public var lastError: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    deviceID: UUID,
    notification: OttoAPNsNotification,
    state: OttoAPNsDeliveryState = .pending,
    attemptCount: Int = 0,
    nextAttemptAt: Date? = nil,
    lastError: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.deviceID = deviceID
    self.notification = notification
    self.state = state
    self.attemptCount = attemptCount
    self.nextAttemptAt = nextAttemptAt
    self.lastError = lastError
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

private struct PersistedOttoAPNsOutbox: Codable {
  var schemaVersion: Int
  var records: [OttoAPNsDeliveryRecord]
}

public enum OttoAPNsOutboxError: Error, Equatable, Sendable {
  case recordNotFound
  case invalidTransition
}

public actor OttoAPNsOutbox {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private var records: [OttoAPNsDeliveryRecord]

  public init(stateDirectory: URL) throws {
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    fileURL = stateDirectory.appending(path: "apns-outbox.json")
    if let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder().decode(PersistedOttoAPNsOutbox.self, from: data)
    {
      records = persisted.records.map { record in
        guard record.state == .sending else { return record }
        var recovered = record
        recovered.state = .uncertain
        recovered.lastError = "Delivery outcome was unknown after host restart."
        return recovered
      }
      try Self.write(records, to: fileURL)
    } else {
      records = []
    }
  }

  public func all() -> [OttoAPNsDeliveryRecord] { records }

  public func enqueue(
    _ notification: OttoAPNsNotification,
    deviceIDs: [UUID],
    now: Date = .now
  ) throws {
    for deviceID in deviceIDs
    where !records.contains(where: {
      $0.deviceID == deviceID && $0.notification.eventID == notification.eventID
    }) {
      records.append(
        OttoAPNsDeliveryRecord(
          deviceID: deviceID, notification: notification, createdAt: now, updatedAt: now))
    }
    try persist()
  }

  public func claimNext(now: Date = .now) throws -> OttoAPNsDeliveryRecord? {
    guard
      let index = records.firstIndex(where: {
        $0.state == .pending && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now)
      })
    else { return nil }
    records[index].state = .sending
    records[index].attemptCount += 1
    records[index].updatedAt = now
    try persist()
    return records[index]
  }

  public func markDelivered(id: UUID, now: Date = .now) throws {
    try updateSending(id: id) {
      $0.state = .delivered
      $0.nextAttemptAt = nil
      $0.lastError = nil
      $0.updatedAt = now
    }
  }

  public func markRetryable(id: UUID, error: String, now: Date = .now) throws {
    try updateSending(id: id) {
      $0.state = .pending
      $0.nextAttemptAt = now.addingTimeInterval(min(pow(2, Double($0.attemptCount)), 3_600))
      $0.lastError = String(error.prefix(500))
      $0.updatedAt = now
    }
  }

  public func markUncertain(id: UUID, error: String, now: Date = .now) throws {
    try updateSending(id: id) {
      $0.state = .uncertain
      $0.lastError = String(error.prefix(500))
      $0.updatedAt = now
    }
  }

  public func markFailed(id: UUID, error: String, now: Date = .now) throws {
    try updateSending(id: id) {
      $0.state = .failed
      $0.lastError = String(error.prefix(500))
      $0.updatedAt = now
    }
  }

  private func updateSending(
    id: UUID,
    mutation: (inout OttoAPNsDeliveryRecord) -> Void
  ) throws {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw OttoAPNsOutboxError.recordNotFound
    }
    guard records[index].state == .sending else {
      throw OttoAPNsOutboxError.invalidTransition
    }
    mutation(&records[index])
    try persist()
  }

  private func persist() throws {
    try Self.write(records, to: fileURL)
  }

  private nonisolated static func write(
    _ records: [OttoAPNsDeliveryRecord],
    to fileURL: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(
      PersistedOttoAPNsOutbox(
        schemaVersion: currentSchemaVersion, records: records)
    )
    .write(to: fileURL, options: [.atomic])
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

public actor OttoAPNsDeliveryWorker {
  private let outbox: OttoAPNsOutbox
  private let pairing: RemotePairingStore
  private let client: OttoAPNsClient

  public init(outbox: OttoAPNsOutbox, pairing: RemotePairingStore, client: OttoAPNsClient) {
    self.outbox = outbox
    self.pairing = pairing
    self.client = client
  }

  public func enqueue(_ notification: OttoAPNsNotification, now: Date = .now) async throws {
    let deviceIDs = await pairing.listDevices().filter {
      $0.revokedAt == nil && $0.pushToken != nil
    }.map(\.id)
    try await outbox.enqueue(notification, deviceIDs: deviceIDs, now: now)
  }

  @discardableResult
  public func drainOne(now: Date = .now) async throws -> Bool {
    guard let record = try await outbox.claimNext(now: now) else { return false }
    guard
      let device = await pairing.listDevices().first(where: {
        $0.id == record.deviceID && $0.revokedAt == nil && $0.pushToken != nil
      })
    else {
      try await outbox.markFailed(
        id: record.id, error: "Paired device is revoked or unregistered.", now: now)
      return true
    }
    do {
      _ = try await client.send(record.notification, to: device, now: now)
      try await outbox.markDelivered(id: record.id, now: now)
    } catch let error as OttoAPNsError {
      switch error {
      case .httpStatus(let status, _) where status == 429 || status >= 500:
        try await outbox.markRetryable(id: record.id, error: error.localizedDescription, now: now)
      case .httpStatus, .deviceNotRegistered, .invalidConfiguration, .invalidResponse:
        try await outbox.markFailed(id: record.id, error: error.localizedDescription, now: now)
      }
    } catch {
      try await outbox.markUncertain(id: record.id, error: error.localizedDescription, now: now)
    }
    return true
  }

  public func drainAvailable(now: Date = .now, limit: Int = 100) async {
    for _ in 0..<max(1, min(limit, 1_000)) {
      guard (try? await drainOne(now: now)) == true else { return }
    }
  }
}

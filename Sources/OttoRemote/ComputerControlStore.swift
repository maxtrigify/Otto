import Foundation
import OttoModels

private struct PersistedComputerControl: Codable {
  var schemaVersion: Int
  var states: [ComputerControlState]
}

public enum ComputerControlError: Error, LocalizedError, Equatable, Sendable {
  case runAlreadyPaused
  case requestNotFound
  case leaseUnavailable
  case leaseExpired
  case wrongDevice
  case invalidTransition
  case resumeAlreadyClaimed

  public var errorDescription: String? {
    switch self {
    case .runAlreadyPaused: "That run already has an active takeover request."
    case .requestNotFound: "That takeover request no longer exists."
    case .leaseUnavailable: "Another device currently owns the takeover lease."
    case .leaseExpired: "The takeover lease expired."
    case .wrongDevice: "Only the device holding this lease can control or hand back the run."
    case .invalidTransition: "That takeover transition is not valid."
    case .resumeAlreadyClaimed: "This paused run has already resumed."
    }
  }
}

public actor ComputerControlStore {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private var states: [ComputerControlState]

  public init(stateDirectory: URL) throws {
    self.fileURL = stateDirectory.appending(path: "computer-control.json")
    try FileManager.default.createDirectory(
      at: stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder.remote.decode(PersistedComputerControl.self, from: data)
    {
      self.states = persisted.states
    } else {
      self.states = []
      let data = try JSONEncoder.remote.encode(
        PersistedComputerControl(schemaVersion: Self.currentSchemaVersion, states: []))
      try data.write(to: fileURL, options: [.atomic])
    }
  }

  public func state(id: UUID) -> ComputerControlState? { states.first { $0.id == id } }

  @discardableResult
  public func request(
    runID: UUID, profileID: UUID?, checkpointID: String, reason: String,
    now: Date = .now
  ) throws -> ComputerControlState {
    guard
      !states.contains(where: {
        $0.runID == runID && [.requested, .userControlling, .resuming].contains($0.phase)
      })
    else { throw ComputerControlError.runAlreadyPaused }
    let state = ComputerControlState(
      runID: runID, profileID: profileID, pausedCheckpointID: checkpointID,
      reason: String(reason.prefix(1_000)), createdAt: now, updatedAt: now)
    states.append(state)
    try persist()
    return state
  }

  @discardableResult
  public func acquire(
    requestID: UUID, deviceID: UUID, lifetime: TimeInterval = 120, now: Date = .now
  ) throws -> ComputerControlState {
    guard let index = states.firstIndex(where: { $0.id == requestID }) else {
      throw ComputerControlError.requestNotFound
    }
    if states[index].phase == .userControlling,
      let expiry = states[index].leaseExpiresAt, expiry > now
    {
      if states[index].leaseDeviceID == deviceID { return states[index] }
      throw ComputerControlError.leaseUnavailable
    }
    guard
      states[index].phase == .requested
        || (states[index].phase == .userControlling
          && states[index].leaseExpiresAt ?? .distantPast <= now)
    else { throw ComputerControlError.invalidTransition }
    states[index].phase = .userControlling
    states[index].owner = .user
    states[index].leaseID = UUID()
    states[index].leaseDeviceID = deviceID
    states[index].leaseExpiresAt = now.addingTimeInterval(min(max(lifetime, 30), 300))
    states[index].updatedAt = now
    try persist()
    return states[index]
  }

  @discardableResult
  public func handBack(
    requestID: UUID, deviceID: UUID, outcome: ComputerHandbackOutcome, now: Date = .now
  ) throws -> ComputerControlState {
    guard let index = states.firstIndex(where: { $0.id == requestID }) else {
      throw ComputerControlError.requestNotFound
    }
    guard states[index].phase == .userControlling else {
      throw ComputerControlError.invalidTransition
    }
    guard states[index].leaseDeviceID == deviceID else { throw ComputerControlError.wrongDevice }
    guard states[index].leaseExpiresAt ?? .distantPast > now else {
      throw ComputerControlError.leaseExpired
    }
    states[index].handbackOutcome = outcome
    states[index].owner = .bot
    states[index].leaseID = nil
    states[index].leaseDeviceID = nil
    states[index].leaseExpiresAt = nil
    states[index].resumeToken = UUID()
    states[index].phase = outcome == .done ? .resuming : outcome == .skipped ? .skipped : .expired
    states[index].updatedAt = now
    try persist()
    return states[index]
  }

  @discardableResult
  public func expire(requestID: UUID, now: Date = .now) throws -> ComputerControlState {
    guard let index = states.firstIndex(where: { $0.id == requestID }) else {
      throw ComputerControlError.requestNotFound
    }
    guard states[index].phase == .userControlling,
      states[index].leaseExpiresAt ?? .distantFuture <= now
    else { throw ComputerControlError.invalidTransition }
    states[index].phase = .expired
    states[index].owner = .bot
    states[index].handbackOutcome = .expired
    states[index].resumeToken = UUID()
    states[index].leaseID = nil
    states[index].leaseDeviceID = nil
    states[index].leaseExpiresAt = nil
    states[index].updatedAt = now
    try persist()
    return states[index]
  }

  public func claimResume(
    requestID: UUID, token: UUID, now: Date = .now
  ) throws -> ComputerControlState {
    guard let index = states.firstIndex(where: { $0.id == requestID }) else {
      throw ComputerControlError.requestNotFound
    }
    guard states[index].resumeClaimedAt == nil else {
      throw ComputerControlError.resumeAlreadyClaimed
    }
    guard states[index].resumeToken == token,
      [.resuming, .skipped, .expired].contains(states[index].phase)
    else { throw ComputerControlError.invalidTransition }
    states[index].resumeClaimedAt = now
    states[index].phase = .completed
    states[index].updatedAt = now
    try persist()
    return states[index]
  }

  private func persist() throws {
    let data = try JSONEncoder.remote.encode(
      PersistedComputerControl(schemaVersion: Self.currentSchemaVersion, states: states))
    try data.write(to: fileURL, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

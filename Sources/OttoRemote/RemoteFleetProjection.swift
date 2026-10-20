import Foundation

public enum RemoteConnectionStatus: String, Codable, Sendable, Equatable {
  case remote = "REMOTE"
  case offline = "OFFLINE"
  case reconnecting = "RECONNECTING"
}

public enum RemoteSessionState: String, Codable, Sendable, Equatable {
  case working = "WORKING"
  case done = "DONE"
  case failed = "FAILED"
  case stopped = "STOPPED"
}

public struct RemoteSessionSnapshot: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var state: RemoteSessionState
  public var exitCode: Int32?
  public var outputByteCount: Int

  public init(
    id: UUID,
    state: RemoteSessionState,
    exitCode: Int32? = nil,
    outputByteCount: Int = 0
  ) {
    self.id = id
    self.state = state
    self.exitCode = exitCode
    self.outputByteCount = outputByteCount
  }
}

public struct RemoteFleetSnapshot: Codable, Sendable, Equatable {
  public var status: RemoteConnectionStatus
  public var daemonID: UUID?
  public var lastSequence: Int64
  public var lastHeartbeat: Date?
  public var processorCount: Int?
  public var physicalMemoryBytes: UInt64?
  public var sessions: [UUID: RemoteSessionSnapshot]

  public init(
    status: RemoteConnectionStatus = .offline,
    daemonID: UUID? = nil,
    lastSequence: Int64 = 0,
    lastHeartbeat: Date? = nil,
    processorCount: Int? = nil,
    physicalMemoryBytes: UInt64? = nil,
    sessions: [UUID: RemoteSessionSnapshot] = [:]
  ) {
    self.status = status
    self.daemonID = daemonID
    self.lastSequence = lastSequence
    self.lastHeartbeat = lastHeartbeat
    self.processorCount = processorCount
    self.physicalMemoryBytes = physicalMemoryBytes
    self.sessions = sessions
  }
}

public actor RemoteFleetCoordinator {
  private var value = RemoteFleetSnapshot()

  public init() {}

  public func snapshot() -> RemoteFleetSnapshot { value }

  @discardableResult
  public func beginReconnect() -> RemoteFleetSnapshot {
    value.status = .reconnecting
    return value
  }

  @discardableResult
  public func markOffline() -> RemoteFleetSnapshot {
    value.status = .offline
    return value
  }

  @discardableResult
  public func refresh(using client: RemoteSocketClient) async throws -> RemoteFleetSnapshot {
    if value.status != .remote { value.status = .reconnecting }
    let cursor = value.lastSequence
    let hello: RemoteHello = try await retryReadOnly {
      try await client.request(
        .hello,
        parameters: RemoteCursorInput(afterSequence: cursor, limit: 500)
      ).decode(RemoteHello.self)
    }
    let heartbeat: RemoteHeartbeat = try await retryReadOnly {
      try await client.request(.heartbeat).decode(RemoteHeartbeat.self)
    }
    if let existingDaemon = value.daemonID, existingDaemon != hello.daemonID {
      value.sessions = [:]
      value.lastSequence = 0
      let replay: RemoteEventPage = try await retryReadOnly {
        try await client.request(
          .events,
          parameters: RemoteCursorInput(afterSequence: 0, limit: 500)
        ).decode(RemoteEventPage.self)
      }
      apply(replay.events)
      value.lastSequence = replay.latestSequence
    } else {
      apply(hello.eventPage.events)
      value.lastSequence = hello.eventPage.latestSequence
    }
    for sessionID in hello.activeSessionIDs where value.sessions[sessionID] == nil {
      value.sessions[sessionID] = RemoteSessionSnapshot(id: sessionID, state: .working)
    }
    value.daemonID = hello.daemonID
    value.lastHeartbeat = heartbeat.timestamp
    value.processorCount = heartbeat.processorCount
    value.physicalMemoryBytes = heartbeat.physicalMemoryBytes
    value.status = .remote
    return value
  }

  private func retryReadOnly<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    var lastError: (any Error)?
    for attempt in 0..<3 {
      do { return try await operation() } catch {
        lastError = error
        if attempt < 2 { try await Task.sleep(for: .milliseconds(25)) }
      }
    }
    throw lastError ?? RemoteError.invalidInput("remote read failed")
  }

  private func apply(_ events: [RemoteEvent]) {
    for event in events {
      guard let sessionID = event.sessionID else { continue }
      switch event.kind {
      case .sessionStarted:
        value.sessions[sessionID] = RemoteSessionSnapshot(id: sessionID, state: .working)
      case .outputAppended:
        guard let encoded = event.payload?["data"]?.stringValue,
          let byteCount = Data(base64Encoded: encoded)?.count
        else { continue }
        var session =
          value.sessions[sessionID]
          ?? RemoteSessionSnapshot(id: sessionID, state: .working)
        session.outputByteCount += byteCount
        value.sessions[sessionID] = session
      case .sessionStopped:
        var session =
          value.sessions[sessionID]
          ?? RemoteSessionSnapshot(id: sessionID, state: .stopped)
        session.state = .stopped
        value.sessions[sessionID] = session
      case .sessionExited:
        let exitCode = event.payload?["exitCode"]?.numberValue.map(Int32.init)
        var session =
          value.sessions[sessionID]
          ?? RemoteSessionSnapshot(id: sessionID, state: .failed)
        session.exitCode = exitCode
        session.state = exitCode == 0 ? .done : .failed
        value.sessions[sessionID] = session
      }
    }
  }
}

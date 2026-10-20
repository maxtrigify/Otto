import Foundation

public enum MediaAction: String, Codable, Equatable, Sendable {
  case open
  case play
  case pause
  case stop
  case seek
  case setVolume
}

public struct MediaRuntimeState: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var source: String
  public var isPlaying: Bool
  public var position: Double
  public var duration: Double?
  public var volume: Double
  public var revision: Int
  public var requestedAction: MediaAction

  public init(
    nodeID: UUID,
    source: String,
    isPlaying: Bool = false,
    position: Double = 0,
    duration: Double? = nil,
    volume: Double = 0.8,
    revision: Int = 0,
    requestedAction: MediaAction = .open
  ) {
    self.nodeID = nodeID
    self.source = source
    self.isPlaying = isPlaying
    self.position = position
    self.duration = duration
    self.volume = min(max(volume, 0), 1)
    self.revision = revision
    self.requestedAction = requestedAction
  }
}

public actor MediaRuntime {
  private var states: [UUID: MediaRuntimeState] = [:]
  private var subscribers: [UUID: [UUID: AsyncStream<MediaRuntimeState>.Continuation]] = [:]

  public init() {}

  @discardableResult
  public func register(nodeID: UUID, source: String) -> MediaRuntimeState {
    if let state = states[nodeID] { return state }
    let state = MediaRuntimeState(nodeID: nodeID, source: source)
    states[nodeID] = state
    return state
  }

  public func state(nodeID: UUID) -> MediaRuntimeState? { states[nodeID] }

  public func updates(nodeID: UUID) -> AsyncStream<MediaRuntimeState> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      subscribers[nodeID, default: [:]][subscriberID] = continuation
      if let state = states[nodeID] { continuation.yield(state) }
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(subscriberID, nodeID: nodeID) }
      }
    }
  }

  public func play(nodeID: UUID) throws -> MediaRuntimeState {
    try mutate(nodeID: nodeID, action: .play) { $0.isPlaying = true }
  }

  public func pause(nodeID: UUID) throws -> MediaRuntimeState {
    try mutate(nodeID: nodeID, action: .pause) { $0.isPlaying = false }
  }

  public func stop(nodeID: UUID) throws -> MediaRuntimeState {
    try mutate(nodeID: nodeID, action: .stop) {
      $0.isPlaying = false
      $0.position = 0
    }
  }

  public func seek(nodeID: UUID, position: Double) throws -> MediaRuntimeState {
    try mutate(nodeID: nodeID, action: .seek) {
      $0.position = max(0, position)
    }
  }

  public func setVolume(nodeID: UUID, volume: Double) throws -> MediaRuntimeState {
    try mutate(nodeID: nodeID, action: .setVolume) {
      $0.volume = min(max(volume, 0), 1)
    }
  }

  public func report(nodeID: UUID, position: Double, duration: Double?) throws {
    _ = try mutate(nodeID: nodeID, action: nil) {
      $0.position = max(0, position)
      $0.duration = duration
    }
  }

  private func mutate(
    nodeID: UUID,
    action: MediaAction?,
    change: (inout MediaRuntimeState) -> Void
  ) throws -> MediaRuntimeState {
    guard var state = states[nodeID] else { throw MediaRuntimeError.unknownNode(nodeID) }
    change(&state)
    if let action {
      state.requestedAction = action
      state.revision += 1
    }
    states[nodeID] = state
    for continuation in subscribers[nodeID]?.values ?? [:].values { continuation.yield(state) }
    return state
  }

  private func removeSubscriber(_ id: UUID, nodeID: UUID) {
    subscribers[nodeID]?[id] = nil
  }
}

public enum MediaRuntimeError: Error, LocalizedError, Equatable, Sendable {
  case unknownNode(UUID)
  public var errorDescription: String? {
    switch self {
    case .unknownNode(let id): "Media node \(id.uuidString) has no active playback session"
    }
  }
}

import Foundation

public enum OttoEventType: String, Codable, CaseIterable, Sendable {
  case agentRunStarted = "agent.run_started"
  case agentOutputAppended = "agent.output_appended"
  case agentStatusChanged = "agent.status_changed"
  case agentRunCompleted = "agent.run_completed"
  case agentRunFailed = "agent.run_failed"
  case agentExited = "agent.exited"
  case botPresenceChanged = "bot.presence_changed"
  case botMessageDelivered = "bot.message_delivered"
  case botNeedsUser = "bot.needs_user"
  case botChannelUpdated = "bot.channel_updated"
  case routineFired = "routine.fired"
  case routineCompleted = "routine.completed"
}

public struct OttoEvent: Codable, Identifiable, Sendable, Equatable {
  public var id: UUID
  public var sequence: Int
  public var streamID: UUID?
  public var type: OttoEventType
  public var timestamp: Date
  public var nodeID: UUID?
  public var state: AgentLifecycleState?
  public var confidence: Double?
  public var byteCount: Int?
  public var exitCode: Int32?
  public var profileID: UUID?
  public var senderProfileID: UUID?
  public var receiverProfileID: UUID?
  public var channelID: UUID?
  public var routineID: UUID?
  public var runID: UUID?
  public var outcome: String?

  public init(
    id: UUID = UUID(),
    sequence: Int = 0,
    streamID: UUID? = nil,
    type: OttoEventType,
    timestamp: Date = .now,
    nodeID: UUID? = nil,
    state: AgentLifecycleState? = nil,
    confidence: Double? = nil,
    byteCount: Int? = nil,
    exitCode: Int32? = nil,
    profileID: UUID? = nil,
    senderProfileID: UUID? = nil,
    receiverProfileID: UUID? = nil,
    channelID: UUID? = nil,
    routineID: UUID? = nil,
    runID: UUID? = nil,
    outcome: String? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.streamID = streamID
    self.type = type
    self.timestamp = timestamp
    self.nodeID = nodeID
    self.state = state
    self.confidence = confidence
    self.byteCount = byteCount
    self.exitCode = exitCode
    self.profileID = profileID
    self.senderProfileID = senderProfileID
    self.receiverProfileID = receiverProfileID
    self.channelID = channelID
    self.routineID = routineID
    self.runID = runID
    self.outcome = outcome
  }
}

public final class OttoEventBus: @unchecked Sendable {
  public let streamID = UUID()
  private let lock = NSLock()
  private let historyLimit: Int
  private var nextSequence = 1
  private var history: [OttoEvent] = []
  private var subscribers: [UUID: AsyncStream<OttoEvent>.Continuation] = [:]

  public init(historyLimit: Int = 1_024) {
    self.historyLimit = max(1, historyLimit)
  }

  @discardableResult
  public func publish(_ event: OttoEvent) -> OttoEvent {
    lock.withLock {
      var sequenced = event
      sequenced.streamID = streamID
      sequenced.sequence = nextSequence
      nextSequence += 1
      history.append(sequenced)
      if history.count > historyLimit {
        history.removeFirst(history.count - historyLimit)
      }
      for continuation in subscribers.values {
        continuation.yield(sequenced)
      }
      return sequenced
    }
  }

  public func stream(afterSequence: Int = 0) -> AsyncStream<OttoEvent> {
    let subscriberID = UUID()
    return AsyncStream { continuation in
      lock.withLock {
        for event in history where event.sequence > afterSequence { continuation.yield(event) }
        subscribers[subscriberID] = continuation
      }
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: subscriberID) }
      }
    }
  }

  public var latestSequence: Int {
    lock.withLock { nextSequence - 1 }
  }
}

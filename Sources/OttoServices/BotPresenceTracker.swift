import Foundation
import OttoModels
import OttoRuntime

/// Derives per-profile presence from the runtime event stream and republishes
/// `bot.presence_changed` for the UI and for `event.wait`.
public final class BotPresenceTracker: @unchecked Sendable {
  public static let recentWindow: TimeInterval = 90

  private let lock = NSLock()
  private var lastOutput: [UUID: Date] = [:]
  private var running: Set<UUID> = []
  private var lastPresence: [UUID: BotPresence] = [:]
  private let eventBus: OttoEventBus
  private let profileForNode: @MainActor (UUID) -> UUID?
  private var listenTask: Task<Void, Never>?

  public init(
    eventBus: OttoEventBus,
    profileForNode: @escaping @MainActor (UUID) -> UUID?
  ) {
    self.eventBus = eventBus
    self.profileForNode = profileForNode
  }

  public func start() {
    listenTask?.cancel()
    listenTask = Task { [weak self] in
      guard let self else { return }
      for await event in self.eventBus.stream() {
        if Task.isCancelled { return }
        // CanvasStore and profile lookup are MainActor-isolated. Ingesting off-thread
        // traps with dispatch_assert_queue on launch.
        await MainActor.run { self.ingest(event) }
      }
    }
  }

  public func stop() {
    listenTask?.cancel()
    listenTask = nil
  }

  public func presence(for profileID: UUID) -> BotPresence {
    lock.lock()
    defer { lock.unlock() }
    return derivedLocked(profileID: profileID, now: .now)
  }

  @MainActor
  public func ingest(_ event: OttoEvent) {
    guard let nodeID = event.nodeID, let profileID = profileForNode(nodeID) else { return }
    let now = event.timestamp
    lock.lock()
    switch event.type {
    case .agentRunStarted:
      running.insert(profileID)
    case .agentRunCompleted, .agentRunFailed, .agentExited:
      running.remove(profileID)
    case .agentOutputAppended:
      lastOutput[profileID] = now
    default:
      break
    }
    let next = derivedLocked(profileID: profileID, now: now)
    let previous = lastPresence[profileID]
    lastPresence[profileID] = next
    lock.unlock()
    if previous != next {
      eventBus.publish(
        OttoEvent(type: .botPresenceChanged, timestamp: now, nodeID: nodeID, profileID: profileID)
      )
    }
  }

  private func derivedLocked(profileID: UUID, now: Date) -> BotPresence {
    if running.contains(profileID) { return .active }
    if let last = lastOutput[profileID], now.timeIntervalSince(last) <= Self.recentWindow {
      return .recent
    }
    return .idle
  }
}

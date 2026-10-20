import Foundation

public enum AgentResourcePressure: String, Codable, CaseIterable, Sendable {
  case nominal
  case elevated
  case critical
}

public struct AgentResourceSchedulerConfiguration: Sendable, Equatable {
  public var nominalLimit: Int
  public var elevatedLimit: Int
  public var criticalLimit: Int

  public init(
    nominalLimit: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)),
    elevatedLimit: Int? = nil,
    criticalLimit: Int = 1
  ) {
    let nominal = max(1, nominalLimit)
    self.nominalLimit = nominal
    self.elevatedLimit = min(nominal, max(1, elevatedLimit ?? max(1, nominal / 2)))
    self.criticalLimit = min(self.elevatedLimit, max(1, criticalLimit))
  }
}

public struct AgentResourceSchedulerSnapshot: Sendable, Equatable {
  public var pressure: AgentResourcePressure
  public var concurrencyLimit: Int
  public var running: [UUID]
  public var queued: [UUID]

  public init(
    pressure: AgentResourcePressure,
    concurrencyLimit: Int,
    running: [UUID],
    queued: [UUID]
  ) {
    self.pressure = pressure
    self.concurrencyLimit = concurrencyLimit
    self.running = running
    self.queued = queued
  }
}

/// Admission control for expensive one-shot workers. A permit controls process lifetime, not UI
/// lifetime: compact and hidden workers keep their slot until their supervised process exits.
public actor AgentResourceScheduler {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let configuration: AgentResourceSchedulerConfiguration
  private var pressure: AgentResourcePressure = .nominal
  private var running: Set<UUID> = []
  private var queue: [Waiter] = []

  public init(configuration: AgentResourceSchedulerConfiguration = .init()) {
    self.configuration = configuration
  }

  public func acquire(_ id: UUID) async throws {
    try Task.checkCancellation()
    if running.contains(id) { return }
    if running.count < concurrencyLimit {
      running.insert(id)
      return
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          queue.append(Waiter(id: id, continuation: continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelQueued(id) }
    }
  }

  public func release(_ id: UUID) {
    guard running.remove(id) != nil else { return }
    admitQueuedWorkers()
  }

  public func updatePressure(_ pressure: AgentResourcePressure) {
    self.pressure = pressure
    admitQueuedWorkers()
  }

  public func snapshot() -> AgentResourceSchedulerSnapshot {
    AgentResourceSchedulerSnapshot(
      pressure: pressure,
      concurrencyLimit: concurrencyLimit,
      running: running.sorted { $0.uuidString < $1.uuidString },
      queued: queue.map(\.id)
    )
  }

  private var concurrencyLimit: Int {
    switch pressure {
    case .nominal: configuration.nominalLimit
    case .elevated: configuration.elevatedLimit
    case .critical: configuration.criticalLimit
    }
  }

  private func cancelQueued(_ id: UUID) {
    guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
    let waiter = queue.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func admitQueuedWorkers() {
    while running.count < concurrencyLimit, !queue.isEmpty {
      let waiter = queue.removeFirst()
      guard !running.contains(waiter.id) else {
        waiter.continuation.resume()
        continue
      }
      running.insert(waiter.id)
      waiter.continuation.resume()
    }
  }
}

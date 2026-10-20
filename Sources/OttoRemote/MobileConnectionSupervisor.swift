import Foundation

public enum MobileConnectionState: String, Codable, Sendable {
  case offline
  case connecting
  case online
}

public enum MobileConnectionError: Error, Equatable, Sendable {
  case offlineApproval
  case nonAdvancingCursor
}

public protocol MobileChatTransport: Sendable {
  func events(after sequence: Int64) async throws -> MobileEventPage
  /// The host must deduplicate this operation by `clientMessageID`.
  func send(_ message: MobileQueuedMessage) async throws
  func respond(to approval: MobileApprovalResponse) async throws
}

public actor MobileConnectionSupervisor {
  public private(set) var state: MobileConnectionState = .offline
  private let cache: MobileClientCache
  private let transport: any MobileChatTransport

  public init(cache: MobileClientCache, transport: any MobileChatTransport) {
    self.cache = cache
    self.transport = transport
  }

  /// Foreground/wake synchronization: replay every durable delta, then flush safe queued sends.
  public func synchronize(maxPages: Int = 100) async throws {
    state = .connecting
    do {
      for _ in 0..<max(1, maxPages) {
        let cursor = await cache.lastSequence
        let page = try await transport.events(after: cursor)
        try await cache.apply(page)
        let advanced = await cache.lastSequence
        if advanced >= page.latestSequence { break }
        guard advanced > cursor else { throw MobileConnectionError.nonAdvancingCursor }
      }
      state = .online
      try await flushQueuedMessages()
    } catch {
      state = .offline
      throw error
    }
  }

  public func disconnect() { state = .offline }

  public func send(
    threadID: UUID, clientMessageID: String, body: String, now: Date = .now
  ) async throws {
    try await cache.queueMessage(
      threadID: threadID, clientMessageID: clientMessageID, body: body, now: now)
    if state == .online {
      do { try await flushQueuedMessages() } catch {
        state = .offline
        throw error
      }
    }
  }

  public func respond(to approval: MobileApprovalResponse) async throws {
    guard state == .online else { throw MobileConnectionError.offlineApproval }
    do { try await transport.respond(to: approval) } catch {
      state = .offline
      throw error
    }
  }

  public nonisolated static func reconnectDelay(
    attempt: Int, base: TimeInterval = 1, maximum: TimeInterval = 60,
    jitterUnit: Double
  ) -> TimeInterval {
    let exponent = min(max(attempt, 0), 16)
    let uncapped = base * pow(2, Double(exponent))
    let capped = min(maximum, uncapped)
    return capped * (0.75 + min(max(jitterUnit, 0), 1) * 0.5)
  }

  private func flushQueuedMessages() async throws {
    for message in await cache.queuedMessages().sorted(by: { $0.createdAt < $1.createdAt }) {
      try await transport.send(message)
      try await cache.acknowledgeMessage(clientMessageID: message.clientMessageID)
    }
  }
}

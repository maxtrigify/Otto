import Foundation
import OttoRemote
import Testing

@Suite("Mobile connection supervisor")
struct MobileConnectionSupervisorTests {
  @Test("Cached startup catches up ordered pages and flushes stable queued messages")
  func reconnectAndFlush() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MobileClientCache(cacheDirectory: root)
    let transport = SupervisorTransport(
      pages: [
        MobileEventPage(
          events: [MobileHostEvent(sequence: 1, type: .homeChanged)], latestSequence: 2),
        MobileEventPage(
          events: [MobileHostEvent(sequence: 2, type: .activityChanged)], latestSequence: 2),
      ])
    let supervisor = MobileConnectionSupervisor(cache: cache, transport: transport)
    try await supervisor.send(
      threadID: UUID(), clientMessageID: "client-stable-1", body: "Send when online")
    #expect(await cache.queuedMessages().count == 1)
    try await supervisor.synchronize()
    #expect(await supervisor.state == .online)
    #expect(await cache.lastSequence == 2)
    #expect(await cache.queuedMessages().isEmpty)
    #expect(await transport.sentIDs == ["client-stable-1"])
    #expect(await transport.requestedCursors == [0, 1])
  }

  @Test("Failed sends remain queued and approvals are never queued offline")
  func failClosed() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try MobileClientCache(cacheDirectory: root)
    let transport = SupervisorTransport(pages: [MobileEventPage(events: [], latestSequence: 0)])
    await transport.setSendFailure(true)
    let supervisor = MobileConnectionSupervisor(cache: cache, transport: transport)
    try await supervisor.synchronize()
    await #expect(throws: SupervisorTransport.Failure.send) {
      try await supervisor.send(
        threadID: UUID(), clientMessageID: "client-stable-2", body: "Keep me")
    }
    #expect(await supervisor.state == .offline)
    #expect(await cache.queuedMessages().map(\.clientMessageID) == ["client-stable-2"])
    await #expect(throws: MobileConnectionError.offlineApproval) {
      try await supervisor.respond(
        to: MobileApprovalResponse(requestID: UUID(), decision: "approve", nonce: "fresh"))
    }
    #expect(await transport.approvalCount == 0)
  }

  @Test("Backoff is exponential, bounded, and jittered")
  func backoff() {
    #expect(MobileConnectionSupervisor.reconnectDelay(attempt: 0, jitterUnit: 0.5) == 1)
    #expect(MobileConnectionSupervisor.reconnectDelay(attempt: 3, jitterUnit: 0.5) == 8)
    #expect(MobileConnectionSupervisor.reconnectDelay(attempt: 20, jitterUnit: 0.5) == 60)
    #expect(MobileConnectionSupervisor.reconnectDelay(attempt: 2, jitterUnit: 0) == 3)
    #expect(MobileConnectionSupervisor.reconnectDelay(attempt: 2, jitterUnit: 1) == 5)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-supervisor-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}

private actor SupervisorTransport: MobileChatTransport {
  enum Failure: Error { case send }
  private var pages: [MobileEventPage]
  private var failSend = false
  private(set) var requestedCursors: [Int64] = []
  private(set) var sentIDs: [String] = []
  private(set) var approvalCount = 0

  init(pages: [MobileEventPage]) { self.pages = pages }
  func setSendFailure(_ value: Bool) { failSend = value }
  func events(after sequence: Int64) async throws -> MobileEventPage {
    requestedCursors.append(sequence)
    return pages.isEmpty
      ? MobileEventPage(events: [], latestSequence: sequence) : pages.removeFirst()
  }
  func send(_ message: MobileQueuedMessage) async throws {
    if failSend { throw Failure.send }
    sentIDs.append(message.clientMessageID)
  }
  func respond(to approval: MobileApprovalResponse) async throws { approvalCount += 1 }
}

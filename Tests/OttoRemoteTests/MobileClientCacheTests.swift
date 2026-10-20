import Foundation
import OttoRemote
import Testing

@Suite("Mobile chat contracts and cache")
struct MobileClientCacheTests {
  @Test("Cached startup and ordered delta replay are durable and idempotent")
  func orderedReplay() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let environmentID = UUID()
    let threadID = UUID()
    let capabilities = MobileEnvironmentCapabilities(
      environmentID: environmentID, environmentName: "Studio Mac", hostOnline: true,
      hostVersion: "1.0", capabilities: ["chat", "activity"])
    let thread = MobileThreadSummary(
      id: threadID, kind: .bot, title: "Researcher", updatedAt: Date(timeIntervalSince1970: 10))
    let home = MobileHomeSnapshot(
      capabilities: capabilities, bots: [], teams: [], threads: [thread], activity: [],
      latestSequence: 0)

    var cache = try MobileClientCache(cacheDirectory: root)
    try await cache.replace(home: home)
    let message = MobileMessage(
      author: .bot(profileID: UUID(), name: "Researcher"), body: "Done",
      createdAt: Date(timeIntervalSince1970: 20))
    let snapshot = MobileThreadSnapshot(thread: thread, messages: [message], latestSequence: 1)
    let payload = try MobileChatCodec.encode(snapshot)
    let event = MobileHostEvent(
      sequence: 1, type: .threadMessage, threadID: threadID, payload: payload)
    try await cache.apply(MobileEventPage(events: [event, event], latestSequence: 1))
    #expect(await cache.cachedThread(id: threadID)?.messages == [message])
    #expect(await cache.lastSequence == 1)

    cache = try MobileClientCache(cacheDirectory: root)
    #expect(await cache.cachedHome()?.capabilities.environmentID == environmentID)
    #expect(await cache.cachedThread(id: threadID)?.messages == [message])
    try await cache.apply(
      MobileEventPage(
        events: [MobileHostEvent(sequence: 3, type: .threadState, threadID: threadID)],
        latestSequence: 3))
    #expect(await cache.lastSequence == 1)
  }

  @Test("Messages queue idempotently while approvals fail closed offline")
  func offlinePolicy() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let threadID = UUID()
    var cache = try MobileClientCache(cacheDirectory: root)
    try await cache.queueMessage(threadID: threadID, clientMessageID: "client-1", body: "Hello")
    await #expect(throws: MobileOfflinePolicyError.duplicateClientMessage) {
      try await cache.queueMessage(threadID: threadID, clientMessageID: "client-1", body: "Again")
    }
    cache = try MobileClientCache(cacheDirectory: root)
    #expect(await cache.queuedMessages().map(\.clientMessageID) == ["client-1"])
    await #expect(throws: MobileOfflinePolicyError.approvalRequiresOnlineHost) {
      try await cache.queueApproval(
        MobileApprovalResponse(requestID: UUID(), decision: "approve", nonce: "fresh"))
    }
    try await cache.acknowledgeMessage(clientMessageID: "client-1")
    #expect(await cache.queuedMessages().isEmpty)
  }

  @Test("Protocol preserves speaker, correlation, and causation attribution")
  func attributionRoundTrip() throws {
    let profileID = UUID()
    let event = MobileHostEvent(
      sequence: 7, timestamp: Date(timeIntervalSince1970: 30), type: .threadMessage,
      threadID: UUID(), profileID: profileID,
      correlationID: UUID(), causationID: UUID(),
      payload: try MobileChatCodec.encode(
        MobileMessage(author: .bot(profileID: profileID, name: "Writer"), body: "Draft")))
    let decoded = try MobileChatCodec.decode(
      MobileHostEvent.self, from: MobileChatCodec.encode(event))
    #expect(decoded == event)
    #expect(MobileChatMethod.allCases.contains(.computerHandBack))
    #expect(!MobileChatMethod.allCases.map(\.rawValue).contains(where: { $0.contains("canvas") }))
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

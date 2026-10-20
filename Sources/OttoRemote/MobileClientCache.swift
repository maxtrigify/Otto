import Foundation

private struct PersistedMobileClientCache: Codable {
  var schemaVersion: Int
  var home: MobileHomeSnapshot?
  var threads: [MobileThreadSnapshot]
  var pendingMessages: [MobileQueuedMessage]
  var appliedEventIDs: [UUID]
  var lastSequence: Int64
}

public actor MobileClientCache {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private var home: MobileHomeSnapshot?
  private var threads: [UUID: MobileThreadSnapshot]
  private var pendingMessages: [MobileQueuedMessage]
  private var appliedEventIDs: Set<UUID>
  public private(set) var lastSequence: Int64

  public init(cacheDirectory: URL) throws {
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    self.fileURL = cacheDirectory.appending(path: "mobile-chat-cache.json")
    if let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder.remote.decode(PersistedMobileClientCache.self, from: data)
    {
      self.home = persisted.home
      self.threads = Dictionary(uniqueKeysWithValues: persisted.threads.map { ($0.thread.id, $0) })
      self.pendingMessages = persisted.pendingMessages
      self.appliedEventIDs = Set(persisted.appliedEventIDs)
      self.lastSequence = persisted.lastSequence
    } else {
      self.home = nil
      self.threads = [:]
      self.pendingMessages = []
      self.appliedEventIDs = []
      self.lastSequence = 0
    }
  }

  public func cachedHome() -> MobileHomeSnapshot? { home }
  public func cachedThread(id: UUID) -> MobileThreadSnapshot? { threads[id] }
  public func queuedMessages() -> [MobileQueuedMessage] { pendingMessages }

  public func replace(home: MobileHomeSnapshot) throws {
    self.home = home
    lastSequence = max(lastSequence, home.latestSequence)
    try persist()
  }

  public func replace(thread: MobileThreadSnapshot) throws {
    threads[thread.thread.id] = thread
    lastSequence = max(lastSequence, thread.latestSequence)
    try persist()
  }

  public func apply(_ page: MobileEventPage) throws {
    for event in page.events.sorted(by: { $0.sequence < $1.sequence }) {
      guard event.sequence > lastSequence else { continue }
      guard event.sequence == lastSequence + 1 else { break }
      guard appliedEventIDs.insert(event.id).inserted else { break }
      applyPayload(event)
      lastSequence = event.sequence
    }
    if appliedEventIDs.count > 4_000 {
      appliedEventIDs = Set(appliedEventIDs.suffix(2_000))
    }
    try persist()
  }

  public func queueMessage(
    threadID: UUID, clientMessageID: String, body: String, now: Date = .now
  ) throws {
    guard !pendingMessages.contains(where: { $0.clientMessageID == clientMessageID }) else {
      throw MobileOfflinePolicyError.duplicateClientMessage
    }
    pendingMessages.append(
      MobileQueuedMessage(
        threadID: threadID, clientMessageID: clientMessageID,
        body: String(body.prefix(64_000)), createdAt: now))
    try persist()
  }

  public func acknowledgeMessage(clientMessageID: String) throws {
    pendingMessages.removeAll { $0.clientMessageID == clientMessageID }
    try persist()
  }

  public func queueApproval(_ response: MobileApprovalResponse) throws {
    throw MobileOfflinePolicyError.approvalRequiresOnlineHost
  }

  private func applyPayload(_ event: MobileHostEvent) {
    guard let payload = event.payload else { return }
    switch event.type {
    case .homeChanged, .activityChanged:
      if let snapshot = try? JSONDecoder.remote.decode(MobileHomeSnapshot.self, from: payload) {
        home = snapshot
      }
    case .threadMessage, .threadState:
      if let snapshot = try? JSONDecoder.remote.decode(MobileThreadSnapshot.self, from: payload) {
        threads[snapshot.thread.id] = snapshot
      }
    case .approvalRequested, .computerControlChanged:
      break
    }
  }

  private func persist() throws {
    let data = try JSONEncoder.remote.encode(
      PersistedMobileClientCache(
        schemaVersion: Self.currentSchemaVersion, home: home,
        threads: threads.values.sorted { $0.thread.updatedAt > $1.thread.updatedAt },
        pendingMessages: pendingMessages, appliedEventIDs: Array(appliedEventIDs),
        lastSequence: lastSequence))
    try data.write(to: fileURL, options: [.atomic])
  }
}

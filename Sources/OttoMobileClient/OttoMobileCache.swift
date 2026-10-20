import Foundation
import OttoModels
import OttoRPCContracts

public struct OttoMobileCachedHome: Codable, Equatable, Sendable {
  public var environment: ExecutionEnvironment?
  public var threads: [OttoModels.Thread]
  public var bots: [MobileBotSummary]
  public var teams: [MobileTeamSummary]
  public var savedAt: Date

  public init(
    environment: ExecutionEnvironment?,
    threads: [OttoModels.Thread],
    bots: [MobileBotSummary],
    teams: [MobileTeamSummary],
    savedAt: Date = .now
  ) {
    self.environment = environment
    self.threads = threads
    self.bots = bots
    self.teams = teams
    self.savedAt = savedAt
  }
}

private struct OttoMobilePersistedCache: Codable, Sendable {
  var schemaVersion: Int
  var home: OttoMobileCachedHome?
  var threads: [ThreadSnapshot]
  var pendingMessages: [MessageSendInput]?
}

public protocol OttoMobileCaching: Sendable {
  func home() async -> OttoMobileCachedHome?
  func thread(id: UUID) async -> ThreadSnapshot?
  func replace(home: OttoMobileCachedHome) async throws
  func replace(thread: ThreadSnapshot) async throws
  func pendingMessage(threadID: UUID) async -> MessageSendInput?
  func savePendingMessage(_ message: MessageSendInput) async throws
  func removePendingMessage(threadID: UUID) async throws
}

public actor OttoMobileDiskCache: OttoMobileCaching {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private var cachedHome: OttoMobileCachedHome?
  private var cachedThreads: [UUID: ThreadSnapshot]
  private var pendingMessages: [UUID: MessageSendInput] = [:]

  public init(directory: URL? = nil) {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    if directory == nil {
      // Before the rename the cache lived in Application Support/MuseMobile.
      OttoDirectoryMigration.migrate(
        legacy: support.appending(path: "MuseMobile", directoryHint: .isDirectory),
        current: support.appending(path: "OttoMobile", directoryHint: .isDirectory))
    }
    let root = directory ?? support.appending(path: "OttoMobile", directoryHint: .isDirectory)
    let destination = root.appending(path: "mobile-client-cache.json")
    fileURL = destination
    // Oldest builds kept the cache under Caches/MuseMobile.
    let legacyURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
      .appending(path: "MuseMobile/mobile-client-cache.json")
    let readURL =
      directory == nil && !FileManager.default.fileExists(atPath: destination.path)
      ? legacyURL : destination
    if let data = try? Data(contentsOf: readURL),
      let persisted = try? OttoRPCCodec.decoder.decode(OttoMobilePersistedCache.self, from: data),
      persisted.schemaVersion == Self.currentSchemaVersion
    {
      pendingMessages = Dictionary(
        uniqueKeysWithValues: (persisted.pendingMessages ?? []).map { ($0.threadID, $0) })
      cachedHome = persisted.home
      cachedThreads = Dictionary(uniqueKeysWithValues: persisted.threads.map { ($0.thread.id, $0) })
    } else {
      cachedHome = nil
      cachedThreads = [:]
    }
  }

  public func home() -> OttoMobileCachedHome? { cachedHome }
  public func thread(id: UUID) -> ThreadSnapshot? { cachedThreads[id] }

  public func replace(home: OttoMobileCachedHome) throws {
    cachedHome = home
    try persist()
  }

  public func replace(thread: ThreadSnapshot) throws {
    cachedThreads[thread.thread.id] = thread
    try persist()
  }

  public func pendingMessage(threadID: UUID) -> MessageSendInput? { pendingMessages[threadID] }

  public func savePendingMessage(_ message: MessageSendInput) throws {
    let previous = pendingMessages
    pendingMessages[message.threadID] = message
    do { try persist() } catch {
      pendingMessages = previous
      throw error
    }
  }

  public func removePendingMessage(threadID: UUID) throws {
    let previous = pendingMessages
    pendingMessages[threadID] = nil
    do { try persist() } catch {
      pendingMessages = previous
      throw error
    }
  }

  private func persist() throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let payload = OttoMobilePersistedCache(
      schemaVersion: Self.currentSchemaVersion,
      home: cachedHome,
      threads: cachedThreads.values.sorted { $0.thread.updatedAt > $1.thread.updatedAt },
      pendingMessages: Array(pendingMessages.values)
    )
    try OttoRPCCodec.encoder.encode(payload).write(to: fileURL, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path)
    #endif
  }
}

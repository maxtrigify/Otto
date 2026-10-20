import Darwin
import Foundation
import OttoModels

public struct DictationDraft: Codable, Equatable, Sendable {
  public var id: UUID
  public var transcript: String
  public var targetNodeID: UUID?
  public var updatedAt: Date
  public var sourceBundleID: String

  public init(
    id: UUID = UUID(),
    transcript: String,
    targetNodeID: UUID?,
    updatedAt: Date = .now,
    sourceBundleID: String
  ) {
    self.id = id
    self.transcript = transcript
    self.targetNodeID = targetNodeID
    self.updatedAt = updatedAt
    self.sourceBundleID = sourceBundleID
  }
}

/// A single atomic rolling draft shared by Otto Dev and production. The transcript is replaced on
/// every recognizer update, matching Apple's evolving-transcript contract without duplicating text.
public actor DictationDraftStore {
  private let fileURL: URL
  private var cached: DictationDraft?
  private var didLoad = false

  public init(directory: URL? = nil) {
    let directory = directory ?? Self.defaultDirectory
    fileURL = directory.appending(path: "dictation-draft.json")
  }

  @discardableResult
  public func save(
    transcript: String,
    targetNodeID: UUID?,
    sourceBundleID: String = Bundle.main.bundleIdentifier ?? "io.openotto.unknown"
  ) throws -> DictationDraft? {
    guard PromptSubmission.verbatimText(from: transcript) != nil else { return nil }
    let existing = try load()
    let draft = DictationDraft(
      id: existing?.id ?? UUID(),
      transcript: transcript,
      targetNodeID: targetNodeID,
      updatedAt: .now,
      sourceBundleID: sourceBundleID
    )
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(draft).write(to: fileURL, options: .atomic)
    cached = draft
    didLoad = true
    return draft
  }

  public func load() throws -> DictationDraft? {
    if didLoad { return cached }
    didLoad = true
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    cached = try decoder.decode(DictationDraft.self, from: Data(contentsOf: fileURL))
    return cached
  }

  public func clear() throws {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      try FileManager.default.removeItem(at: fileURL)
    }
    cached = nil
    didLoad = true
  }

  private static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appending(path: "Otto/Voice", directoryHint: .isDirectory)
      ?? FileManager.default.temporaryDirectory.appending(
        path: "Otto/Voice", directoryHint: .isDirectory)
  }
}

public final class VoiceCaptureLease: @unchecked Sendable {
  private let path: String
  private let lock = NSLock()
  private var descriptor: Int32 = -1

  public init(path: String? = nil) {
    self.path = path ?? "/tmp/io.openotto.voice-capture-\(getuid()).lock"
  }

  deinit { release() }

  public func acquire(owner: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if descriptor >= 0 { return true }
    let candidate = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard candidate >= 0 else { return false }
    guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
      close(candidate)
      return false
    }
    descriptor = candidate
    let identity = "\(owner) · pid \(getpid())\n"
    ftruncate(candidate, 0)
    _ = identity.withCString { pointer in
      Darwin.write(candidate, pointer, strlen(pointer))
    }
    return true
  }

  public func release() {
    lock.lock()
    defer { lock.unlock() }
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }

  public var isHeld: Bool {
    lock.withLock { descriptor >= 0 }
  }
}

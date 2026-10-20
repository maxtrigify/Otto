import Foundation
import OttoTools

#if canImport(Darwin)
  import Darwin
#else
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#endif

public actor RemoteEventJournal {
  public let url: URL
  private let maximumBytes: Int64
  private var history: [RemoteEvent]
  private var nextSequence: Int64

  public init(url: URL, maximumBytes: Int64) throws {
    self.url = url
    self.maximumBytes = maximumBytes
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    if !FileManager.default.fileExists(atPath: url.path) {
      guard
        FileManager.default.createFile(
          atPath: url.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else { throw RemoteError.journal("Could not create the journal.") }
    }
    chmod(url.path, 0o600)
    let data = try Data(contentsOf: url)
    guard Int64(data.count) <= maximumBytes else {
      throw RemoteError.resourceLimit("event journal exceeds the configured byte limit")
    }
    var events: [RemoteEvent] = []
    let decoder = JSONDecoder.remote
    for line in data.split(separator: 0x0a) where !line.isEmpty {
      do {
        events.append(try decoder.decode(RemoteEvent.self, from: Data(line)))
      } catch {
        throw RemoteError.journal("The journal contains an invalid event.")
      }
    }
    for (index, event) in events.enumerated() where event.sequence != Int64(index + 1) {
      throw RemoteError.journal("Event sequences are not contiguous.")
    }
    self.history = events
    self.nextSequence = Int64(events.count + 1)
  }

  @discardableResult
  public func append(
    kind: RemoteEventKind,
    sessionID: UUID? = nil,
    payload: JSONValue? = nil
  ) throws -> RemoteEvent {
    let timestamp = Date(
      timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 * 1_000) / 1_000)
    let event = RemoteEvent(
      sequence: nextSequence,
      timestamp: timestamp,
      kind: kind,
      sessionID: sessionID,
      payload: payload
    )
    var data = try JSONEncoder.remote.encode(event)
    data.append(0x0a)
    let currentSize =
      try FileManager.default.attributesOfItem(atPath: url.path)[.size]
      .flatMap { ($0 as? NSNumber)?.int64Value } ?? 0
    guard currentSize + Int64(data.count) <= maximumBytes else {
      throw RemoteError.resourceLimit("event journal exceeds the configured byte limit")
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
    history.append(event)
    nextSequence += 1
    return event
  }

  public func page(after sequence: Int64, limit: Int) -> RemoteEventPage {
    let events = Array(history.lazy.filter { $0.sequence > sequence }.prefix(limit))
    return RemoteEventPage(events: events, latestSequence: nextSequence - 1)
  }
}

extension JSONEncoder {
  static var remote: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  static var remote: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}

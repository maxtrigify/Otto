import Foundation
import OttoModels

/// Append-only inter-bot audit. Tool-registry calls still land in SQLite `audit_events`;
/// this log carries sender/receiver profile IDs the generic sink does not.
public final class BotAuditLog: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [BotInteractionAudit] = []
  private let fileURL: URL?
  private let fileManager: FileManager

  public init(workspacePath: String? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    if let workspacePath {
      self.fileURL = URL(fileURLWithPath: workspacePath)
        .appending(path: ".otto/bot-audit.jsonl")
    } else {
      self.fileURL = nil
    }
  }

  @discardableResult
  public func record(_ event: BotInteractionAudit) -> BotInteractionAudit {
    lock.lock()
    records.append(event)
    lock.unlock()
    if let fileURL {
      if let data = try? JSONEncoder.botAudit.encode(event) {
        var line = data
        line.append(0x0A)
        if !fileManager.fileExists(atPath: fileURL.path) {
          try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? line.write(to: fileURL, options: .atomic)
        } else if let handle = try? FileHandle(forWritingTo: fileURL) {
          defer { try? handle.close() }
          _ = try? handle.seekToEnd()
          try? handle.write(contentsOf: line)
        }
      }
    }
    return event
  }

  public func all() -> [BotInteractionAudit] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  public func interactions(sender: UUID? = nil, receiver: UUID? = nil) -> [BotInteractionAudit] {
    all().filter { event in
      (sender == nil || event.senderProfileID == sender)
        && (receiver == nil || event.receiverProfileID == receiver)
    }
  }
}

extension JSONEncoder {
  fileprivate static let botAudit: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()
}

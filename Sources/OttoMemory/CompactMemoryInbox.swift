import Foundation

/// A compact-memory candidate retained for review when the store budget is full.
public struct CompactMemoryProposal: Codable, Equatable, Sendable, Identifiable {
  public enum Target: String, Codable, Sendable {
    case personal
    case operating
  }

  public var id: String
  public var target: Target
  public var text: String
  public var source: String
  public var proposedBy: String
  public var proposedAt: Date

  public init(
    id: String,
    target: Target,
    text: String,
    source: String,
    proposedBy: String,
    proposedAt: Date = .now
  ) {
    self.id = id
    self.target = target
    self.text = text
    self.source = source
    self.proposedBy = proposedBy
    self.proposedAt = proposedAt
  }
}

/// The review inbox for compact-memory changes, persisted as one JSON file beside the workspace.
public actor CompactMemoryInbox {
  public let filePath: String

  public init(filePath: String) {
    self.filePath = filePath
  }

  public func proposals() -> [CompactMemoryProposal] {
    guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
    return (try? JSONDecoder.inbox.decode([CompactMemoryProposal].self, from: data)) ?? []
  }

  @discardableResult
  public func propose(_ proposal: CompactMemoryProposal) throws -> [CompactMemoryProposal] {
    if let marker = MemorySecretScanner.firstSecretMarker(
      in: proposal.text + "\n" + proposal.source)
    {
      throw CompactMemoryError.secretDetected(marker)
    }
    var current = proposals()
    current.removeAll { $0.id == proposal.id }
    current.append(proposal)
    try persist(current)
    return current
  }

  /// Removes a proposal (after the user accepted it into a store, or rejected it outright).
  @discardableResult
  public func remove(id: String) throws -> [CompactMemoryProposal] {
    var current = proposals()
    current.removeAll { $0.id == id }
    try persist(current)
    return current
  }

  private func persist(_ proposals: [CompactMemoryProposal]) throws {
    let directory = (filePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try JSONEncoder.inbox.encode(proposals)
      .write(to: URL(fileURLWithPath: filePath), options: .atomic)
  }
}

extension JSONEncoder {
  fileprivate static var inbox: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var inbox: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

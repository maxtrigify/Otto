import Foundation

/// One always-loadable compact memory entry: a short stable fact with provenance. These are the
/// only memories that enter an agent's context automatically, so every entry carries its source
/// and confirmation state, and the whole store lives under a hard visible budget.
public struct CompactMemoryEntry: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var text: String
  public var source: String
  public var confidence: MemoryConfidence
  public var lastConfirmedAt: Date

  public init(
    id: String,
    text: String,
    source: String,
    confidence: MemoryConfidence = .confirmed,
    lastConfirmedAt: Date = .now
  ) {
    self.id = id
    self.text = text
    self.source = source
    self.confidence = confidence
    self.lastConfirmedAt = lastConfirmedAt
  }
}

public struct MemoryBudget: Codable, Equatable, Sendable {
  public var maximumEntries: Int
  /// Character ceiling as a stable, model-agnostic proxy for tokens.
  public var maximumCharacters: Int

  public init(maximumEntries: Int, maximumCharacters: Int) {
    self.maximumEntries = max(1, maximumEntries)
    self.maximumCharacters = max(64, maximumCharacters)
  }

  public static let personal = MemoryBudget(maximumEntries: 40, maximumCharacters: 4_000)
  public static let operating = MemoryBudget(maximumEntries: 60, maximumCharacters: 6_000)
}

public enum CompactMemoryError: Error, LocalizedError, Equatable {
  case budgetExceeded(entries: Int, characters: Int, budget: MemoryBudget)
  case entryNotFound(String)
  case secretDetected(String)

  public var errorDescription: String? {
    switch self {
    case .budgetExceeded(let entries, let characters, let budget):
      "Compact memory budget reached (\(entries)/\(budget.maximumEntries) entries, "
        + "\(characters)/\(budget.maximumCharacters) characters). Consolidate or archive an "
        + "existing entry instead of silently dropping one."
    case .entryNotFound(let id):
      "No compact memory entry named \(id)"
    case .secretDetected(let marker):
      "Compact memory must never contain credentials; found \(marker)."
    }
  }
}

/// The USER.md / MEMORY.md equivalent: a single human-editable Markdown file of bulleted facts
/// with inline provenance comments. Overflow throws visibly — consolidation is a deliberate act,
/// never an automatic deletion.
public actor CompactMemoryStore {
  public let filePath: String
  public let budget: MemoryBudget
  private let title: String

  public init(filePath: String, title: String, budget: MemoryBudget) {
    self.filePath = filePath
    self.title = title
    self.budget = budget
  }

  public func entries() -> [CompactMemoryEntry] {
    guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
    return Self.parse(String(decoding: data, as: UTF8.self))
  }

  public struct Usage: Sendable, Equatable {
    public let entryCount: Int
    public let characterCount: Int
    public let budget: MemoryBudget
  }

  public func usage() -> Usage {
    let current = entries()
    return Usage(
      entryCount: current.count,
      characterCount: current.reduce(0) { $0 + $1.text.count },
      budget: budget
    )
  }

  @discardableResult
  public func add(_ entry: CompactMemoryEntry) throws -> [CompactMemoryEntry] {
    if let marker = MemorySecretScanner.firstSecretMarker(in: entry.text + "\n" + entry.source) {
      throw CompactMemoryError.secretDetected(marker)
    }
    var current = entries()
    current.removeAll { $0.id == entry.id }
    current.append(entry)
    let characters = current.reduce(0) { $0 + $1.text.count }
    guard current.count <= budget.maximumEntries, characters <= budget.maximumCharacters else {
      throw CompactMemoryError.budgetExceeded(
        entries: current.count, characters: characters, budget: budget)
    }
    try persist(current)
    return current
  }

  @discardableResult
  public func remove(id: String) throws -> [CompactMemoryEntry] {
    var current = entries()
    guard current.contains(where: { $0.id == id }) else {
      throw CompactMemoryError.entryNotFound(id)
    }
    current.removeAll { $0.id == id }
    try persist(current)
    return current
  }

  @discardableResult
  public func confirm(id: String) throws -> CompactMemoryEntry {
    var current = entries()
    guard let index = current.firstIndex(where: { $0.id == id }) else {
      throw CompactMemoryError.entryNotFound(id)
    }
    current[index].confidence = .confirmed
    current[index].lastConfirmedAt = .now
    try persist(current)
    return current[index]
  }

  // MARK: - Canonical Markdown form

  private static let dateFormat = Date.ISO8601FormatStyle()

  static func serialize(title: String, entries: [CompactMemoryEntry]) -> String {
    var lines = ["# \(title)", ""]
    for entry in entries {
      let metadata =
        "id:\(entry.id) confidence:\(entry.confidence.rawValue) "
        + "source:\(entry.source.replacingOccurrences(of: " ", with: "_")) "
        + "confirmed:\(entry.lastConfirmedAt.formatted(dateFormat))"
      lines.append("- \(entry.text.replacingOccurrences(of: "\n", with: " ")) <!-- \(metadata) -->")
    }
    lines.append("")
    return lines.joined(separator: "\n")
  }

  static func parse(_ source: String) -> [CompactMemoryEntry] {
    source.components(separatedBy: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("- "),
        let commentStart = trimmed.range(of: "<!--"),
        let commentEnd = trimmed.range(of: "-->")
      else { return nil }
      let text = String(
        trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<commentStart.lowerBound]
      )
      .trimmingCharacters(in: .whitespaces)
      let metadata = trimmed[commentStart.upperBound..<commentEnd.lowerBound]
        .split(whereSeparator: { $0.isWhitespace })
        .reduce(into: [String: String]()) { result, pair in
          let parts = pair.split(separator: ":", maxSplits: 1)
          guard parts.count == 2 else { return }
          result[String(parts[0])] = String(parts[1])
        }
      guard let id = metadata["id"], !text.isEmpty else { return nil }
      return CompactMemoryEntry(
        id: id,
        text: text,
        source: metadata["source"]?.replacingOccurrences(of: "_", with: " ") ?? "unknown",
        confidence: metadata["confidence"].flatMap(MemoryConfidence.init(rawValue:)) ?? .proposed,
        lastConfirmedAt: metadata["confirmed"].flatMap { try? Date($0, strategy: dateFormat) }
          ?? .distantPast
      )
    }
  }

  private func persist(_ entries: [CompactMemoryEntry]) throws {
    let directory = (filePath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try Data(Self.serialize(title: title, entries: entries).utf8)
      .write(to: URL(fileURLWithPath: filePath), options: .atomic)
  }
}

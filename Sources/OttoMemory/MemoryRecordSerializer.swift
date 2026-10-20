import Foundation

/// Canonical Markdown-with-frontmatter form of a MemoryRecord. Deterministic output (fixed key
/// order, ISO-8601 dates, block lists) so revisions diff cleanly and hashes are stable. The
/// parser accepts only the strict subset this serializer emits, plus inline `[a, b]` arrays —
/// anything else is malformed and gets quarantined rather than guessed at.
public enum MemoryRecordSerializer {
  private static let fence = "---"

  private static let dateFormat = Date.ISO8601FormatStyle()

  public static func serialize(_ record: MemoryRecord) -> String {
    var lines: [String] = [fence]
    lines.append("id: \(record.id)")
    lines.append("type: \(record.type.rawValue)")
    lines.append("scope: \(record.scope.rawValue)")
    lines.append("project: \(escapeScalar(record.project))")
    lines.append("title: \(escapeScalar(record.title))")
    lines.append("author: \(escapeScalar(record.author))")
    lines.append("created_at: \(record.createdAt.formatted(dateFormat))")
    lines.append("updated_at: \(record.updatedAt.formatted(dateFormat))")
    lines.append("revision: \(record.revision)")
    lines.append("confidence: \(record.confidence.rawValue)")
    lines.append("status: \(record.status.rawValue)")
    lines.append("fact_kind: \(record.factKind.rawValue)")
    if let expiresAt = record.expiresAt {
      lines.append("expires_at: \(expiresAt.formatted(dateFormat))")
    }
    lines.append("trust_score: \(trustFormat(record.trustScore))")
    lines.append("helpful_count: \(record.helpfulCount)")
    lines.append("unhelpful_count: \(record.unhelpfulCount)")
    lines.append(contentsOf: list(named: "source_ids", record.sourceIDs))
    lines.append(contentsOf: list(named: "supersedes", record.supersedes))
    lines.append(contentsOf: list(named: "tags", record.tags))
    lines.append(contentsOf: list(named: "entity_ids", record.entityIDs))
    if let profileID = record.profileID {
      lines.append("profile_id: \(profileID.uuidString)")
    }
    lines.append(fence)
    lines.append("")
    lines.append(record.body)
    return lines.joined(separator: "\n")
  }

  public static func parse(_ source: String) throws -> MemoryRecord {
    var lines = source.components(separatedBy: "\n")[...]
    guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "missing opening frontmatter fence")
    }
    lines = lines.dropFirst()

    var fields: [String: String] = [:]
    var listFields: [String: [String]] = [:]
    var pendingListKey: String?
    var closed = false

    while let line = lines.first {
      lines = lines.dropFirst()
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == fence {
        closed = true
        break
      }
      if trimmed.isEmpty { continue }
      if trimmed.hasPrefix("- "), let key = pendingListKey {
        listFields[key, default: []].append(String(trimmed.dropFirst(2)))
        continue
      }
      guard let separator = trimmed.range(of: ": ") ?? trimmed.range(of: ":") else {
        throw MemoryStoreError.malformedRecord(path: "", reason: "unparseable line \(trimmed)")
      }
      let key = String(trimmed[..<separator.lowerBound])
      let value = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
      if value.isEmpty {
        pendingListKey = key
        listFields[key] = []
      } else if value.hasPrefix("["), value.hasSuffix("]") {
        pendingListKey = nil
        let inner = value.dropFirst().dropLast()
        listFields[key] =
          inner.isEmpty
          ? []
          : inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      } else {
        pendingListKey = nil
        fields[key] = unescapeScalar(value)
      }
    }
    guard closed else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "missing closing frontmatter fence")
    }

    func required(_ key: String) throws -> String {
      guard let value = fields[key], !value.isEmpty else {
        throw MemoryStoreError.malformedRecord(path: "", reason: "missing \(key)")
      }
      return value
    }
    func date(_ key: String) throws -> Date {
      guard let value = try? Date(required(key), strategy: dateFormat) else {
        throw MemoryStoreError.malformedRecord(path: "", reason: "invalid date for \(key)")
      }
      return value
    }

    let id = try required("id")
    guard MemoryRecord.isValidID(id) else { throw MemoryStoreError.invalidRecordID(id) }
    guard let type = MemoryRecordType(rawValue: try required("type")) else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "unknown type")
    }
    guard let scope = MemoryScope(rawValue: try required("scope")) else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "unknown scope")
    }
    guard let confidence = MemoryConfidence(rawValue: try required("confidence")) else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "unknown confidence")
    }
    guard let status = MemoryStatus(rawValue: try required("status")) else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "unknown status")
    }
    guard let revision = Int(try required("revision")), revision >= 0 else {
      throw MemoryStoreError.malformedRecord(path: "", reason: "invalid revision")
    }

    // Trust fields postdate the first records written to disk. A brain predating them is not
    // malformed — it simply has no feedback yet, which is exactly the neutral starting score.
    let trustScore = fields["trust_score"].flatMap(Double.init) ?? MemoryTrust.initial
    let helpfulCount = fields["helpful_count"].flatMap(Int.init) ?? 0
    let unhelpfulCount = fields["unhelpful_count"].flatMap(Int.init) ?? 0
    let factKind = fields["fact_kind"].flatMap(MemoryFactKind.init(rawValue:)) ?? .fact
    let expiresAt = fields["expires_at"].flatMap { try? Date($0, strategy: dateFormat) }

    var body = lines.joined(separator: "\n")
    if body.hasPrefix("\n") { body.removeFirst() }

    return MemoryRecord(
      id: id,
      type: type,
      scope: scope,
      project: try required("project"),
      title: try required("title"),
      body: body,
      author: try required("author"),
      createdAt: try date("created_at"),
      updatedAt: try date("updated_at"),
      revision: revision,
      confidence: confidence,
      status: status,
      sourceIDs: listFields["source_ids"] ?? [],
      supersedes: listFields["supersedes"] ?? [],
      tags: listFields["tags"] ?? [],
      entityIDs: listFields["entity_ids"] ?? [],
      factKind: factKind,
      expiresAt: expiresAt,
      profileID: fields["profile_id"].flatMap(UUID.init(uuidString:)),
      trustScore: trustScore,
      helpfulCount: helpfulCount,
      unhelpfulCount: unhelpfulCount
    )
  }

  /// Fixed three decimals so repeated serialization is byte-stable and revisions diff cleanly —
  /// `Double` description would render 0.5 and 0.45000000000000001 inconsistently.
  private static func trustFormat(_ value: Double) -> String {
    String(format: "%.3f", MemoryTrust.clamp(value))
  }

  private static func list(named key: String, _ values: [String]) -> [String] {
    guard !values.isEmpty else { return ["\(key): []"] }
    return ["\(key):"] + values.map { "  - \($0)" }
  }

  /// Scalars stay on one line; newlines and a leading/trailing ambiguity are the only real
  /// hazards in this strict subset, so quote exactly when needed.
  private static func escapeScalar(_ value: String) -> String {
    let sanitized = value.replacingOccurrences(of: "\n", with: " ")
    if sanitized.hasPrefix("[") || sanitized.hasPrefix("\"") || sanitized.hasSuffix(":")
      || sanitized != sanitized.trimmingCharacters(in: .whitespaces)
    {
      let escaped = sanitized.replacingOccurrences(of: "\"", with: "\\\"")
      return "\"\(escaped)\""
    }
    return sanitized
  }

  private static func unescapeScalar(_ value: String) -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
    return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
  }
}

import Foundation

/// Where a memory record may travel. Retrieval requires an exact authorised scope; nothing falls
/// back to a broader scope.
public enum MemoryScope: String, Codable, CaseIterable, Sendable {
  case devicePrivate = "device-private"
  case userPrivate = "user-private"
  case organisation
  case project
  case canvas
  case agentRole = "agent-role"
  case orchestrationRun = "orchestration-run"
}

/// Record types map one-to-one onto the canonical Project Brain directories.
public enum MemoryRecordType: String, Codable, CaseIterable, Sendable {
  case log
  case wiki
  case raw
  case output
  case decision
  case handoff

  public var directoryName: String {
    switch self {
    case .log: "log"
    case .wiki: "wiki"
    case .raw: "raw"
    case .output: "outputs"
    case .decision: "decisions"
    case .handoff: "handoffs"
    }
  }
}

public enum MemoryStatus: String, Codable, CaseIterable, Sendable {
  case active
  case superseded
  case archived
}

/// Whether an entry is a confirmed statement, a proposal, or a model inference. Inferred content
/// is a suggestion for context, never authoritative truth.
public enum MemoryConfidence: String, Codable, CaseIterable, Sendable {
  case proposed
  case inferred
  case confirmed
  case contested
}

/// Semantic shape of one durable fact. Kept separate from the record's storage type: a
/// commitment may live in a wiki page or decision record while retaining its meaning.
public enum MemoryFactKind: String, Codable, CaseIterable, Sendable {
  case event
  case preference
  case commitment
  case belief
  case fact
}

/// How much a record has earned its place in search results.
///
/// Every record starts equally trusted and moves only on explicit feedback, so ranking degrades
/// gracefully: a brain that never receives feedback behaves exactly as it did before trust
/// existed. Unhelpful feedback is weighted twice as heavily as helpful — a record that actively
/// misleads should sink faster than a merely useful one rises.
public enum MemoryTrust {
  public static let initial = 0.5
  public static let helpfulDelta = 0.05
  public static let unhelpfulDelta = -0.10
  public static let minimum = 0.0
  public static let maximum = 1.0

  /// Records below this score are withheld from search by default. Set so that a record needs
  /// three unhelpful ratings with no offsetting positives before it drops out (0.5 → 0.2, under
  /// the floor) while two still clear it — deliberate rejection, not one bad day.
  public static let searchFloor = 0.3

  public static func clamp(_ value: Double) -> Double {
    max(minimum, min(maximum, value))
  }
}

/// One canonical Project Brain record. Markdown with structured frontmatter is the source of
/// truth; SQLite/FTS indexes are derived accelerators that must be rebuildable from these.
public struct MemoryRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var type: MemoryRecordType
  public var scope: MemoryScope
  public var project: String
  public var title: String
  public var body: String
  public var author: String
  public var createdAt: Date
  public var updatedAt: Date
  /// Monotonic revision used for optimistic concurrency; every write must present the revision
  /// it read. Revision 0 means the record has never been persisted.
  public var revision: Int
  public var confidence: MemoryConfidence
  public var status: MemoryStatus
  public var sourceIDs: [String]
  public var supersedes: [String]
  public var tags: [String]
  /// Stable entity slugs such as `people/max`, `project/otto`, or `company/acme`.
  public var entityIDs: [String]
  public var factKind: MemoryFactKind
  /// Optional expiry for temporary facts. Expired records remain auditable on disk but are never
  /// returned by normal search or context packs.
  public var expiresAt: Date?
  /// Owning saved-profile identity when `scope == .agentRole`. Required for exact-scope retrieval.
  public var profileID: UUID?
  /// Search weight in 0...1, moved only by explicit `helpful`/`unhelpful` feedback. Durable
  /// judgment, so it lives in the canonical Markdown rather than the rebuildable index.
  public var trustScore: Double
  public var helpfulCount: Int
  public var unhelpfulCount: Int

  public init(
    id: String,
    type: MemoryRecordType,
    scope: MemoryScope = .project,
    project: String,
    title: String,
    body: String,
    author: String,
    createdAt: Date = .now,
    updatedAt: Date = .now,
    revision: Int = 0,
    confidence: MemoryConfidence = .proposed,
    status: MemoryStatus = .active,
    sourceIDs: [String] = [],
    supersedes: [String] = [],
    tags: [String] = [],
    entityIDs: [String] = [],
    factKind: MemoryFactKind = .fact,
    expiresAt: Date? = nil,
    profileID: UUID? = nil,
    trustScore: Double = MemoryTrust.initial,
    helpfulCount: Int = 0,
    unhelpfulCount: Int = 0
  ) {
    self.id = id
    self.type = type
    self.scope = scope
    self.project = project
    self.title = title
    self.body = body
    self.author = author
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.revision = revision
    self.confidence = confidence
    self.status = status
    self.sourceIDs = sourceIDs
    self.supersedes = supersedes
    self.tags = tags
    self.entityIDs = entityIDs
    self.factKind = factKind
    self.expiresAt = expiresAt
    self.profileID = profileID
    self.trustScore = MemoryTrust.clamp(trustScore)
    self.helpfulCount = helpfulCount
    self.unhelpfulCount = unhelpfulCount
  }

  public func isAvailable(at date: Date = .now) -> Bool {
    status == .active && (expiresAt == nil || expiresAt! > date)
  }

  /// Record IDs double as file names, appear in citations, and travel through tool calls: they
  /// must be lowercase slugs with no path traversal potential.
  public static func isValidID(_ id: String) -> Bool {
    guard (1...96).contains(id.count) else { return false }
    guard let first = id.first, first.isLowercase || first.isNumber else { return false }
    return id.allSatisfy { $0.isLowercase && $0.isLetter || $0.isNumber || $0 == "-" }
  }

  public static func slug(from title: String, maxLength: Int = 48) -> String {
    let lowered = title.lowercased()
    var slug = ""
    var previousWasDash = true
    for character in lowered {
      if character.isLetter || character.isNumber, character.isASCII {
        slug.append(character)
        previousWasDash = false
      } else if !previousWasDash {
        slug.append("-")
        previousWasDash = true
      }
      if slug.count >= maxLength { break }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    return slug.isEmpty ? "untitled" : slug
  }
}

/// Identity and schema state of one Project Brain, persisted as manifest.json at the brain root.
public struct BrainManifest: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var project: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    project: String,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.schemaVersion = schemaVersion
    self.project = project
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// One hit from the derived search index: enough to cite and decide, never the full content —
/// callers fetch the canonical record explicitly.
public struct BrainSearchHit: Equatable, Sendable {
  public let id: String
  public let type: MemoryRecordType
  public let title: String
  public let excerpt: String
  /// The trust weight applied to this hit's rank, so callers can explain an ordering.
  public let trustScore: Double

  public init(
    id: String,
    type: MemoryRecordType,
    title: String,
    excerpt: String,
    trustScore: Double = MemoryTrust.initial
  ) {
    self.id = id
    self.type = type
    self.title = title
    self.excerpt = excerpt
    self.trustScore = trustScore
  }
}

/// Server-side packed memory context. Callers receive bounded, cited material and explicit
/// budget accounting instead of independently truncating arbitrary search results.
public struct MemoryContextPack: Codable, Equatable, Sendable {
  public var text: String
  public var recordIDs: [String]
  public var budgetTokens: Int
  public var budgetUsed: Int
  public var droppedCount: Int

  public init(
    text: String,
    recordIDs: [String],
    budgetTokens: Int,
    budgetUsed: Int,
    droppedCount: Int
  ) {
    self.text = text
    self.recordIDs = recordIDs
    self.budgetTokens = budgetTokens
    self.budgetUsed = budgetUsed
    self.droppedCount = droppedCount
  }
}

/// A record that failed validation during load and was moved aside rather than silently dropped
/// or allowed to poison the store.
public struct QuarantinedRecord: Equatable, Sendable {
  public let originalPath: String
  public let quarantinePath: String
  public let reason: String

  public init(originalPath: String, quarantinePath: String, reason: String) {
    self.originalPath = originalPath
    self.quarantinePath = quarantinePath
    self.reason = reason
  }
}

public enum MemoryStoreError: Error, LocalizedError, Equatable {
  case invalidRecordID(String)
  case invalidTitle
  case recordNotFound(String)
  case revisionConflict(id: String, currentRevision: Int)
  case secretDetected(String)
  case schemaTooNew(found: Int, supported: Int)
  case malformedRecord(path: String, reason: String)
  case storageFailure(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRecordID(let id):
      "Memory record IDs must be lowercase slugs (letters, digits, dashes): \(id)"
    case .invalidTitle:
      "Memory records need a non-empty title"
    case .recordNotFound(let id):
      "No memory record named \(id)"
    case .revisionConflict(let id, let current):
      "Memory record \(id) changed since it was read (current revision \(current)); re-read and merge instead of overwriting"
    case .secretDetected(let marker):
      "Memory must never contain credentials; found content matching \(marker). Store secrets in the keychain."
    case .schemaTooNew(let found, let supported):
      "This Project Brain uses schema \(found), newer than the supported \(supported); update Otto before editing it"
    case .malformedRecord(let path, let reason):
      "Malformed memory record at \(path): \(reason)"
    case .storageFailure(let message):
      "Memory storage failure: \(message)"
    }
  }
}

/// Conservative credential markers. Rejecting a write is recoverable; persisting a live token in
/// plain Markdown is not.
public enum MemorySecretScanner {
  private static let patterns: [(marker: String, expression: String)] = [
    ("a credential assignment", #"(?i)\b(?:password|api_key|secret)\s*=\s*["']?[^\s"'=]+"#),
    ("a JWT", #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
    ("a private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY"#),
    ("an AWS access key", #"AKIA[0-9A-Z]{16}"#),
    ("a GitHub token", #"gh[pousr]_[A-Za-z0-9]{20,}"#),
    ("a Slack token", #"xox[bpars]-[A-Za-z0-9-]{10,}"#),
    ("an API secret key", #"\bsk-[A-Za-z0-9_-]{20,}"#),
    ("a bearer token", #"Bearer [A-Za-z0-9._~+/-]{25,}"#),
  ]

  public static func firstSecretMarker(in text: String) -> String? {
    for (marker, expression) in patterns
    where text.range(of: expression, options: .regularExpression) != nil {
      return marker
    }
    return nil
  }
}

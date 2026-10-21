import Foundation

/// A read-only projection of recorded relationships, never a source of new memory facts.
public struct MemoryGraph: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable {
    case memory, personal, operating, entity, source, topic, layer
  }

  public enum Relationship: String, CaseIterable, Sendable {
    case belongsTo = "In layer"
    case mentions = "Mentions"
    case cites = "Cites"
    case tagged = "Tagged"
    case supersedes = "Replaces"
  }

  public enum Layer: String, CaseIterable, Sendable {
    case all = "All memory"
    case project = "Project"
    case personal = "You"
    case operating = "Workspace"
    case bots = "Bots"
  }

  public struct Node: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var kind: Kind
    public var context: String
    public var confidence: MemoryConfidence?
    public var updatedAt: Date?
    public var status: String?
  }

  public struct Edge: Identifiable, Equatable, Sendable {
    public var from: String
    public var to: String
    public var relationship: Relationship
    public var id: String { "\(from)|\(relationship.rawValue)|\(to)" }
  }

  public var nodes: [Node]
  public var edges: [Edge]
  public var matchingMemoryCount: Int
  public var visibleMemoryCount: Int
  public var omittedConnections: Int

  public init(
    nodes: [Node] = [], edges: [Edge] = [], matchingMemoryCount: Int = 0,
    visibleMemoryCount: Int = 0, omittedConnections: Int = 0
  ) {
    self.nodes = nodes
    self.edges = edges
    self.matchingMemoryCount = matchingMemoryCount
    self.visibleMemoryCount = visibleMemoryCount
    self.omittedConnections = omittedConnections
  }

  public func neighbors(of id: String) -> Set<String> {
    Set(edges.compactMap { edge in
      edge.from == id ? edge.to : (edge.to == id ? edge.from : nil)
    })
  }

  public static func recordID(_ record: MemoryRecord) -> String {
    "memory:\(record.scope.rawValue):\(record.profileID?.uuidString ?? "shared"):\(record.id)"
  }

  /// Filters the complete local collection before bounding the rendered graph. Search therefore
  /// still finds older records beyond the initial visual sample. Existing trust is never changed.
  public static func build(
    records: [MemoryRecord], personal: [CompactMemoryEntry] = [],
    operating: [CompactMemoryEntry] = [], botNames: [UUID: String] = [:],
    query: String = "", layer: Layer = .all, includeActivity: Bool = false,
    includeHistory: Bool = false, memoryLimit: Int = 100, nodeLimit: Int = 320,
    now: Date = .now
  ) -> MemoryGraph {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    func matches(_ text: String) -> Bool {
      needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }
    let eligible = records.filter { record in
      guard [.project, .canvas, .agentRole].contains(record.scope),
        includeHistory || record.isAvailable(at: now),
        includeActivity || record.type != .log,
        layer == .all || (layer == .bots && record.scope == .agentRole)
          || (layer == .project && record.scope != .agentRole)
      else { return false }
      return matches(
        ([record.id, record.title, record.body] + record.tags + record.entityIDs
          + record.sourceIDs).joined(separator: "\n"))
    }.sorted {
      if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
      return recordID($0) < recordID($1)
    }
    let user = (layer == .all || layer == .personal)
      ? personal.filter { matches($0.text + "\n" + $0.source) } : []
    let workspace = (layer == .all || layer == .operating)
      ? operating.filter { matches($0.text + "\n" + $0.source) } : []
    let maximum = max(1, min(memoryLimit, max(1, nodeLimit)))
    let compact = (user.map { ($0, Kind.personal) } + workspace.map { ($0, Kind.operating) })
      .sorted { "\($0.1.rawValue):\($0.0.id)" < "\($1.1.rawValue):\($1.0.id)" }
    let compactSlots = eligible.isEmpty ? maximum
      : max(0, maximum - min(eligible.count, max(1, maximum * 2 / 3)))
    let chosenCompact = Array(compact.prefix(compactSlots))
    let chosen = Array(eligible.prefix(maximum - chosenCompact.count))
    var graph = MemoryGraph(
      matchingMemoryCount: eligible.count + compact.count,
      visibleMemoryCount: chosen.count + chosenCompact.count)
    var nodes: [String: Node] = [:]
    var edges: [String: Edge] = [:]

    func layerName(_ record: MemoryRecord) -> String {
      if record.scope == .agentRole {
        return "Private bot · \(record.profileID.flatMap { botNames[$0] } ?? "Unnamed bot")"
      }
      return "Project knowledge"
    }
    // Memories get priority over hubs. Supporting nodes are bounded separately and omissions
    // are counted, so a dense imported record cannot freeze the graph or silently hide data.
    for record in chosen {
      nodes[recordID(record)] = Node(
        id: recordID(record), title: record.title, detail: record.body, kind: .memory,
        context: "\(layerName(record)) · \(record.type.rawValue.capitalized)",
        confidence: record.confidence, updatedAt: record.updatedAt,
        status: record.expiresAt.map { $0 <= now } == true ? "Expired" : record.status.rawValue)
    }
    for (entry, kind) in chosenCompact {
      let id = "\(kind.rawValue):\(entry.id)"
      nodes[id] = Node(
        id: id, title: entry.text, detail: entry.text, kind: kind,
        context: kind == .personal ? "User context · always loaded when confirmed"
          : "Operating memory · always loaded when confirmed",
        confidence: entry.confidence, updatedAt: entry.lastConfirmedAt, status: "active")
    }
    func connect(_ from: String, _ target: Node, _ relationship: Relationship) {
      guard from != target.id else { return }
      guard nodes[target.id] != nil || nodes.count < max(1, nodeLimit) else {
        graph.omittedConnections += 1
        return
      }
      if nodes[target.id] == nil { nodes[target.id] = target }
      let edge = Edge(from: from, to: target.id, relationship: relationship)
      edges[edge.id] = edge
    }
    func hub(_ id: String, _ title: String, _ kind: Kind, _ detail: String) -> Node {
      Node(id: id, title: title, detail: detail, kind: kind, context: kind.rawValue.capitalized)
    }
    func reference(_ source: String, for record: MemoryRecord) -> MemoryRecord? {
      let id = source.hasPrefix("memory:") ? String(source.dropFirst(7)) : source
      // Unqualified IDs must never accidentally point at another bot's same-named record.
      return chosen.first {
        $0.id == id && $0.scope == record.scope && $0.profileID == record.profileID
      }
    }
    for record in chosen {
      let id = recordID(record)
      let owner = record.scope == .agentRole
        ? "bot:\(record.profileID?.uuidString ?? "unknown")" : "project"
      connect(id, hub("layer:\(owner)", layerName(record), .layer,
        "Membership comes from the memory's saved scope."), .belongsTo)
      for entity in Set(record.entityIDs).sorted() where !entity.isEmpty {
        connect(id, hub("entity:\(entity)", entity, .entity,
          "Memories explicitly associated with this entity ID."), .mentions)
      }
      for tag in Set(record.tags.map { $0.lowercased() }).sorted() where !tag.isEmpty {
        connect(id, hub("topic:\(tag)", tag, .topic,
          "Memories carrying this saved tag. A shared tag is not a factual claim."), .tagged)
      }
      for source in Set(record.sourceIDs).sorted() where !source.isEmpty {
        if let other = reference(source, for: record), let target = nodes[recordID(other)] {
          connect(id, target, .cites)
        } else {
          connect(id, hub("source:\(source)", source, .source,
            "Source citation as stored in memory. A citation does not independently verify a claim."), .cites)
        }
      }
      for previous in Set(record.supersedes).sorted() {
        if let other = reference(previous, for: record), let target = nodes[recordID(other)] {
          connect(id, target, .supersedes)
        } else {
          graph.omittedConnections += 1
        }
      }
    }
    for (entry, kind) in chosenCompact {
      let id = "\(kind.rawValue):\(entry.id)"
      let label = kind == .personal ? "About you" : "Working together"
      connect(id, hub("layer:\(kind.rawValue)", label, .layer,
        "Compact context supplied to agents automatically when confirmed."), .belongsTo)
      if !entry.source.isEmpty {
        connect(id, hub("source:\(entry.source)", entry.source, .source,
          "The recorded origin of this compact memory."), .cites)
      }
    }
    graph.nodes = nodes.values.sorted { $0.id < $1.id }
    graph.edges = edges.values.sorted { $0.id < $1.id }
    return graph
  }
}

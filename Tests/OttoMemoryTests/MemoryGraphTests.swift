import Foundation
import OttoMemory
import Testing

@Suite("Memory graph")
struct MemoryGraphTests {
  private func record(
    _ id: String, sources: [String] = [], entities: [String] = [],
    tags: [String] = []
  ) -> MemoryRecord {
    MemoryRecord(
      id: id, type: .wiki, project: "Test", title: id, body: "A stored fact.",
      author: "test", updatedAt: Date(timeIntervalSince1970: 100), confidence: .confirmed,
      sourceIDs: sources, tags: tags, entityIDs: entities)
  }

  @Test("Shared sources, entities and tags produce explicit, deduplicated links")
  func recordedLinks() {
    let a = record(
      "a", sources: ["https://example.com", "https://example.com"],
      entities: ["people/max"], tags: ["Product"])
    let b = record(
      "b", sources: ["https://example.com"], entities: ["people/max"], tags: ["product"])
    let graph = MemoryGraph.build(records: [a, b])
    #expect(graph.nodes.filter { $0.kind == .source }.count == 1)
    #expect(graph.nodes.filter { $0.kind == .entity }.count == 1)
    #expect(graph.nodes.filter { $0.kind == .topic }.count == 1)
    #expect(graph.edges.filter { $0.relationship == .cites }.count == 2)
    #expect(
      graph.neighbors(of: "entity:people/max") == [
        MemoryGraph.recordID(a), MemoryGraph.recordID(b),
      ])
  }

  @Test("Similar prose does not manufacture semantic relationships")
  func noGuessedLinks() {
    let graph = MemoryGraph.build(records: [record("first"), record("second")])
    #expect(graph.edges.allSatisfy { $0.relationship == .belongsTo })
    #expect(graph.nodes.filter { $0.kind == .entity || $0.kind == .topic }.isEmpty)
  }

  @Test("Same-named private memories remain distinct and references stay in their scope")
  func scopedReferences() throws {
    var a = record("shared-id")
    a.scope = .agentRole
    a.profileID = UUID()
    var b = a
    b.profileID = UUID()
    var next = record("next", sources: ["memory:shared-id"])
    next.scope = .agentRole
    next.profileID = a.profileID
    let graph = MemoryGraph.build(records: [a, b, next])
    #expect(graph.visibleMemoryCount == 3)
    let edge = try #require(graph.edges.first { $0.relationship == .cites })
    #expect(edge.to == MemoryGraph.recordID(a))
    #expect(edge.to != MemoryGraph.recordID(b))
  }

  @Test("History, activity, confidence and expiry remain explicit")
  func historyAndConfidence() {
    var old = record("old")
    old.status = .superseded
    var new = record("new")
    new.supersedes = ["old"]
    new.confidence = .proposed
    var expired = record("temporary")
    expired.expiresAt = Date(timeIntervalSince1970: 1)
    var log = record("activity")
    log.type = .log
    let current = MemoryGraph.build(records: [old, new, expired, log])
    #expect(current.visibleMemoryCount == 1)
    #expect(current.nodes.first { $0.id == MemoryGraph.recordID(new) }?.confidence == .proposed)
    #expect(current.omittedConnections == 1)
    let history = MemoryGraph.build(
      records: [old, new, expired, log], includeActivity: true,
      includeHistory: true)
    #expect(history.visibleMemoryCount == 4)
    #expect(
      history.edges.contains {
        $0.relationship == .supersedes && $0.to == MemoryGraph.recordID(old)
      })
    #expect(history.nodes.first { $0.id == MemoryGraph.recordID(expired) }?.status == "Expired")
  }

  @Test("Search reaches records outside a bounded initial sample")
  func searchBeforeSampling() {
    let records = (0..<20).map { index -> MemoryRecord in
      var item = record("record-\(index)")
      item.updatedAt = Date(timeIntervalSince1970: Double(index))
      return item
    }
    let sample = MemoryGraph.build(records: records, memoryLimit: 2)
    #expect(sample.visibleMemoryCount == 2)
    #expect(sample.matchingMemoryCount == 20)
    #expect(!sample.nodes.contains { $0.id == MemoryGraph.recordID(records[0]) })
    let found = MemoryGraph.build(records: records, query: "record-0", memoryLimit: 2)
    #expect(found.visibleMemoryCount == 1)
    #expect(found.nodes.contains { $0.id == MemoryGraph.recordID(records[0]) })
  }

  @Test("Dense records are bounded and omitted relationships are reported")
  func denseInputs() {
    let dense = record("dense", sources: (0..<500).map { "source:\($0)" })
    let graph = MemoryGraph.build(records: [dense], nodeLimit: 12)
    #expect(graph.nodes.count <= 12)
    #expect(graph.omittedConnections > 0)
    #expect(graph.edges.allSatisfy { edge in graph.nodes.contains { $0.id == edge.to } })
  }

  @Test("Compact context is included without crowding out project knowledge")
  func compactAndProjectLayers() {
    let personal = (0..<40).map {
      CompactMemoryEntry(id: "pref-\($0)", text: "Preference \($0)", source: "user statement")
    }
    let operating = (0..<60).map {
      CompactMemoryEntry(id: "habit-\($0)", text: "Habit \($0)", source: "session:test")
    }
    let graph = MemoryGraph.build(
      records: [record("project")], personal: personal, operating: operating)
    #expect(graph.nodes.contains { $0.kind == .memory })
    #expect(graph.nodes.contains { $0.kind == .personal })
    let onlyYou = MemoryGraph.build(
      records: [record("project")], personal: personal,
      operating: operating, layer: .personal)
    #expect(onlyYou.visibleMemoryCount == 40)
    #expect(!onlyYou.nodes.contains { $0.kind == .operating || $0.kind == .memory })
  }

  @Test("Projection and layout are deterministic, finite and non-mutating")
  func stableLayout() {
    let a = record("a", tags: ["one"])
    let b = record("b", tags: ["one", "two"])
    let graph = MemoryGraph.build(records: [a, b])
    #expect(graph == MemoryGraph.build(records: [b, a]))
    let points = MemoryGraphLayout.positions(for: graph)
    #expect(points == MemoryGraphLayout.positions(for: graph))
    #expect(points.count == graph.nodes.count)
    #expect(points.values.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(a.confidence == .confirmed)
  }
}

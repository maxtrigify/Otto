import OttoMemory
import SwiftUI

struct MemoryGraphView: View {
  let records: [MemoryRecord]
  let personal: [CompactMemoryEntry]
  let operating: [CompactMemoryEntry]
  let botNames: [UUID: String]
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  @State private var query = ""
  @State private var layer: MemoryGraph.Layer = .all
  @State private var includeActivity = false
  @State private var includeHistory = false
  @State private var relationships = Set(MemoryGraph.Relationship.allCases)
  @State private var listMode = false
  @State private var neighborhoodOnly = false
  @State private var graph = MemoryGraph()
  @State private var neighborIndex: [String: Set<String>] = [:]
  @State private var positions: [String: MemoryGraphLayout.Point] = [:]
  @State private var selectedID: String?
  @State private var worldBounds = CGRect(x: -100, y: -90, width: 200, height: 180)
  @State private var cameraReset = UUID()
  @State private var loading = false

  private struct Request: Equatable, Sendable {
    var records: [MemoryRecord]
    var personal: [CompactMemoryEntry]
    var operating: [CompactMemoryEntry]
    var botNames: [UUID: String]
    var query: String
    var layer: MemoryGraph.Layer
    var activity: Bool
    var history: Bool
  }

  private var request: Request {
    Request(
      records: records, personal: personal, operating: operating, botNames: botNames,
      query: query, layer: layer, activity: includeActivity, history: includeHistory)
  }

  private var selected: MemoryGraph.Node? { graph.nodes.first { $0.id == selectedID } }
  private var enabledEdges: [MemoryGraph.Edge] {
    graph.edges.filter { relationships.contains($0.relationship) }
  }
  private var neighbors: Set<String> {
    selectedID.flatMap { neighborIndex[$0] } ?? []
  }
  private var visibleNodes: [MemoryGraph.Node] {
    let linked = Set(neighborIndex.keys)
    let filtered = graph.nodes.filter {
      [.memory, .personal, .operating].contains($0.kind) || linked.contains($0.id)
    }
    guard neighborhoodOnly, let selectedID else { return filtered }
    return filtered.filter { $0.id == selectedID || neighbors.contains($0.id) }
  }
  private var visibleIDs: Set<String> { Set(visibleNodes.map(\.id)) }
  private var visibleEdges: [MemoryGraph.Edge] {
    let ids = visibleIDs
    return enabledEdges.filter { ids.contains($0.from) && ids.contains($0.to) }
  }

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider().overlay(palette.paper.opacity(0.07))
      HStack(spacing: 0) {
        ZStack(alignment: .bottomLeading) {
          map.opacity(listMode ? 0 : 1)
            .allowsHitTesting(!listMode).disabled(listMode).accessibilityHidden(listMode)
          if listMode { nodeList }
          if loading {
            ProgressView().controlSize(.small).padding(20)
          }
        }
        Divider().overlay(palette.paper.opacity(0.07))
        detailPanel.frame(width: 290)
      }
      Divider().overlay(palette.paper.opacity(0.07))
      footer
    }
    .task(id: request) { await rebuild(request) }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
        TextField("Search memories…", text: $query)
          .textFieldStyle(.plain).font(.ottoDisplay(13))
          .accessibilityLabel("Search memory graph")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel("Clear memory search")
        }
      }
      .padding(9).background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
      .frame(maxWidth: 300)
      Picker("Memory layer", selection: $layer) {
        ForEach(MemoryGraph.Layer.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .labelsHidden().frame(width: 135)
      Menu {
        Section("Connections") {
          ForEach(MemoryGraph.Relationship.allCases, id: \.self) { relationship in
            Toggle(
              connectionFilterTitle(relationship),
              isOn: Binding(
                get: { relationships.contains(relationship) },
                set: { show in
                  if show {
                    relationships.insert(relationship)
                  } else {
                    relationships.remove(relationship)
                  }
                  refreshNeighbors()
                  if let selectedID, !visibleNodes.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                    neighborhoodOnly = false
                  }
                  resetCamera()
                }))
          }
        }
        Section("Memories") {
          Toggle("Include activity logs", isOn: $includeActivity)
          Toggle("Include archived, replaced and expired memories", isOn: $includeHistory)
        }
      } label: {
        Label(
          filterCount == 0 ? "Filters" : "Filters · \(filterCount)",
          systemImage: "line.3.horizontal.decrease")
      }
      .menuStyle(.borderlessButton).fixedSize()
      Spacer(minLength: 0)
      Button {
        listMode.toggle()
      } label: {
        Image(systemName: listMode ? "point.3.connected.trianglepath.dotted" : "list.bullet")
      }
      .help(listMode ? "Show graph" : "Browse accessible memory list")
      .accessibilityLabel(listMode ? "Show memory graph" : "Show memory list")
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private var map: some View {
    MemoryGraphSurface(
      nodes: visibleNodes, edges: visibleEdges, positions: $positions,
      selectedID: selectedID, neighbors: neighbors, neighborIndex: neighborIndex,
      bounds: worldBounds, resetID: cameraReset, neighborhoodOnly: neighborhoodOnly,
      emptyTitle: query.isEmpty ? "Your map starts here" : "No matching memories",
      emptyDescription: query.isEmpty
        ? "Connections appear as Otto saves memories with sources, entities and tags."
        : "Try another search, layer, or include activity and history.",
      loading: loading, select: select,
      focus: {
        neighborhoodOnly.toggle()
        resetCamera()
      }, fit: resetCamera)
  }

  private var nodeList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(visibleNodes) { node in
          Button {
            select(node.id)
          } label: {
            HStack(spacing: 10) {
              Circle().fill(color(node.kind)).frame(width: 7, height: 7)
              VStack(alignment: .leading, spacing: 3) {
                Text(node.title).font(.ottoDisplay(13)).lineLimit(2)
                Text(node.context).font(.ottoMono(8)).foregroundStyle(palette.muted)
              }
              Spacer()
              Text("\(connectionCount(node.id))").font(.ottoMono(9))
            }
            .foregroundStyle(palette.paper).padding(12)
            .background(
              selectedID == node.id ? palette.signal.opacity(0.1) : .clear,
              in: RoundedRectangle(cornerRadius: 8))
          }.buttonStyle(.plain)
        }
      }.padding(12)
    }
  }

  private var detailPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if let node = selected {
          HStack {
            Label(node.kind.rawValue.uppercased(), systemImage: symbol(node.kind))
              .font(.ottoMono(9, weight: .bold)).foregroundStyle(color(node.kind))
            Spacer()
            Button {
              let wasFocused = neighborhoodOnly
              selectedID = nil
              neighborhoodOnly = false
              if wasFocused { resetCamera() }
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.plain).accessibilityLabel("Clear selected memory")
          }
          Text(node.title).font(.ottoDisplay(21).weight(.semibold)).textSelection(.enabled)
          Text(node.context).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          if let confidence = node.confidence {
            Label(
              confidence == .confirmed
                ? "Confirmed" : "\(confidence.rawValue.capitalized) · unconfirmed",
              systemImage: confidence == .confirmed ? "checkmark.seal" : "circle.dashed"
            )
            .font(.ottoDisplay(11)).foregroundStyle(
              confidence == .confirmed ? palette.signal : palette.amber)
            if confidence != .confirmed {
              Text("Not included as confirmed automatic context.")
                .font(.ottoDisplay(11)).foregroundStyle(palette.muted)
            }
          }
          if let status = node.status, status != "active" {
            Text(status.capitalized).font(.ottoMono(9)).foregroundStyle(palette.amber)
          }
          Text(node.detail).font(.ottoDisplay(12)).lineSpacing(4).textSelection(.enabled)
          if let date = node.updatedAt {
            Text("Updated \(date.formatted(date: .abbreviated, time: .omitted))")
              .font(.ottoMono(8)).foregroundStyle(palette.muted)
          }
          Divider()
          Text("CONNECTIONS · \(connections(to: node.id).count)").font(.ottoMono(9, weight: .bold))
            .foregroundStyle(palette.muted)
          ForEach(connections(to: node.id)) { edge in
            connection(edge, selected: node)
          }
        } else {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(palette.signal)
            .padding(.top, 12)
          Text("Follow a thought.").font(.ottoDisplay(25).weight(.semibold))
          Text(
            "Select a dot to explore its memory, source and connections. Two-finger scroll or drag the background to move. Pinch to zoom; use the mouse wheel or ⌘-scroll to zoom at the pointer. Drag dots to rearrange."
          )
          .font(.ottoDisplay(12)).lineSpacing(4).foregroundStyle(palette.muted)
          Divider()
          Text("MOST CONNECTED").font(.ottoMono(9, weight: .bold)).foregroundStyle(palette.muted)
          ForEach(
            visibleNodes.sorted {
              let a = connectionCount($0.id)
              let b = connectionCount($1.id)
              return a == b ? $0.id < $1.id : a > b
            }.prefix(5)
          ) { node in
            Button {
              select(node.id)
            } label: {
              HStack {
                Circle().fill(color(node.kind)).frame(width: 6, height: 6)
                Text(shortTitle(node)).font(.ottoDisplay(12)).lineLimit(1)
                Spacer()
                Text("\(connectionCount(node.id))").font(.ottoMono(9)).foregroundStyle(
                  palette.muted)
              }.foregroundStyle(palette.paper)
            }.buttonStyle(.plain)
          }
          Divider()
          Text(
            "Memory dots: solid means confirmed; hollow means unconfirmed. Lines show saved sources, tags, entities and layer membership—not guessed associations."
          )
          .font(.ottoDisplay(11)).lineSpacing(3).foregroundStyle(palette.muted)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }
    .background(palette.raised.opacity(0.35))
  }

  private func connection(_ edge: MemoryGraph.Edge, selected: MemoryGraph.Node) -> some View {
    let outgoing = edge.from == selected.id
    let otherID = outgoing ? edge.to : edge.from
    let other = graph.nodes.first { $0.id == otherID }
    return Button {
      select(otherID)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(relationshipLabel(edge.relationship, outgoing: outgoing))
          .font(.ottoMono(8)).foregroundStyle(palette.muted)
        HStack {
          Text(other?.title ?? otherID).font(.ottoDisplay(12)).lineLimit(2)
          Spacer(minLength: 4)
          Image(systemName: "arrow.up.right").font(.system(size: 9))
        }.foregroundStyle(palette.paper)
      }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.paper.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain)
  }

  private var footer: some View {
    HStack(spacing: 14) {
      ForEach([MemoryGraph.Kind.memory, .entity, .topic, .source], id: \.self) { kind in
        HStack(spacing: 5) {
          Circle().fill(color(kind)).frame(width: 5, height: 5)
          Text(kind.rawValue.capitalized).font(.ottoMono(8))
        }
      }
      Spacer()
      Text(
        "\(visibleMemoryCount) of \(graph.matchingMemoryCount) \(graph.matchingMemoryCount == 1 ? "memory" : "memories") · \(visibleEdges.count) \(visibleEdges.count == 1 ? "link" : "links")"
      )
      .font(.ottoMono(8))
      if graph.visibleMemoryCount < graph.matchingMemoryCount || graph.omittedConnections > 0 {
        Text("Sampled · search or filter for more").font(.ottoMono(8)).foregroundStyle(
          palette.amber
        )
        .help(
          "Some memories or links are outside the current sample. Search, or include history in Filters, to explore more."
        )
      }
    }
    .foregroundStyle(palette.muted).padding(.horizontal, 20).padding(.vertical, 11)
  }

  private func color(_ kind: MemoryGraph.Kind) -> Color {
    switch kind {
    case .memory, .personal, .operating, .layer: palette.signal
    case .entity: palette.cyan
    case .source: palette.muted
    case .topic: palette.amber
    }
  }

  private func symbol(_ kind: MemoryGraph.Kind) -> String {
    switch kind {
    case .memory: "sparkle"
    case .personal: "person"
    case .operating: "slider.horizontal.3"
    case .entity: "circle.hexagongrid"
    case .source: "link"
    case .topic: "number"
    case .layer: "square.3.layers.3d"
    }
  }

  private func shortTitle(_ node: MemoryGraph.Node) -> String {
    if node.kind == .source, let url = URL(string: node.title), let host = url.host {
      return host + (url.lastPathComponent.isEmpty ? "" : "/" + url.lastPathComponent)
    }
    return String(node.title.prefix(60))
  }

  private func relationshipLabel(_ kind: MemoryGraph.Relationship, outgoing: Bool) -> String {
    if outgoing { return kind.rawValue }
    switch kind {
    case .belongsTo: return "Contains"
    case .mentions: return "Mentioned by"
    case .cites: return "Cited by"
    case .tagged: return "Tags"
    case .supersedes: return "Replaced by"
    }
  }

  private func select(_ id: String) {
    withAnimation(motion.fade) { selectedID = id }
    if neighborhoodOnly { resetCamera() }
  }

  private func connections(to id: String) -> [MemoryGraph.Edge] {
    enabledEdges.filter { $0.from == id || $0.to == id }
  }

  private func connectionCount(_ id: String) -> Int {
    neighborIndex[id]?.count ?? 0
  }

  private func refreshNeighbors() {
    var index: [String: Set<String>] = [:]
    for edge in enabledEdges {
      index[edge.from, default: []].insert(edge.to)
      index[edge.to, default: []].insert(edge.from)
    }
    neighborIndex = index
  }

  private var filterCount: Int {
    MemoryGraph.Relationship.allCases.count - relationships.count
      + (includeActivity ? 1 : 0) + (includeHistory ? 1 : 0)
  }

  private var visibleMemoryCount: Int {
    visibleNodes.filter { [.memory, .personal, .operating].contains($0.kind) }.count
  }

  private func connectionFilterTitle(_ relationship: MemoryGraph.Relationship) -> String {
    switch relationship {
    case .belongsTo: "Memory layers"
    case .mentions: "Entities"
    case .cites: "Sources"
    case .tagged: "Tags"
    case .supersedes: "Replacements"
    }
  }

  private func resetCamera() {
    worldBounds = calculateBounds()
    cameraReset = UUID()
  }

  private func calculateBounds() -> CGRect {
    let points = visibleNodes.compactMap { positions[$0.id] }
    let minX = points.map(\.x).min() ?? -100
    let maxX = points.map(\.x).max() ?? 100
    let minY = points.map(\.y).min() ?? -100
    let maxY = points.map(\.y).max() ?? 100
    let width = max(200, maxX - minX)
    let height = max(180, maxY - minY)
    return CGRect(
      x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2,
      width: width, height: height)
  }

  @MainActor private func rebuild(_ request: Request) async {
    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
    loading = true
    let result = await Task.detached(priority: .userInitiated) {
      let graph = MemoryGraph.build(
        records: request.records, personal: request.personal,
        operating: request.operating, botNames: request.botNames, query: request.query,
        layer: request.layer, includeActivity: request.activity, includeHistory: request.history)
      return (graph, MemoryGraphLayout.positions(for: graph))
    }.value
    guard !Task.isCancelled else { return }
    graph = result.0
    positions = result.1
    refreshNeighbors()
    if !graph.nodes.contains(where: { $0.id == selectedID }) {
      selectedID = nil
      neighborhoodOnly = false
    }
    worldBounds = calculateBounds()
    cameraReset = UUID()
    loading = false
  }
}

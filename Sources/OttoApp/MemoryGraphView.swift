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
  @State private var hoveredID: String?
  @State private var zoom: CGFloat = 1
  @State private var pan = CGSize.zero
  @State private var gesturePan = CGSize.zero
  @State private var dragging = false
  @State private var worldBounds = CGRect(x: -100, y: -90, width: 200, height: 180)
  @State private var dragOrigin: MemoryGraphLayout.Point?
  @State private var draggedID: String?
  @State private var magnificationStart: CGFloat?
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
    Request(records: records, personal: personal, operating: operating, botNames: botNames,
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
          if listMode { nodeList } else { map }
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
          Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
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
            Toggle(connectionFilterTitle(relationship), isOn: Binding(
              get: { relationships.contains(relationship) },
              set: { show in
                if show { relationships.insert(relationship) }
                else { relationships.remove(relationship) }
                refreshNeighbors()
                if let selectedID, !visibleNodes.contains(where: { $0.id == selectedID }) {
                  self.selectedID = nil; neighborhoodOnly = false
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
        Label(filterCount == 0 ? "Filters" : "Filters · \(filterCount)",
          systemImage: "line.3.horizontal.decrease")
      }
      .menuStyle(.borderlessButton).fixedSize()
      Spacer(minLength: 0)
      Button { listMode.toggle() } label: {
        Image(systemName: listMode ? "point.3.connected.trianglepath.dotted" : "list.bullet")
      }
      .help(listMode ? "Show graph" : "Browse accessible memory list")
      .accessibilityLabel(listMode ? "Show memory graph" : "Show memory list")
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private var map: some View {
    GeometryReader { geometry in
      ZStack {
        RadialGradient(colors: [palette.signal.opacity(0.065), palette.surface],
          center: .center, startRadius: 0, endRadius: 450)
        Canvas { context, size in
          for x in stride(from: 16.0, to: size.width, by: 28) {
            for y in stride(from: 16.0, to: size.height, by: 28) {
              context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                with: .color(palette.paper.opacity(0.07)))
            }
          }
          for edge in visibleEdges {
            guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
            let a = screen(from, in: size), b = screen(to, in: size)
            let active = edge.from == selectedID || edge.to == selectedID
            var line = Path(); line.move(to: a); line.addLine(to: b)
            context.stroke(line, with: .color(active ? palette.signal.opacity(0.72)
              : palette.paper.opacity(selectedID == nil ? 0.055 : 0.025)),
              style: StrokeStyle(lineWidth: active ? 1.4 : 0.7,
                dash: edge.relationship == .supersedes ? [4, 4] : []))
          }
        }
        .accessibilityHidden(true)
        ForEach(visibleNodes) { node in
          if let point = positions[node.id] {
            graphNode(node)
              .position(screen(point, in: geometry.size))
          }
        }
        if graph.nodes.isEmpty && !loading {
          ContentUnavailableView(
            query.isEmpty ? "Your map starts here" : "No matching memories",
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text(query.isEmpty
              ? "Connections appear as Otto saves memories with sources, entities and tags."
              : "Try another search, layer, or include activity and history."))
        }
      }
      .clipped().contentShape(Rectangle())
      .simultaneousGesture(drag(in: geometry.size))
      .simultaneousGesture(MagnificationGesture()
        .onChanged { value in
          if magnificationStart == nil { magnificationStart = zoom }
          zoom = min(3.5, max(0.45, (magnificationStart ?? 1) * value))
        }.onEnded { _ in magnificationStart = nil })
      .overlay(alignment: .bottomTrailing) { mapControls.padding(16) }
    }
  }

  private func graphNode(_ node: MemoryGraph.Node) -> some View {
    let emphasized = selectedID == node.id || hoveredID == node.id
    let related = selectedID == nil || selectedID == node.id || neighbors.contains(node.id)
    let showLabel = emphasized || (related && (zoom > 2 || visibleNodes.count < 22
      || (selectedID != nil && neighbors.count < 15) || node.kind == .layer
      || (node.kind == .topic && connectionCount(node.id) >= 4)))
    let diameter: CGFloat = node.kind == .layer ? 18 : (node.kind == .memory ? 10 : 8)
    return Button { select(node.id) } label: {
      ZStack {
        Circle().fill(color(node.kind).opacity(emphasized ? 0.14 : 0))
          .frame(width: 34, height: 34)
        Circle().fill(node.confidence == nil || node.confidence == .confirmed
          ? color(node.kind) : palette.surface)
          .frame(width: diameter, height: diameter)
          .overlay(Circle().strokeBorder(color(node.kind), lineWidth: 1.5))
          .shadow(color: color(node.kind).opacity(emphasized ? 0.6 : 0.2), radius: emphasized ? 9 : 3)
      }
      .frame(width: 26, height: 26)
      .overlay(alignment: .top) {
        if showLabel {
          Text(shortTitle(node)).font(.ottoDisplay(emphasized ? 12 : 10).weight(emphasized ? .semibold : .regular))
            .lineLimit(1).truncationMode(.middle)
            .frame(width: emphasized ? 190 : 120).foregroundStyle(palette.paper.opacity(emphasized ? 1 : 0.7))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(palette.surface.opacity(emphasized ? 0.95 : 0.15), in: Capsule())
            .offset(y: 25).allowsHitTesting(false)
        }
      }
      .opacity(related ? 1 : 0.22)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(node.kind.rawValue.capitalized): \(node.title)")
    .accessibilityValue(node.confidence?.rawValue ?? "Recorded relationship")
    .help(node.title)
    .onHover { hoveredID = $0 ? node.id : nil }
  }

  private var mapControls: some View {
    HStack(spacing: 12) {
      Button { neighborhoodOnly.toggle(); resetCamera() } label: {
        Image(systemName: neighborhoodOnly ? "scope" : "circle.dotted.circle")
      }
      .disabled(selectedID == nil).help("Focus the selected node and its connections")
      .accessibilityLabel("Focus connections")
      Divider().frame(height: 14)
      Button { zoom = max(0.45, zoom / 1.25) } label: { Image(systemName: "minus") }
        .accessibilityLabel("Zoom out")
      Text("\(Int(zoom * 100))%").font(.ottoMono(9)).frame(width: 35)
      Button { zoom = min(3.5, zoom * 1.25) } label: { Image(systemName: "plus") }
        .accessibilityLabel("Zoom in")
      Button { resetCamera() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
        .help("Fit graph").accessibilityLabel("Fit memory graph")
    }
    .buttonStyle(.plain).foregroundStyle(palette.paper)
    .padding(11).background(palette.raised.opacity(0.94), in: Capsule())
    .overlay(Capsule().strokeBorder(palette.paper.opacity(0.08)))
  }

  private var nodeList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(visibleNodes) { node in
          Button { select(node.id) } label: {
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
            .background(selectedID == node.id ? palette.signal.opacity(0.1) : .clear,
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
              selectedID = nil; neighborhoodOnly = false
              if wasFocused { resetCamera() }
            } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("Clear selected memory")
          }
          Text(node.title).font(.ottoDisplay(21).weight(.semibold)).textSelection(.enabled)
          Text(node.context).font(.ottoDisplay(11)).foregroundStyle(palette.muted)
          if let confidence = node.confidence {
            Label(confidence == .confirmed ? "Confirmed" : "\(confidence.rawValue.capitalized) · unconfirmed",
              systemImage: confidence == .confirmed ? "checkmark.seal" : "circle.dashed")
              .font(.ottoDisplay(11)).foregroundStyle(confidence == .confirmed ? palette.signal : palette.amber)
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
          Text("Select a dot to explore its memory, source and connections. Drag dots to rearrange; drag the background to move around.")
            .font(.ottoDisplay(12)).lineSpacing(4).foregroundStyle(palette.muted)
          Divider()
          Text("MOST CONNECTED").font(.ottoMono(9, weight: .bold)).foregroundStyle(palette.muted)
          ForEach(visibleNodes.sorted {
            let a = connectionCount($0.id), b = connectionCount($1.id)
            return a == b ? $0.id < $1.id : a > b
          }.prefix(5)) { node in
            Button { select(node.id) } label: {
              HStack {
                Circle().fill(color(node.kind)).frame(width: 6, height: 6)
                Text(shortTitle(node)).font(.ottoDisplay(12)).lineLimit(1)
                Spacer()
                Text("\(connectionCount(node.id))").font(.ottoMono(9)).foregroundStyle(palette.muted)
              }.foregroundStyle(palette.paper)
            }.buttonStyle(.plain)
          }
          Divider()
          Text("Memory dots: solid means confirmed; hollow means unconfirmed. Lines show saved sources, tags, entities and layer membership—not guessed associations.")
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
    return Button { select(otherID) } label: {
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
      Text("\(visibleMemoryCount) of \(graph.matchingMemoryCount) \(graph.matchingMemoryCount == 1 ? "memory" : "memories") · \(visibleEdges.count) \(visibleEdges.count == 1 ? "link" : "links")")
        .font(.ottoMono(8))
      if graph.visibleMemoryCount < graph.matchingMemoryCount || graph.omittedConnections > 0 {
        Text("Sampled · search or filter for more").font(.ottoMono(8)).foregroundStyle(palette.amber)
          .help("Some memories or links are outside the current sample. Search, or include history in Filters, to explore more.")
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
    withAnimation(motion.enter(.moderate)) {
      worldBounds = calculateBounds(); zoom = 1; pan = .zero
    }
  }

  private var bounds: CGRect {
    return worldBounds
  }

  private func calculateBounds() -> CGRect {
    let points = visibleNodes.compactMap { positions[$0.id] }
    let minX = points.map(\.x).min() ?? -100, maxX = points.map(\.x).max() ?? 100
    let minY = points.map(\.y).min() ?? -100, maxY = points.map(\.y).max() ?? 100
    let width = max(200, maxX - minX), height = max(180, maxY - minY)
    return CGRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2,
      width: width, height: height)
  }

  private func scale(in size: CGSize) -> CGFloat {
    min((size.width - 110) / bounds.width, (size.height - 90) / bounds.height) * zoom
  }

  private func screen(_ point: MemoryGraphLayout.Point, in size: CGSize) -> CGPoint {
    let factor = scale(in: size)
    return CGPoint(x: size.width / 2 + (point.x - bounds.midX) * factor + pan.width,
      y: size.height / 2 + (point.y - bounds.midY) * factor + pan.height)
  }

  private func drag(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        if !dragging {
          dragging = true
          let hit = visibleNodes.first { node in
            guard let point = positions[node.id] else { return false }
            let p = screen(point, in: size)
            return hypot(p.x - value.startLocation.x, p.y - value.startLocation.y) < 16
          }
          draggedID = hit?.id
          dragOrigin = hit.flatMap { positions[$0.id] }
          gesturePan = pan
        }
        if let id = draggedID, let origin = dragOrigin {
          let factor = max(0.01, scale(in: size))
          positions[id] = .init(x: origin.x + value.translation.width / factor,
            y: origin.y + value.translation.height / factor)
        } else {
          pan = CGSize(width: gesturePan.width + value.translation.width,
            height: gesturePan.height + value.translation.height)
        }
      }
      .onEnded { _ in
        draggedID = nil; dragOrigin = nil; gesturePan = .zero; dragging = false
      }
  }

  @MainActor private func rebuild(_ request: Request) async {
    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
    loading = true
    let result = await Task.detached(priority: .userInitiated) {
      let graph = MemoryGraph.build(records: request.records, personal: request.personal,
        operating: request.operating, botNames: request.botNames, query: request.query,
        layer: request.layer, includeActivity: request.activity, includeHistory: request.history)
      return (graph, MemoryGraphLayout.positions(for: graph))
    }.value
    guard !Task.isCancelled else { return }
    graph = result.0; positions = result.1
    refreshNeighbors()
    if !graph.nodes.contains(where: { $0.id == selectedID }) {
      selectedID = nil; neighborhoodOnly = false
    }
    worldBounds = calculateBounds()
    pan = .zero; zoom = 1; loading = false
  }
}

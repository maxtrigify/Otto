import AppKit
import OttoMemory
import SwiftUI

/// Owns transient camera state so pan/zoom never recomputes the inspector or its graph projection.
struct MemoryGraphSurface: View {
  let nodes: [MemoryGraph.Node]
  let edges: [MemoryGraph.Edge]
  @Binding var positions: [String: MemoryGraphLayout.Point]
  let selectedID: String?
  let neighbors: Set<String>
  let neighborIndex: [String: Set<String>]
  let bounds: CGRect
  let resetID: UUID
  let neighborhoodOnly: Bool
  let emptyTitle: String
  let emptyDescription: String
  let loading: Bool
  let select: (String) -> Void
  let focus: () -> Void
  let fit: () -> Void
  @Environment(\.ottoPalette) private var palette
  @Environment(\.isEnabled) private var isEnabled
  @State private var camera = MemoryGraphCamera()
  @State private var viewport = CGSize.zero
  @State private var hoveredID: String?
  @State private var dragStart: CGPoint?
  @State private var dragOrigin: MemoryGraphLayout.Point?
  @State private var draggedID: String?
  @State private var initialPan = CGSize.zero

  var body: some View {
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
          for edge in edges {
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
        ForEach(nodes) { node in
          if let point = positions[node.id] {
            graphNode(node).position(screen(point, in: geometry.size))
          }
        }
        if nodes.isEmpty && !loading {
          ContentUnavailableView(emptyTitle,
            systemImage: "point.3.connected.trianglepath.dotted",
            description: Text(emptyDescription))
        }
      }
      .background {
        MemoryGraphInputMonitor(isEnabled: isEnabled) { input, anchor in
          // Direct input must track fingers without implicit animation or spring lag.
          var transaction = Transaction(); transaction.disablesAnimations = true
          withTransaction(transaction) {
            switch input {
            case .pan(let delta): camera.panBy(delta)
            case .zoom(let factor): camera.zoom(by: factor, at: anchor, in: geometry.size)
            }
          }
        }
      }
      .clipped().contentShape(Rectangle())
      .simultaneousGesture(drag(in: geometry.size))
      .overlay(alignment: .bottomTrailing) { mapControls.padding(16) }
      .onAppear { viewport = geometry.size }
      .onChange(of: geometry.size) { _, size in viewport = size }
    }
    .onChange(of: resetID) { _, _ in
      camera = MemoryGraphCamera()
    }
  }

  private func screen(_ point: MemoryGraphLayout.Point, in size: CGSize) -> CGPoint {
    camera.screen(CGPoint(x: point.x, y: point.y), bounds: bounds, viewport: size)
  }

  private func changeZoom(by factor: CGFloat) {
    camera.zoom(by: factor, at: CGPoint(x: viewport.width / 2, y: viewport.height / 2), in: viewport)
  }

  private func drag(in size: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { value in
        if dragStart == nil {
          dragStart = value.startLocation
          let hit = nodes.min { a, b in
            distance(a, from: value.startLocation, in: size) < distance(b, from: value.startLocation, in: size)
          }
          if let hit, distance(hit, from: value.startLocation, in: size) < 16 {
            draggedID = hit.id; dragOrigin = positions[hit.id]
          }
          initialPan = camera.pan
        }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
          if let id = draggedID, let origin = dragOrigin {
            let factor = camera.scale(bounds: bounds, viewport: size)
            positions[id] = .init(x: origin.x + value.translation.width / factor,
              y: origin.y + value.translation.height / factor)
          } else {
            camera.pan = CGSize(width: initialPan.width + value.translation.width,
              height: initialPan.height + value.translation.height)
          }
        }
      }
      .onEnded { _ in
        draggedID = nil; dragOrigin = nil; dragStart = nil
      }
  }

  private func distance(_ node: MemoryGraph.Node, from location: CGPoint, in size: CGSize) -> CGFloat {
    guard let point = positions[node.id] else { return .infinity }
    let p = screen(point, in: size)
    return hypot(p.x - location.x, p.y - location.y)
  }

  private func graphNode(_ node: MemoryGraph.Node) -> some View {
    let emphasized = selectedID == node.id || hoveredID == node.id
    let related = selectedID == nil || selectedID == node.id || neighbors.contains(node.id)
    let showLabel = emphasized || (related && (camera.zoom > 2 || nodes.count < 22
      || (selectedID != nil && neighbors.count < 15) || node.kind == .layer
      || (node.kind == .topic && (neighborIndex[node.id]?.count ?? 0) >= 4)))
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
      Button(action: focus) {
        Image(systemName: neighborhoodOnly ? "scope" : "circle.dotted.circle")
      }
      .disabled(selectedID == nil).help("Focus the selected node and its connections")
      .accessibilityLabel("Focus connections")
      Divider().frame(height: 14)
      Button { changeZoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }
        .accessibilityLabel("Zoom out")
      Text("\(Int(camera.zoom * 100))%").font(.ottoMono(9)).frame(width: 35)
      Button { changeZoom(by: 1.25) } label: { Image(systemName: "plus") }
        .accessibilityLabel("Zoom in")
      Button(action: fit) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
        .help("Fit graph").accessibilityLabel("Fit memory graph")
    }
    .buttonStyle(.plain).foregroundStyle(palette.paper)
    .padding(11).background(palette.raised.opacity(0.94), in: Capsule())
    .overlay(Capsule().strokeBorder(palette.paper.opacity(0.08)))
  }

  private func color(_ kind: MemoryGraph.Kind) -> Color {
    switch kind {
    case .memory, .personal, .operating, .layer: palette.signal
    case .entity: palette.cyan
    case .source: palette.muted
    case .topic: palette.amber
    }
  }

  private func shortTitle(_ node: MemoryGraph.Node) -> String {
    if node.kind == .source, let url = URL(string: node.title), let host = url.host {
      return host + (url.lastPathComponent.isEmpty ? "" : "/" + url.lastPathComponent)
    }
    return String(node.title.prefix(60))
  }

}

private enum MemoryGraphInput {
  case pan(CGSize)
  case zoom(CGFloat)
}

/// Observe only events over this graph; never swallow scrolling in details, menus, or curation.
private struct MemoryGraphInputMonitor: NSViewRepresentable {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  let isEnabled: Bool
  let perform: (MemoryGraphInput, CGPoint) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = FlippedView()
    context.coordinator.view = view
    context.coordinator.install()
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.isEnabled = isEnabled && spaceVisible
    context.coordinator.perform = perform
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }
  private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  @MainActor final class Coordinator {
    weak var view: NSView?
    var isEnabled = false
    var perform: ((MemoryGraphInput, CGPoint) -> Void)?
    private var monitor: Any?
    func install() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
        guard let self, self.isEnabled, let view = self.view,
          let window = view.window, event.window === window, window.isKeyWindow,
          !view.isHiddenOrHasHiddenAncestor
        else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.bounds.contains(point), NSApp.keyWindow === window else { return event }
        if event.type == .magnify {
          self.perform?(.zoom(exp(event.magnification)), point)
        } else if !event.hasPreciseScrollingDeltas
          || !event.modifierFlags.intersection([.command, .control]).isEmpty {
          let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.008 : 0.08
          self.perform?(.zoom(exp(event.scrollingDeltaY * sensitivity)), point)
        } else {
          self.perform?(.pan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)), point)
        }
        return nil
      }
    }
    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

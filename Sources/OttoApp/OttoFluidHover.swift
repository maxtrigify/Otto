import SwiftUI

/// Fluid hover, after Fluid Functionalism: one highlight per list that glides to the nearest
/// row instead of blinking off and on at every gap. Rows report their frames through a
/// preference; the container tracks the pointer, picks the nearest enabled row along the
/// list's axis, and springs a single fill between the measured rects on the fast tier. The
/// fill is pointer-transparent, so rows keep their own buttons, menus, and focus.
///
///   OttoFluidHover(axis: .vertical, style: .init(fill: palette.paper.opacity(0.06))) {
///     ForEach(rows) { row in rowView(row).ottoHoverItem(row.id) }
///   }
///
/// Pass `highlight` to drive the same fill from keyboard selection: the pointer then writes
/// the binding, and arrow keys move the highlight through the same spring. Pass `selected`
/// to draw a second, persistent fill on the moderate tier for the current row.
enum OttoFluidHoverAxis: Equatable, Sendable {
  case vertical
  case horizontal
  case grid
}

struct OttoFluidHoverStyle {
  var fill: Color
  var selectedFill: Color? = nil
  var cornerRadius: CGFloat = 7
  var inset: CGFloat = 0
}

struct OttoFluidHoverItem: Equatable, @unchecked Sendable {
  let id: AnyHashable
  let frame: CGRect
  let disabled: Bool
}

struct OttoFluidHoverItemsKey: PreferenceKey {
  static let defaultValue: [OttoFluidHoverItem] = []
  static func reduce(value: inout [OttoFluidHoverItem], nextValue: () -> [OttoFluidHoverItem]) {
    value.append(contentsOf: nextValue())
  }
}

private struct OttoFluidHoverSpaceKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  fileprivate var ottoFluidHoverSpace: String? {
    get { self[OttoFluidHoverSpaceKey.self] }
    set { self[OttoFluidHoverSpaceKey.self] = newValue }
  }
}

/// Pure picking rule, kept separate so it is testable: a pointer inside an enabled row wins;
/// otherwise the enabled row whose centre is nearest along the list's axis wins, so a
/// pointer in a gap or a divider still lands on a row and the highlight never goes dark.
enum OttoFluidHoverPicker {
  static func nearest(
    to point: CGPoint, in items: [OttoFluidHoverItem], axis: OttoFluidHoverAxis
  ) -> AnyHashable? {
    let enabled = items.filter { !$0.disabled && !$0.frame.isEmpty }
    guard !enabled.isEmpty else { return nil }
    if let hit = enabled.first(where: { $0.frame.contains(point) }) { return hit.id }
    func distance(_ item: OttoFluidHoverItem) -> CGFloat {
      let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
      switch axis {
      case .vertical: return abs(point.y - center.y)
      case .horizontal: return abs(point.x - center.x)
      case .grid: return hypot(point.x - center.x, point.y - center.y)
      }
    }
    return enabled.min { distance($0) < distance($1) }?.id
  }
}

extension View {
  /// Registers this view as a fluid hover target inside the nearest `OttoFluidHover`.
  func ottoHoverItem<ID: Hashable>(_ id: ID, disabled: Bool = false) -> some View {
    modifier(OttoFluidHoverItemModifier(id: AnyHashable(id), disabled: disabled))
  }
}

private struct OttoFluidHoverItemModifier: ViewModifier {
  @Environment(\.ottoFluidHoverSpace) private var space
  let id: AnyHashable
  let disabled: Bool

  func body(content: Content) -> some View {
    content.background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: OttoFluidHoverItemsKey.self,
          value: [
            OttoFluidHoverItem(
              id: id,
              frame: space.map { proxy.frame(in: .named($0)) } ?? proxy.frame(in: .local),
              disabled: disabled
            )
          ]
        )
      }
    }
  }
}

struct OttoFluidHover<Content: View>: View {
  @Environment(\.ottoMotion) private var motion
  let axis: OttoFluidHoverAxis
  let style: OttoFluidHoverStyle
  /// External highlight (keyboard-driven lists). When nil the container owns hover state and
  /// the fill disappears as the pointer leaves.
  let highlight: Binding<AnyHashable?>?
  let selected: AnyHashable?
  let content: () -> Content

  @State private var items: [OttoFluidHoverItem] = []
  @State private var hovered: AnyHashable? = nil
  @State private var pointer: CGPoint? = nil
  @State private var space = "otto-fluid-hover-\(UUID().uuidString)"

  /// Hover only: the fill follows the pointer and leaves with it.
  init(
    axis: OttoFluidHoverAxis = .vertical, style: OttoFluidHoverStyle,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.axis = axis
    self.style = style
    self.highlight = nil
    self.selected = nil
    self.content = content
  }

  /// Hover plus a persistent selected fill on the moderate tier for `selected`.
  init<Selection: Hashable>(
    axis: OttoFluidHoverAxis = .vertical, style: OttoFluidHoverStyle, selected: Selection?,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.axis = axis
    self.style = style
    self.highlight = nil
    self.selected = selected.map { AnyHashable($0) }
    self.content = content
  }

  /// Keyboard-driven: the pointer writes `highlight`, arrow keys move it, and the fill
  /// follows either through the same spring.
  init<Highlight: Hashable>(
    axis: OttoFluidHoverAxis = .vertical, style: OttoFluidHoverStyle,
    highlight: Binding<Highlight?>, @ViewBuilder content: @escaping () -> Content
  ) {
    self.axis = axis
    self.style = style
    self.highlight = Binding<AnyHashable?>(
      get: { highlight.wrappedValue.map { AnyHashable($0) } },
      set: { highlight.wrappedValue = $0?.base as? Highlight }
    )
    self.selected = nil
    self.content = content
  }

  private var currentHighlight: AnyHashable? {
    if let highlight { return highlight.wrappedValue }
    return hovered
  }

  private func rect(for id: AnyHashable?) -> CGRect? {
    guard let id else { return nil }
    return items.first { $0.id == id && !$0.frame.isEmpty }?.frame
  }

  private var hoverRect: CGRect? {
    // A keyboard-driven highlight stays visible without a pointer; a hover-only one leaves
    // with it.
    guard highlight != nil || pointer != nil else { return nil }
    return rect(for: currentHighlight)
  }

  private var selectedRect: CGRect? { rect(for: selected) }

  var body: some View {
    content()
      .environment(\.ottoFluidHoverSpace, space)
      .coordinateSpace(name: space)
      .background(alignment: .topLeading) { fills }
      .onPreferenceChange(OttoFluidHoverItemsKey.self) { next in
        items = next
        if let pointer { pick(at: pointer) }
      }
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          pointer = location
          pick(at: location)
        case .ended:
          pointer = nil
          hovered = nil
        }
      }
  }

  private func pick(at point: CGPoint) {
    guard let id = OttoFluidHoverPicker.nearest(to: point, in: items, axis: axis) else { return }
    if let highlight {
      if highlight.wrappedValue != id { highlight.wrappedValue = id }
    } else if hovered != id {
      hovered = id
    }
  }

  @ViewBuilder private var fills: some View {
    ZStack(alignment: .topLeading) {
      if let selectedFill = style.selectedFill, let selectedRect {
        fill(selectedFill, rect: selectedRect)
          // The current row steps back a little while the pointer is elsewhere.
          .opacity(hoverRect == nil || hoverRect == selectedRect ? 1 : 0.85)
          .animation(motion.enter(.moderate), value: selectedRect)
          .animation(motion.fade, value: hoverRect == nil || hoverRect == selectedRect)
          .transition(.opacity.animation(motion.fade))
      }
      if let hoverRect {
        fill(style.fill, rect: hoverRect)
          // Over the selected row the hover fill only tints, so the two never stack solid.
          .opacity(selectedRect == hoverRect && style.selectedFill != nil ? 0.4 : 1)
          .animation(motion.enter(.fast), value: hoverRect)
          .transition(
            .asymmetric(
              insertion: .opacity.animation(motion.fade),
              removal: .opacity.animation(OttoMotion.fast.exit)
            )
          )
      }
    }
    .animation(motion.fade, value: hoverRect == nil)
    .animation(motion.fade, value: selectedRect == nil)
    .allowsHitTesting(false)
  }

  private func fill(_ color: Color, rect: CGRect) -> some View {
    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
      .fill(color)
      .frame(
        width: max(0, rect.width - style.inset * 2),
        height: max(0, rect.height - style.inset * 2)
      )
      .offset(x: rect.minX + style.inset, y: rect.minY + style.inset)
  }
}

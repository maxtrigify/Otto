import SwiftUI

/// Scroll chrome after Fluid Functionalism's ScrollArea: an overlay thumb that rests thin
/// and quiet, widens and darkens when you reach for it, and never hides the fact that a
/// list has more below; plus an edge fade that dissolves content toward whichever edge
/// still has more to scroll while keeping the true start and end crisp.
///
///   ScrollView { … }.ottoScrollChrome()
///
/// The system indicators are hidden underneath. Pass a `ScrollPosition` binding to make the
/// thumb draggable; without one it is display only.
struct OttoScrollMetrics: Equatable {
  var offset: CGPoint = .zero
  var content: CGSize = .zero
  var container: CGSize = .zero

  var verticalOverflow: CGFloat { max(0, content.height - container.height) }
  var horizontalOverflow: CGFloat { max(0, content.width - container.width) }
  var remainingBelow: CGFloat { max(0, verticalOverflow - offset.y) }
  var remainingAfter: CGFloat { max(0, horizontalOverflow - offset.x) }
}

/// Pure geometry for the overlay thumb, exported for the unit test.
enum OttoScrollThumbGeometry {
  static let minimumLength: CGFloat = 24

  /// Thumb length and leading offset along a track of `track` points.
  static func thumb(track: CGFloat, content: CGFloat, container: CGFloat, offset: CGFloat)
    -> (length: CGFloat, position: CGFloat)?
  {
    guard content > container, container > 0, track > 0 else { return nil }
    let ratio = container / content
    let length = max(minimumLength, track * ratio)
    let travel = max(0, track - length)
    let progress = min(1, max(0, offset / (content - container)))
    return (length, travel * progress)
  }

  /// Inverse of `thumb`: the content offset that places the thumb's leading edge at
  /// `position` along the track.
  static func offset(
    forThumbPosition position: CGFloat, track: CGFloat, content: CGFloat,
    container: CGFloat
  ) -> CGFloat {
    guard let geometry = thumb(track: track, content: content, container: container, offset: 0)
    else { return 0 }
    let travel = max(0, track - geometry.length)
    guard travel > 0 else { return 0 }
    let progress = min(1, max(0, position / travel))
    return progress * (content - container)
  }
}

extension View {
  func ottoScrollChrome(
    axis: Axis = .vertical,
    fade: CGFloat = 24,
    showsThumb: Bool = true,
    position: Binding<ScrollPosition>? = nil
  ) -> some View {
    modifier(
      OttoScrollChromeModifier(
        axis: axis, fadeSize: fade, showsThumb: showsThumb, position: position))
  }
}

private struct OttoScrollChromeModifier: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  let axis: Axis
  let fadeSize: CGFloat
  let showsThumb: Bool
  let position: Binding<ScrollPosition>?

  @State private var metrics = OttoScrollMetrics()
  @State private var hoveringArea = false
  @State private var hoveringTrack = false
  @State private var dragging = false
  @State private var recentlyScrolled = false
  @State private var scrollSettle: Task<Void, Never>?

  private var thumbVisible: Bool {
    showsThumb && (hoveringArea || recentlyScrolled || dragging)
      && (axis == .vertical ? metrics.verticalOverflow > 0 : metrics.horizontalOverflow > 0)
  }

  private var leadingFade: CGFloat {
    min(fadeSize, axis == .vertical ? metrics.offset.y : metrics.offset.x)
  }

  private var trailingFade: CGFloat {
    min(fadeSize, axis == .vertical ? metrics.remainingBelow : metrics.remainingAfter)
  }

  func body(content: Content) -> some View {
    content
      .scrollIndicators(.hidden)
      .onScrollGeometryChange(for: OttoScrollMetrics.self) { geometry in
        OttoScrollMetrics(
          offset: CGPoint(
            x: geometry.contentOffset.x + geometry.contentInsets.leading,
            y: geometry.contentOffset.y + geometry.contentInsets.top),
          content: geometry.contentSize,
          container: geometry.containerSize)
      } action: { _, next in
        let moved = next.offset != metrics.offset
        metrics = next
        if moved { noteScroll() }
      }
      .mask { fadeMask }
      .overlay(alignment: axis == .vertical ? .trailing : .bottom) {
        if showsThumb { track }
      }
      .onHover { hoveringArea = $0 }
  }

  private func noteScroll() {
    recentlyScrolled = true
    scrollSettle?.cancel()
    scrollSettle = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      recentlyScrolled = false
    }
  }

  /// The fade only masks the edge that has more to scroll; it collapses to nothing at the
  /// true start and end, so content is never dimmed where there is nothing beyond it.
  @ViewBuilder private var fadeMask: some View {
    if axis == .vertical {
      VStack(spacing: 0) {
        LinearGradient(
          colors: [.clear, .black], startPoint: .top, endPoint: .bottom
        )
        .frame(height: max(0, leadingFade))
        Color.black
        LinearGradient(
          colors: [.black, .clear], startPoint: .top, endPoint: .bottom
        )
        .frame(height: max(0, trailingFade))
      }
    } else {
      HStack(spacing: 0) {
        LinearGradient(
          colors: [.clear, .black], startPoint: .leading, endPoint: .trailing
        )
        .frame(width: max(0, leadingFade))
        Color.black
        LinearGradient(
          colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
        )
        .frame(width: max(0, trailingFade))
      }
    }
  }

  private var thumbStrong: Bool { hoveringTrack || dragging }

  /// A 10pt track holds the hit target; the thumb inside rests 4pt at 8% and grows to 6pt at
  /// 12% (16% while dragging). It shows at once and, on leaving, shrinks first and then fades
  /// so the retreat reads as deliberate.
  private var track: some View {
    GeometryReader { proxy in
      let trackLength = axis == .vertical ? proxy.size.height - 4 : proxy.size.width - 4
      let geometry = OttoScrollThumbGeometry.thumb(
        track: trackLength,
        content: axis == .vertical ? metrics.content.height : metrics.content.width,
        container: axis == .vertical ? metrics.container.height : metrics.container.width,
        offset: axis == .vertical ? metrics.offset.y : metrics.offset.x)
      if let geometry {
        let thickness: CGFloat = thumbStrong ? 6 : 4
        Capsule()
          .fill(palette.paper.opacity(dragging ? 0.28 : thumbStrong ? 0.20 : 0.12))
          .frame(
            width: axis == .vertical ? thickness : geometry.length,
            height: axis == .vertical ? geometry.length : thickness
          )
          .offset(
            x: axis == .vertical ? (10 - thickness) / 2 - 2 : geometry.position + 2,
            y: axis == .vertical ? geometry.position + 2 : (10 - thickness) / 2 - 2
          )
          .animation(motion.tint, value: thumbStrong)
          .animation(dragging ? nil : motion.enter(.fast), value: geometry.position)
          .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
              .onChanged { value in
                guard let position else { return }
                dragging = true
                let along = axis == .vertical ? value.location.y : value.location.x
                let target = OttoScrollThumbGeometry.offset(
                  forThumbPosition: along - geometry.length / 2, track: trackLength,
                  content: axis == .vertical ? metrics.content.height : metrics.content.width,
                  container: axis == .vertical
                    ? metrics.container.height : metrics.container.width)
                if axis == .vertical {
                  position.wrappedValue.scrollTo(y: target)
                } else {
                  position.wrappedValue.scrollTo(x: target)
                }
              }
              .onEnded { _ in dragging = false }
          )
      }
    }
    .frame(
      width: axis == .vertical ? 10 : nil,
      height: axis == .vertical ? nil : 10
    )
    .contentShape(Rectangle())
    .onHover { hoveringTrack = $0 }
    .opacity(thumbVisible ? 1 : 0)
    .animation(
      thumbVisible ? .easeOut(duration: 0.16) : .easeOut(duration: 0.12).delay(0.16),
      value: thumbVisible
    )
    .allowsHitTesting(thumbVisible && position != nil)
  }
}

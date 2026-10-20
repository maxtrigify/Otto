import SwiftUI

/// Lets a growing chat text box stop at a height and scroll, with a scroll bar, instead of
/// hiding the rest of a long message. The box hugs short text and stays pinned to the bottom
/// while typing so the caret stays in view.
private struct ComposerScroll: ViewModifier {
  let maxHeight: CGFloat
  @State private var contentHeight: CGFloat = 0

  func body(content: Content) -> some View {
    ScrollView(.vertical) {
      content
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(contentHeight > maxHeight ? .visible : .hidden)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
    .frame(height: min(max(contentHeight, 1), maxHeight))
  }
}

extension View {
  /// Pair with an unbounded `lineLimit` on a vertical `TextField`.
  func composerScroll(maxHeight: CGFloat) -> some View {
    modifier(ComposerScroll(maxHeight: maxHeight))
  }
}

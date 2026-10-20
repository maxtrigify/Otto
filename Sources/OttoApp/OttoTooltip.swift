import SwiftUI

/// An in-window tooltip: 200ms of hover intent, then a small plate that fades in with a 4pt
/// slide from the trigger on the fast tier and leaves on its exit tween. Replaces `.help`
/// on chrome where the system bubble arrives late and unstyled; the text still reaches
/// assistive technology as the accessibility hint.
extension View {
  func ottoTooltip(_ text: String, edge: Edge = .bottom, delay: Double = 0.2) -> some View {
    modifier(OttoTooltipModifier(text: text, edge: edge, delay: delay))
  }
}

private struct OttoTooltipModifier: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  let text: String
  let edge: Edge
  let delay: Double
  @State private var shown = false
  @State private var intent: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .accessibilityHint(text)
      .onHover { hovering in
        intent?.cancel()
        if hovering {
          intent = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            shown = true
          }
        } else {
          shown = false
        }
      }
      .overlay(alignment: edge == .top ? .top : .bottom) {
        if shown {
          Text(text)
            .font(.ottoDisplay(11).weight(.medium))
            .foregroundStyle(palette.paper)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.raised.opacity(0.98), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.paper.opacity(0.12)))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .alignmentGuide(edge == .top ? .top : .bottom) { dimensions in
              edge == .top ? dimensions[.bottom] + 8 : dimensions[.top] - 8
            }
            .transition(
              .ottoPopup(from: edge == .top ? .bottom : .top, reduceMotion: motion.reduceMotion)
            )
            .allowsHitTesting(false)
            .zIndex(10)
        }
      }
      .animation(motion.presence(.fast, isPresented: shown), value: shown)
  }
}

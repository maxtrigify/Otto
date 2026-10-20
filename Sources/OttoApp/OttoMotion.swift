import SwiftUI

/// The app's motion vocabulary, after Fluid Functionalism's three spring tiers. Everything
/// enters on a spring and leaves on a plain tween one tier quicker, so a dismissal reads as
/// crisp and final instead of replaying the entrance backwards. Never hand-write a duration
/// in a view — reach for a tier, and let reduced motion drop the travel through
/// `OttoMotionResolver`.
///
///   fast      hover, focus rings, fades, small toggles
///   moderate  dropdowns, tabs, switches, sidebar, selection travel — critically damped
///   slow      dialogs, drawers, question cards, thinking steps
enum OttoMotion {
  struct Tier: Equatable, Sendable {
    let duration: Double
    let bounce: Double
    let exitDuration: Double

    var enter: Animation { .spring(duration: duration, bounce: bounce) }
    var exit: Animation { .easeOut(duration: exitDuration) }

    // Leading-dot spelling at call sites: `motion.enter(.moderate)`.
    static var fast: Tier { OttoMotion.fast }
    static var moderate: Tier { OttoMotion.moderate }
    static var slow: Tier { OttoMotion.slow }
  }

  static let fast = Tier(duration: 0.08, bounce: 0, exitDuration: 0.06)
  static let moderate = Tier(duration: 0.16, bounce: 0, exitDuration: 0.12)
  static let slow = Tier(duration: 0.24, bounce: 0.12, exitDuration: 0.16)

  /// Opacity fades ride on every tier at the same short length.
  static let fadeDuration = 0.08
  static var fade: Animation { .easeOut(duration: fadeDuration) }
  /// Colour, weight, and stroke changes.
  static var tint: Animation { .easeOut(duration: 0.08) }

  /// The same tiers for web surfaces the app hosts (widgets, bundled apps), as CSS custom
  /// properties, so an agent-authored widget can move at the app's pace.
  static let cssTokens = """
    :root{--otto-motion-fast:80ms;--otto-motion-fast-exit:60ms;\
    --otto-motion-moderate:160ms;--otto-motion-moderate-exit:120ms;\
    --otto-motion-slow:240ms;--otto-motion-slow-exit:160ms;\
    --otto-motion-fade:80ms;--otto-motion-ease:cubic-bezier(0.23,1,0.32,1)}
    """
}

/// Resolves a tier against the OS reduced-motion setting: travel drops out, fades remain.
struct OttoMotionResolver: Equatable {
  let reduceMotion: Bool

  func enter(_ tier: OttoMotion.Tier) -> Animation? { reduceMotion ? nil : tier.enter }
  func exit(_ tier: OttoMotion.Tier) -> Animation? { reduceMotion ? nil : tier.exit }

  /// Presence-driven state: the spring on the way in, the tween on the way out.
  func presence(_ tier: OttoMotion.Tier, isPresented: Bool) -> Animation? {
    isPresented ? enter(tier) : exit(tier)
  }

  /// A fade survives reduced motion; it is the one thing that keeps a state change legible.
  var fade: Animation { OttoMotion.fade }
  var tint: Animation { OttoMotion.tint }
}

private struct OttoMotionKey: EnvironmentKey {
  static let defaultValue = OttoMotionResolver(reduceMotion: false)
}

extension EnvironmentValues {
  /// Tier resolver already gated on the accessibility setting for this environment.
  var ottoMotion: OttoMotionResolver {
    OttoMotionResolver(reduceMotion: accessibilityReduceMotion)
  }
}

// MARK: - Transitions

private struct OttoPopupTransitionModifier: ViewModifier {
  let isHidden: Bool
  let edge: Edge
  let travel: CGFloat

  private var anchor: UnitPoint {
    switch edge {
    case .top: .top
    case .bottom: .bottom
    case .leading: .leading
    case .trailing: .trailing
    }
  }

  private var offset: CGSize {
    guard isHidden else { return .zero }
    switch edge {
    case .top: return CGSize(width: 0, height: -travel)
    case .bottom: return CGSize(width: 0, height: travel)
    case .leading: return CGSize(width: -travel, height: 0)
    case .trailing: return CGSize(width: travel, height: 0)
    }
  }

  func body(content: Content) -> some View {
    content
      .opacity(isHidden ? 0 : 1)
      .scaleEffect(
        x: edge == .top || edge == .bottom ? 1 : (isHidden ? 0.96 : 1),
        y: edge == .top || edge == .bottom ? (isHidden ? 0.96 : 1) : 1,
        anchor: anchor
      )
      .offset(offset)
  }
}

private struct OttoDialogTransitionModifier: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content
      .opacity(isHidden ? 0 : 1)
      .scaleEffect(isHidden ? 0.97 : 1)
  }
}

extension AnyTransition {
  /// Popup choreography shared by flyouts, menus, and pickers: fade, a 4pt slide out of the
  /// edge it is anchored to, and a slight grow from that edge. Fast in, fast exit out.
  static func ottoPopup(from edge: Edge = .top, reduceMotion: Bool = false) -> AnyTransition {
    guard !reduceMotion else {
      return .opacity.animation(OttoMotion.fade)
    }
    return .asymmetric(
      insertion: .modifier(
        active: OttoPopupTransitionModifier(isHidden: true, edge: edge, travel: 4),
        identity: OttoPopupTransitionModifier(isHidden: false, edge: edge, travel: 4)
      ).animation(OttoMotion.fast.enter),
      removal: .modifier(
        active: OttoPopupTransitionModifier(isHidden: true, edge: edge, travel: 4),
        identity: OttoPopupTransitionModifier(isHidden: false, edge: edge, travel: 4)
      ).animation(OttoMotion.fast.exit)
    )
  }

  /// Dialog choreography: fade with a 0.97 scale on the slow spring, out on its exit tween.
  static func ottoDialog(reduceMotion: Bool = false) -> AnyTransition {
    guard !reduceMotion else {
      return .opacity.animation(OttoMotion.fade)
    }
    return .asymmetric(
      insertion: .modifier(
        active: OttoDialogTransitionModifier(isHidden: true),
        identity: OttoDialogTransitionModifier(isHidden: false)
      ).animation(OttoMotion.slow.enter),
      removal: .modifier(
        active: OttoDialogTransitionModifier(isHidden: true),
        identity: OttoDialogTransitionModifier(isHidden: false)
      ).animation(OttoMotion.slow.exit)
    )
  }

  /// A row or panel unfolding beneath its header: fade plus a short slide from the top.
  static func ottoUnfold(reduceMotion: Bool = false) -> AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
  }
}

// MARK: - Weight-stable labels

/// A label that reads semibold when active and regular otherwise without moving anything:
/// an invisible semibold twin reserves the width, so a row never reflows as it becomes
/// current. The weight change itself rides the tint animation.
struct OttoWeightStableText: View {
  let text: String
  let font: Font
  let activeFont: Font
  let active: Bool
  var activeColor: Color
  var restingColor: Color

  init(
    _ text: String, size: CGFloat, active: Bool,
    activeWeight: Font.Weight = .semibold, restingWeight: Font.Weight = .regular,
    activeColor: Color, restingColor: Color
  ) {
    self.text = text
    self.font = .ottoDisplay(size).weight(restingWeight)
    self.activeFont = .ottoDisplay(size).weight(activeWeight)
    self.active = active
    self.activeColor = activeColor
    self.restingColor = restingColor
  }

  var body: some View {
    Text(text)
      .font(activeFont)
      .lineLimit(1)
      .truncationMode(.tail)
      .hidden()
      .overlay(alignment: .leading) {
        Text(text)
          .font(active ? activeFont : font)
          .foregroundStyle(active ? activeColor : restingColor)
          .lineLimit(1)
          .truncationMode(.tail)
          .animation(OttoMotion.tint, value: active)
      }
      .accessibilityLabel(text)
  }
}

import SwiftUI

/// Chrome and toolbar buttons: a ghost that tints on hover and visibly sinks on press. The
/// hover fill is the surface system's +6% wash, the press adds an inset ring so the button
/// reads as pushed into the plane rather than merely darker. Colour changes run on the tint
/// animation; the sink itself is the fast tier.
struct OttoChromeButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = 7
  var hoverOpacity: Double = 0.06
  var pressOpacity: Double = 0.10
  var sinks = true

  func makeBody(configuration: Configuration) -> some View {
    StyledLabel(configuration: configuration, style: self)
  }

  struct StyledLabel: View {
    @Environment(\.ottoPalette) private var palette
    @Environment(\.ottoMotion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let style: OttoChromeButtonStyle
    @State private var hovering = false

    private var fillOpacity: Double {
      guard isEnabled else { return 0 }
      if configuration.isPressed { return style.pressOpacity }
      return hovering ? style.hoverOpacity : 0
    }

    var body: some View {
      configuration.label
        .background(
          palette.paper.opacity(fillOpacity),
          in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .strokeBorder(
              palette.paper.opacity(configuration.isPressed && isEnabled ? 0.10 : 0),
              lineWidth: 1
            )
        }
        .scaleEffect(style.sinks && configuration.isPressed ? 0.985 : 1)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(motion.tint, value: fillOpacity)
        .animation(motion.enter(OttoMotion.fast), value: configuration.isPressed)
        .onHover { hovering = $0 }
    }
  }
}

/// The filled call to action: signal fill, a lighter hover mix, and the same press sink.
struct OttoPrimaryButtonStyle: ButtonStyle {
  var cornerRadius: CGFloat = 8

  func makeBody(configuration: Configuration) -> some View {
    StyledLabel(configuration: configuration, cornerRadius: cornerRadius)
  }

  struct StyledLabel: View {
    @Environment(\.ottoPalette) private var palette
    @Environment(\.ottoMotion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let cornerRadius: CGFloat
    @State private var hovering = false

    /// A lighter mix while hovered; nothing while pressed or disabled.
    private var hoverWashOpacity: Double {
      guard isEnabled, !configuration.isPressed, hovering else { return 0 }
      return 0.10
    }

    var body: some View {
      configuration.label
        .foregroundStyle(isEnabled ? palette.onSignal : palette.muted)
        .background(
          isEnabled ? palette.signal : palette.paper.opacity(0.06),
          in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(palette.paper.opacity(hoverWashOpacity))
            .allowsHitTesting(false)
        }
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
              palette.ink.opacity(configuration.isPressed && isEnabled ? 0.18 : 0), lineWidth: 1)
        }
        .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
        .animation(motion.tint, value: hovering)
        .animation(motion.tint, value: isEnabled)
        .animation(motion.enter(OttoMotion.fast), value: configuration.isPressed)
        .onHover { hovering = $0 }
    }
  }
}

extension ButtonStyle where Self == OttoChromeButtonStyle {
  /// Ghost chrome button with hover wash and press sink.
  static var ottoChrome: OttoChromeButtonStyle { OttoChromeButtonStyle() }
  static func ottoChrome(cornerRadius: CGFloat, sinks: Bool = true) -> OttoChromeButtonStyle {
    OttoChromeButtonStyle(cornerRadius: cornerRadius, sinks: sinks)
  }
}

extension ButtonStyle where Self == OttoPrimaryButtonStyle {
  static var ottoPrimary: OttoPrimaryButtonStyle { OttoPrimaryButtonStyle() }
  static func ottoPrimary(cornerRadius: CGFloat) -> OttoPrimaryButtonStyle {
    OttoPrimaryButtonStyle(cornerRadius: cornerRadius)
  }
}

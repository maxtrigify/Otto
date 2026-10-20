import SwiftUI

/// A switch whose thumb travels on the moderate spring and whose track tints on the fast
/// fade, after Fluid Functionalism's Switch. Sized for canvas panels rather than the
/// Settings window, where the system control stays.
struct OttoSwitchToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    StyledLabel(configuration: configuration)
  }

  struct StyledLabel: View {
    @Environment(\.ottoPalette) private var palette
    @Environment(\.ottoMotion) private var motion
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ToggleStyleConfiguration
    @State private var hovering = false

    private let trackWidth: CGFloat = 30
    private let trackHeight: CGFloat = 18
    private let thumb: CGFloat = 14

    var body: some View {
      Button {
        withAnimation(motion.enter(.moderate)) { configuration.isOn.toggle() }
      } label: {
        HStack(spacing: 8) {
          configuration.label
          Spacer(minLength: 0)
          ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
              .fill(configuration.isOn ? palette.signal : palette.paper.opacity(0.14))
              .overlay(
                Capsule().strokeBorder(palette.paper.opacity(hovering ? 0.16 : 0.08), lineWidth: 1)
              )
              .animation(motion.tint, value: configuration.isOn)
              .animation(motion.tint, value: hovering)
            Circle()
              .fill(configuration.isOn ? palette.onSignal : palette.paper.opacity(0.9))
              .frame(width: thumb, height: thumb)
              .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
              .padding(2)
          }
          .frame(width: trackWidth, height: trackHeight)
          .contentShape(Capsule())
        }
        .opacity(isEnabled ? 1 : 0.5)
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .accessibilityAddTraits(.isToggle)
      .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
  }
}

extension ToggleStyle where Self == OttoSwitchToggleStyle {
  static var ottoSwitch: OttoSwitchToggleStyle { OttoSwitchToggleStyle() }
}

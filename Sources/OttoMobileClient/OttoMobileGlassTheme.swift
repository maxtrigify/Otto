#if canImport(SwiftUI)
  import SwiftUI

  #if canImport(UIKit)
    import UIKit
  #endif

  /// Shared mobile material language derived from Otto's Glasswing and Nightglass desktop themes.
  /// The backdrop supplies colour and depth; content remains on local, contrast-preserving glass.
  public enum OttoMobileGlassPalette {
    #if canImport(UIKit)
      public static let accent = Color(
        uiColor: UIColor { traits in
          traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.67, green: 0.68, blue: 0.96, alpha: 1)
            : UIColor(red: 0.36, green: 0.30, blue: 0.62, alpha: 1)
        })
    #else
      public static let accent = Color(red: 0.48, green: 0.44, blue: 0.86)
    #endif

    public static let success = Color(red: 0.25, green: 0.66, blue: 0.52)
    public static let warning = Color(red: 0.90, green: 0.62, blue: 0.25)
    public static let danger = Color(red: 0.92, green: 0.32, blue: 0.38)
    public static let cyan = Color(red: 0.27, green: 0.72, blue: 0.86)
  }

  public struct OttoMobileGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init() {}

    public var body: some View {
      GeometryReader { proxy in
        ZStack {
          LinearGradient(
            colors: colorScheme == .dark
              ? [
                Color(red: 0.07, green: 0.07, blue: 0.09),
                Color(red: 0.10, green: 0.10, blue: 0.13),
                Color(red: 0.07, green: 0.08, blue: 0.10),
              ]
              : [
                Color(red: 0.92, green: 0.95, blue: 1.0),
                Color(red: 0.97, green: 0.94, blue: 1.0),
                Color(red: 0.90, green: 0.97, blue: 0.98),
              ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          if !reduceTransparency {
            Circle()
              .fill(OttoMobileGlassPalette.accent.opacity(colorScheme == .dark ? 0.18 : 0.24))
              .frame(width: proxy.size.width * 1.12)
              .blur(radius: 72)
              .offset(x: proxy.size.width * 0.36, y: -proxy.size.height * 0.34)

            Circle()
              .fill(OttoMobileGlassPalette.cyan.opacity(colorScheme == .dark ? 0.12 : 0.20))
              .frame(width: proxy.size.width * 0.92)
              .blur(radius: 84)
              .offset(x: -proxy.size.width * 0.42, y: proxy.size.height * 0.30)

            Circle()
              .fill(OttoMobileGlassPalette.danger.opacity(colorScheme == .dark ? 0.04 : 0.10))
              .frame(width: proxy.size.width * 0.62)
              .blur(radius: 76)
              .offset(x: proxy.size.width * 0.34, y: proxy.size.height * 0.44)

            Rectangle()
              .fill(.ultraThinMaterial)
              .opacity(colorScheme == .dark ? 0.12 : 0.20)
          }
        }
      }
      .ignoresSafeArea()
      .accessibilityHidden(true)
    }
  }

  extension View {
    /// Uses native Liquid Glass on iOS 26 and a material-backed equivalent on earlier systems.
    @ViewBuilder
    public func ottoMobileGlassSurface(
      cornerRadius: CGFloat = 24,
      tint: Color = OttoMobileGlassPalette.accent,
      interactive: Bool = false
    ) -> some View {
      modifier(
        OttoMobileGlassSurfaceModifier(
          cornerRadius: cornerRadius,
          tint: tint,
          interactive: interactive
        ))
    }
  }

  private struct OttoMobileGlassSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    let tint: Color
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      if reduceTransparency {
        content
          .background(
            colorScheme == .dark
              ? Color(red: 0.10, green: 0.10, blue: 0.14)
              : Color(red: 0.96, green: 0.97, blue: 0.99),
            in: shape
          )
          .overlay(shape.stroke(.primary.opacity(0.12), lineWidth: 1))
      } else if #available(iOS 26.0, macOS 26.0, *) {
        content
          .glassEffect(.regular.tint(tint.opacity(0.10)).interactive(interactive), in: shape)
          .overlay(shape.stroke(.white.opacity(colorScheme == .dark ? 0.12 : 0.58), lineWidth: 0.8))
          .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 22, y: 10)
      } else {
        content
          .background(.ultraThinMaterial, in: shape)
          .background(tint.opacity(colorScheme == .dark ? 0.10 : 0.06), in: shape)
          .overlay(shape.stroke(.white.opacity(colorScheme == .dark ? 0.18 : 0.56), lineWidth: 0.8))
          .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.09), radius: 20, y: 9)
      }
    }
  }
#endif

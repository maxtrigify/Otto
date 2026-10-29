import CoreText
import OttoModels
import SwiftUI

// Equatable so SwiftUI can prove the environment palette unchanged instead of invalidating
// every view that reads \.ottoPalette on each WorkspaceView body pass.
struct OttoPalette: Equatable {
  let ink: Color
  let surface: Color
  let raised: Color
  let paper: Color
  let muted: Color
  let signal: Color
  /// Readable accent text on question cards, including low-contrast custom themes.
  let choiceAccent: Color
  let onSignal: Color
  let amber: Color
  let red: Color
  let cyan: Color
  /// Text on a `signal` → `cyan` gradient fill; never a hard-coded white.
  let onAccentGradient: Color
  /// Header bands that float over artwork: a theme-ink tint dense enough that
  /// `chromeForeground` keeps body contrast over any backdrop pixel, light or dark.
  let chromeBand: Color
  /// Text and glyphs on `chromeBand`. Follows the theme, so a light theme gets dark header
  /// controls instead of white ones on a pale strip.
  let chromeForeground: Color
  /// The exact text/background pair the embedded terminal's contrast filter judges against.
  let terminalForeground: ThemeColor
  let terminalBackground: ThemeColor
  let nodeOpacity: Double
  let surfaceMaterial: OttoSurfaceMaterial
  /// Fill for node shells that sit directly over the canvas backdrop. Matte and
  /// window-glass themes composite the surface color at the user's adjustable
  /// transparency; every other material keeps the opaque surface, so interior
  /// panels never stack alpha.
  let nodeSurface: Color
  /// Set when a whole surface (Chat) draws one tint over theme artwork. Its inner panes then
  /// behave like a translucent material instead of each painting an opaque plane.
  private(set) var overArtwork = false

  /// The one tint laid over theme artwork on Home and Chat. Light themes keep it faint so the
  /// photo stays crisp instead of turning milky; panels carry their own solid surfaces.
  var artworkTint: Color { .clear }

  /// A soft halo in the opposite tone keeps text readable straight on a photo without
  /// washing the photo itself.
  var textHalo: Color { ink.opacity(0.55) }

  /// The same palette for views laid over theme artwork as one continuous surface.
  func overThemeArtwork() -> OttoPalette {
    var copy = self
    copy.overArtwork = true
    return copy
  }

  /// Translucent materials composite their surface over the backdrop instead of painting an
  /// opaque plane: window glass through the system blur, matte as flat colour at the user's
  /// transparency. Every derived plane below keys off this so interior panels never stack a
  /// second translucent layer on top of the one the shell already provides.
  private var isTranslucentMaterial: Bool {
    overArtwork || surfaceMaterial == .windowGlass || surfaceMaterial == .matte
  }

  /// Large workspace planes must not repaint the desktop acrylic. Cards can add a local
  /// reading tint, but window-sized roots remain nearly clear so the wallpaper still reads.
  /// Matte roots stay near-clear for the same reason: the node shell or the chat card is the
  /// one matte layer text reads on, and a matte root underneath it would compound to opaque.
  var workspaceSurface: Color {
    isTranslucentMaterial ? surface.opacity(0.06) : nodeSurface
  }

  /// A modest pane tint for headers, inspectors, and split views inside a glass window.
  var paneSurface: Color {
    // Over a clear photo, panes are solid reading surfaces rather than a faint wash.
    if overArtwork { return surface.opacity(0.14) }
    return isTranslucentMaterial ? surface.opacity(0.14) : surface
  }

  /// The chat surface's floating conversation card. On matte themes it is the single
  /// translucent layer the transcript reads on, composited at the theme's node opacity;
  /// every other material keeps the pane tint (glass adds its own system material there).
  var chatCardSurface: Color {
    surfaceMaterial == .matte && !overArtwork ? nodeSurface : paneSurface
  }

  /// Sidebars are intentionally a little denser than the main acrylic sheet, matching the
  /// familiar macOS hierarchy without turning the rail into an opaque slab.
  var sidebarSurface: Color {
    surfaceMaterial == .windowGlass ? ink.opacity(0.20) : ink.opacity(0.76)
  }

  /// The transcript uses a very shallow tonal drift on acrylic. Its former opaque surface-to-ink
  /// gradient covered the desktop even when every surrounding Bots pane was transparent.
  var conversationTop: Color {
    isTranslucentMaterial ? surface.opacity(0.04) : surface
  }

  var conversationBottom: Color {
    isTranslucentMaterial ? ink.opacity(0.12) : ink.opacity(0.36)
  }

  init(theme: OttoThemeDefinition, matteOpacity: Double? = nil) {
    ink = Color(theme.ink)
    surface = Color(theme.surface)
    raised = Color(theme.raised)
    paper = Color(theme.paper)
    muted = Color(theme.muted)
    signal = Color(theme.signal)
    choiceAccent = Color(Self.choiceAccentColor(for: theme))
    onSignal = Color(Self.signalForegroundColor(for: theme))
    amber = Color(theme.amber)
    red = Color(theme.red)
    cyan = Color(theme.cyan)
    onAccentGradient = Color(theme.onAccentGradient)
    chromeBand = Color(theme.ink).opacity(theme.chromeBandOpacity)
    chromeForeground = Color(theme.chromeForeground)
    terminalForeground = theme.paper
    terminalBackground = theme.ink
    nodeOpacity = theme.nodeOpacity
    surfaceMaterial = theme.resolvedSurfaceMaterial
    switch surfaceMaterial {
    case .matte:
      nodeSurface = Color(theme.surface).opacity(
        OttoMatteTransparency.resolve(preference: matteOpacity, themeDefault: theme.nodeOpacity))
    case .windowGlass:
      // Glass has its own designed density. Reusing Velvet's persisted matte preference made a
      // previously-solid Velvet setting silently turn the acrylic themes opaque.
      nodeSurface = Color(theme.surface).opacity(
        OttoWindowGlassTransparency.clamped(theme.nodeOpacity))
    default:
      nodeSurface = Color(theme.surface)
    }
  }

  static func choiceAccentColor(for theme: OttoThemeDefinition) -> ThemeColor {
    theme.signal.contrastRatio(with: theme.raised) >= 4.5 ? theme.signal : theme.paper
  }

  static func signalForegroundColor(for theme: OttoThemeDefinition) -> ThemeColor {
    if theme.ink.contrastRatio(with: theme.signal) >= 4.5 { return theme.ink }
    let black = ThemeColor(red: 0, green: 0, blue: 0)
    let white = ThemeColor(red: 1, green: 1, blue: 1)
    return black.contrastRatio(with: theme.signal) > white.contrastRatio(with: theme.signal)
      ? black : white
  }

  static let fieldNotes = OttoPalette(theme: OttoThemeCatalog.fieldNotes)
}

private struct OttoPaletteKey: EnvironmentKey {
  static let defaultValue = OttoPalette.fieldNotes
}

extension EnvironmentValues {
  var ottoPalette: OttoPalette {
    get { self[OttoPaletteKey.self] }
    set { self[OttoPaletteKey.self] = newValue }
  }
}

extension Color {
  fileprivate init(_ color: ThemeColor) {
    self.init(red: color.red, green: color.green, blue: color.blue)
  }
}

/// Inter ships inside the app so every Mac renders the same face, whatever is installed.
enum OttoFonts {
  static let registered: Bool = {
    guard let url = Bundle.module.url(forResource: "Fonts/InterVariable", withExtension: "ttf")
    else { return false }
    var error: Unmanaged<CFError>?
    // Already-registered is fine: tests and previews may load the bundle more than once.
    return CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
      || (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains("Inter Variable")
        == true
  }()
}

extension Font {
  static func ottoDisplay(_ size: CGFloat) -> Font {
    _ = OttoFonts.registered
    return .custom("Inter Variable", size: size, relativeTo: .body).weight(.regular)
  }

  /// Interface labels that used to be tiny tracked monospace. Inter reads smaller than SF Mono
  /// caps at the same point size, so labels get a small lift; heavy weights soften to semibold.
  static func ottoLabel(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let softened: Font.Weight =
      switch weight {
      case .black, .heavy, .bold: .semibold
      case .semibold: .medium
      default: weight
      }
    return ottoDisplay(size + 2).weight(softened)
  }

  static func ottoMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .custom("SF Mono", size: size, relativeTo: .body).weight(weight)
  }
}

/// See-through frosted cards: the photo shows through, blurred, and the system material
/// follows the window's light or dark appearance so text on it is always black or white
/// as needed.
/// How dark the smoked glass is. Bright photos need more smoke so white text stays readable;
/// Home sets this from the theme.
struct OttoGlassSmokeKey: EnvironmentKey {
  static let defaultValue: Double = 0.34
}

extension EnvironmentValues {
  var ottoGlassSmoke: Double {
    get { self[OttoGlassSmokeKey.self] }
    set { self[OttoGlassSmokeKey.self] = newValue }
  }
}

/// Light themes without artwork use a light plate instead of smoked glass.
struct OttoGlassLightKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var ottoGlassLight: Bool {
    get { self[OttoGlassLightKey.self] }
    set { self[OttoGlassLightKey.self] = newValue }
  }
}

private struct OttoGlassCard: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoGlassSmoke) private var smoke
  @Environment(\.ottoGlassLight) private var lightGlass
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let cornerRadius: CGFloat
  let tint: Double?

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .background {
        if reduceTransparency {
          shape.fill(palette.surface)
        } else if lightGlass {
          shape.fill(palette.raised.opacity(0.96))
        } else {
          // Smoked glass: a dark frosted plate the photo shows through.
          ZStack {
            shape.fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            shape.fill(Color.black.opacity(tint ?? smoke))
          }
        }
      }
      .ottoElevated(cornerRadius: cornerRadius)
  }
}

extension View {
  func ottoGlass(cornerRadius: CGFloat = 14, tint: Double? = nil) -> some View {
    modifier(OttoGlassCard(cornerRadius: cornerRadius, tint: tint))
  }
}

extension Font {
  /// Small uppercase mono labels for dates, counts, section names and metadata. Pair with
  /// `.tracking(2.4)` and uppercase text; never use it for body copy.
  static var ottoMicro: Font { .ottoMono(9.5, weight: .medium) }
}

/// How high a surface floats. Cards sit just above the page; modals float well above it.
enum OttoElevation {
  case card, modal
}

/// The devl.dev surface finish: a hairline border, a faint inset highlight along the top
/// edge, and layered shadows (a tight contact shadow plus a soft, wide one).
private struct OttoElevatedSurface: ViewModifier {
  @Environment(\.ottoPalette) private var palette
  let cornerRadius: CGFloat
  let depth: OttoElevation

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content
      .overlay(shape.strokeBorder(palette.paper.opacity(0.10), lineWidth: 1))
      .overlay(alignment: .top) {
        shape
          .strokeBorder(
            LinearGradient(
              colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .center),
            lineWidth: 1
          )
          .allowsHitTesting(false)
      }
      .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
      .shadow(
        color: .black.opacity(depth == .modal ? 0.22 : 0.14), radius: depth == .modal ? 16 : 10,
        y: depth == .modal ? 12 : 6
      )
      .shadow(
        color: .black.opacity(depth == .modal ? 0.20 : 0.08), radius: depth == .modal ? 32 : 20,
        y: depth == .modal ? 28 : 14)
  }
}

extension View {
  func ottoElevated(cornerRadius: CGFloat, depth: OttoElevation = .card) -> some View {
    modifier(OttoElevatedSurface(cornerRadius: cornerRadius, depth: depth))
  }
}

import Foundation

public struct ThemeColor: Codable, Equatable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public func contrastRatio(with other: ThemeColor) -> Double {
    let light = max(relativeLuminance, other.relativeLuminance)
    let dark = min(relativeLuminance, other.relativeLuminance)
    return (light + 0.05) / (dark + 0.05)
  }

  public var isLight: Bool { relativeLuminance > 0.4 }

  /// This color painted at `opacity` over an opaque `base`, blended per sRGB channel — the
  /// same compositing a scrim or translucent surface performs on screen.
  public func blended(over base: ThemeColor, opacity: Double) -> ThemeColor {
    let alpha = min(max(opacity, 0), 1)
    return ThemeColor(
      red: red * alpha + base.red * (1 - alpha),
      green: green * alpha + base.green * (1 - alpha),
      blue: blue * alpha + base.blue * (1 - alpha)
    )
  }

  /// WCAG relative luminance, exposed so backdrop artwork can be audited against the
  /// theme compositing contract.
  public var luminance: Double { relativeLuminance }

  private var relativeLuminance: Double {
    func channel(_ value: Double) -> Double {
      value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }
}

public enum OttoSurfaceMaterial: String, Codable, Sendable {
  case opaque
  case glassLight = "glass-light"
  case glassDark = "glass-dark"
  /// Translucent flat color with no gloss or specular treatment; node shells composite
  /// over the backdrop at a user-adjustable opacity (see `OttoMatteTransparency`).
  case matte
  /// The window itself is transparent: the user's desktop shows through a behind-window
  /// system blur, frosted by a surface-toned scrim. The wallpaper is unbounded (any pixel
  /// may be pure white or pure black), so the frost — not an artwork luminance bound —
  /// carries the whole legibility contract. Node shells respect `OttoMatteTransparency`.
  case windowGlass = "window-glass"
}

public struct OttoThemeDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var version: Int
  public var ink: ThemeColor
  public var surface: ThemeColor
  public var raised: ThemeColor
  public var paper: ThemeColor
  public var muted: ThemeColor
  public var signal: ThemeColor
  public var amber: ThemeColor
  public var red: ThemeColor
  public var cyan: ThemeColor
  public var traceStyle: String
  public var nodeOpacity: Double
  /// Bundle asset ("aurora.mov", "aurora.heic") or a built-in procedural scene name ("aurora").
  public var backgroundAsset: String?
  public var surfaceMaterial: String

  public var resolvedSurfaceMaterial: OttoSurfaceMaterial {
    OttoSurfaceMaterial(rawValue: surfaceMaterial) ?? .opaque
  }

  /// Light themes invert the ink/paper relationship: ink becomes a light canvas
  /// and paper a dark text color. Drives system chrome (sheets, menus) appearance.
  public var isLightAppearance: Bool { ink.isLight }

  // MARK: Backdrop compositing contract

  /// The weakest stop of the ink scrim the app paints over an animated or procedural
  /// backdrop. Text drawn straight over the backdrop is guaranteed legible only through
  /// this scrim, so the value is policy, not styling — the theme tests prove the contract
  /// and `ThemeBackgroundView` must not paint less than this anywhere.
  public var scrimFloorOpacity: Double {
    switch resolvedSurfaceMaterial {
    case .glassLight: 0.30
    // Window glass is wallpaper-first acrylic. Text sits on local material-backed surfaces;
    // the full-window wash exists only to unify the desktop colours, not to make the desktop
    // itself carry a text-contrast guarantee.
    case .windowGlass: isLightAppearance ? 0.05 : 0.08
    default: 0.42
    }
  }

  /// The surface-equivalent tint the behind-window system blur material is assumed to
  /// contribute for `windowGlass` themes, on top of `scrimFloorOpacity`'s frost. AppKit
  /// doesn't expose the material's compositing, so this is a documented conservative
  /// assumption (the appearance-forced HUD material tints well past this even before its
  /// blur averages the wallpaper); the theme tests judge glass contrast through this tint
  /// plus the frost, which is why the frost alone can stay sheer.
  public static let windowGlassMaterialTintOpacity = 0.10

  /// A card inside window glass gets a second, local system material. This is deliberately
  /// stronger than the base sheet: wallpaper structure remains visible across the window while
  /// dense chat and terminal content gets a calm reading plane only where it needs one.
  public static let windowGlassPanelMaterialTintOpacity = 0.5

  /// What backdrop artwork is allowed to contain, expressed as WCAG relative luminance.
  ///
  /// A video or painting can hold any pixel, so legibility over "any frame" is impossible
  /// to promise with a fixed scrim; instead the theme commits to a bound on its artwork and
  /// the scrim is sized for that bound. Dark-scrim themes cap how *bright* large regions may
  /// be; light-scrim themes cap how *dark* they may be. Asset audits in the theme tests
  /// measure shipped art against these numbers — exceeding them is the white-text-on-bright-
  /// video bug class, caught at test time instead of in production.
  public var backdropLuminanceBound: Double {
    switch resolvedSurfaceMaterial {
    case .glassLight: 0.02
    // The desktop wallpaper is not ours to audit — assume the worst pixel outright.
    case .windowGlass: isLightAppearance ? 0.0 : 1.0
    default: 0.70
    }
  }

  /// The strongest stop of the scrim gradient (its bottom edge, where the persistent HUD
  /// sits). Same contract status as `scrimFloorOpacity`.
  public var scrimDeepOpacity: Double {
    // Window glass keeps the deep stop airy — a +0.28 ramp reads as a dimmed lower half,
    // defeating the see-through-window identity the material exists for.
    scrimFloorOpacity + (resolvedSurfaceMaterial == .windowGlass ? 0.07 : 0.28)
  }

  /// The brightest (dark scrim) or darkest (light scrim) surface an in-contract backdrop
  /// pixel can present through the scrim at `scrimOpacity` — the surface text contrast is
  /// judged against.
  public func worstCaseScrimmedBackdrop(scrimOpacity: Double) -> ThemeColor {
    let bound = backdropLuminanceBound
    // A uniform gray at the bound's luminance: invert the sRGB transfer curve per channel.
    let channel = bound <= 0.0031308 ? bound * 12.92 : 1.055 * pow(bound, 1 / 2.4) - 0.055
    let extreme = ThemeColor(red: channel, green: channel, blue: channel)
    guard resolvedSurfaceMaterial == .windowGlass else {
      return ink.blended(over: extreme, opacity: scrimOpacity)
    }
    // Window glass frosts with the surface tone: unlike an ink scrim it can *lighten* a
    // black wallpaper, which a light-appearance glass theme needs for dark text to hold.
    // The system blur material sits between the wallpaper and the frost and is credited
    // with its assumed tint, so the frost itself can stay sheer.
    let materialTinted = surface.blended(
      over: extreme, opacity: Self.windowGlassMaterialTintOpacity)
    return surface.blended(over: materialTinted, opacity: scrimOpacity)
  }

  public init(
    id: String, displayName: String, version: Int,
    ink: ThemeColor, surface: ThemeColor, raised: ThemeColor, paper: ThemeColor,
    muted: ThemeColor, signal: ThemeColor, amber: ThemeColor, red: ThemeColor, cyan: ThemeColor,
    traceStyle: String, nodeOpacity: Double,
    backgroundAsset: String? = nil, surfaceMaterial: String = OttoSurfaceMaterial.opaque.rawValue
  ) {
    self.id = id
    self.displayName = displayName
    self.version = version
    self.ink = ink
    self.surface = surface
    self.raised = raised
    self.paper = paper
    self.muted = muted
    self.signal = signal
    self.amber = amber
    self.red = red
    self.cyan = cyan
    self.traceStyle = traceStyle
    self.nodeOpacity = nodeOpacity
    self.backgroundAsset = backgroundAsset
    self.surfaceMaterial = surfaceMaterial
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    version = try container.decode(Int.self, forKey: .version)
    ink = try container.decode(ThemeColor.self, forKey: .ink)
    surface = try container.decode(ThemeColor.self, forKey: .surface)
    raised = try container.decode(ThemeColor.self, forKey: .raised)
    paper = try container.decode(ThemeColor.self, forKey: .paper)
    muted = try container.decode(ThemeColor.self, forKey: .muted)
    signal = try container.decode(ThemeColor.self, forKey: .signal)
    amber = try container.decode(ThemeColor.self, forKey: .amber)
    red = try container.decode(ThemeColor.self, forKey: .red)
    cyan = try container.decode(ThemeColor.self, forKey: .cyan)
    traceStyle = try container.decode(String.self, forKey: .traceStyle)
    nodeOpacity = try container.decode(Double.self, forKey: .nodeOpacity)
    backgroundAsset = try container.decodeIfPresent(String.self, forKey: .backgroundAsset)
    surfaceMaterial =
      try container.decodeIfPresent(String.self, forKey: .surfaceMaterial)
      ?? OttoSurfaceMaterial.opaque.rawValue
  }
}

public enum OttoThemeCatalog {
  public static let all: [OttoThemeDefinition] = [
    fieldNotes, aurora, highfell, silverbough, mistfall, duneveil,
    halcyon, ringfall, shorelight, farfield, afterglow, nightspire, graphite, velvet,
    nightscreen, glasswing, nightglass,
  ]

  /// Superseded theme IDs (name collisions with another product, plus identity renames when themes
  /// gained artwork); persisted canvases and recipes may still carry them.
  private static let legacyAliases: [String: String] = [
    "lakeside": "shorelight",
    "cobalt": "farfield",
    "fathom": "farfield",
    "outrun": "afterglow",
    "nocturne": "ringfall",
    "aperture": "nightspire",
  ]

  /// Resolves an installed or legacy theme ID to its installed ID, nil when unknown.
  public static func canonicalID(_ id: String) -> String? {
    let resolved = legacyAliases[id] ?? id
    return all.contains { $0.id == resolved } ? resolved : nil
  }

  /// The theme a brand-new workspace opens in: Highfell's sunlit valley, which also backs the
  /// welcome screens. Unknown or missing IDs still fall back to Field Notes.
  public static let defaultThemeID = "highfell"

  public static func theme(id: String?) -> OttoThemeDefinition {
    guard let id, let canonical = canonicalID(id) else { return fieldNotes }
    return all.first { $0.id == canonical } ?? fieldNotes
  }

  public static let fieldNotes = OttoThemeDefinition(
    id: "field-notes", displayName: "Field Notes", version: 1,
    ink: ThemeColor(red: 0.055, green: 0.061, blue: 0.063),
    surface: ThemeColor(red: 0.085, green: 0.091, blue: 0.091),
    raised: ThemeColor(red: 0.115, green: 0.121, blue: 0.118),
    paper: ThemeColor(red: 0.89, green: 0.87, blue: 0.80),
    muted: ThemeColor(red: 0.55, green: 0.57, blue: 0.53),
    signal: ThemeColor(red: 0.76, green: 0.94, blue: 0.28),
    amber: ThemeColor(red: 0.95, green: 0.60, blue: 0.20),
    red: ThemeColor(red: 0.95, green: 0.32, blue: 0.25),
    cyan: ThemeColor(red: 0.30, green: 0.82, blue: 0.78),
    traceStyle: "signal", nodeOpacity: 0.96
  )

  /// Golden storybook castle on a lake — idyllic warm light behind dark glass.
  public static let halcyon = OttoThemeDefinition(
    id: "halcyon", displayName: "Halcyon", version: 2,
    ink: ThemeColor(red: 0.075, green: 0.063, blue: 0.095),
    surface: ThemeColor(red: 0.12, green: 0.10, blue: 0.14),
    raised: ThemeColor(red: 0.17, green: 0.13, blue: 0.16),
    paper: ThemeColor(red: 0.96, green: 0.91, blue: 0.82),
    muted: ThemeColor(red: 0.68, green: 0.63, blue: 0.62),
    signal: ThemeColor(red: 0.91, green: 0.53, blue: 0.29),
    amber: ThemeColor(red: 0.95, green: 0.72, blue: 0.32),
    red: ThemeColor(red: 0.94, green: 0.35, blue: 0.30),
    cyan: ThemeColor(red: 0.40, green: 0.79, blue: 0.76),
    traceStyle: "ember", nodeOpacity: 0.90,
    backgroundAsset: "halcyon", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Colossal ringworld arcing over waterfall valleys — cool sci-fi blue.
  public static let ringfall = OttoThemeDefinition(
    id: "ringfall", displayName: "Ringfall", version: 2,
    ink: ThemeColor(red: 0.025, green: 0.065, blue: 0.12),
    surface: ThemeColor(red: 0.045, green: 0.10, blue: 0.17),
    raised: ThemeColor(red: 0.07, green: 0.15, blue: 0.23),
    paper: ThemeColor(red: 0.86, green: 0.93, blue: 0.98),
    muted: ThemeColor(red: 0.57, green: 0.68, blue: 0.77),
    signal: ThemeColor(red: 0.30, green: 0.86, blue: 0.92),
    amber: ThemeColor(red: 0.95, green: 0.68, blue: 0.27),
    red: ThemeColor(red: 0.96, green: 0.37, blue: 0.42),
    cyan: ThemeColor(red: 0.38, green: 0.78, blue: 1.0),
    traceStyle: "ion", nodeOpacity: 0.94,
    backgroundAsset: "ringfall", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Mediterranean shore — sun on still water.
  public static let shorelight = OttoThemeDefinition(
    id: "shorelight", displayName: "Shorelight", version: 2,
    ink: ThemeColor(red: 0.03, green: 0.10, blue: 0.11),
    surface: ThemeColor(red: 0.05, green: 0.14, blue: 0.15),
    raised: ThemeColor(red: 0.08, green: 0.19, blue: 0.20),
    paper: ThemeColor(red: 0.95, green: 0.92, blue: 0.84),
    muted: ThemeColor(red: 0.58, green: 0.70, blue: 0.67),
    signal: ThemeColor(red: 0.98, green: 0.76, blue: 0.30),
    amber: ThemeColor(red: 0.92, green: 0.55, blue: 0.30),
    red: ThemeColor(red: 0.95, green: 0.41, blue: 0.33),
    cyan: ThemeColor(red: 0.38, green: 0.80, blue: 0.82),
    traceStyle: "sun", nodeOpacity: 0.92,
    backgroundAsset: "shorelight", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Wide adventuring field — distant volcano and ruins, palette drawn from the art.
  public static let farfield = OttoThemeDefinition(
    id: "farfield", displayName: "Farfield", version: 3,
    ink: ThemeColor(red: 0.025, green: 0.060, blue: 0.050),
    surface: ThemeColor(red: 0.045, green: 0.100, blue: 0.085),
    raised: ThemeColor(red: 0.075, green: 0.150, blue: 0.120),
    paper: ThemeColor(red: 0.92, green: 0.95, blue: 0.90),
    muted: ThemeColor(red: 0.60, green: 0.68, blue: 0.62),
    signal: ThemeColor(red: 0.45, green: 0.85, blue: 0.40),
    amber: ThemeColor(red: 0.95, green: 0.55, blue: 0.25),
    red: ThemeColor(red: 0.95, green: 0.36, blue: 0.30),
    cyan: ThemeColor(red: 0.40, green: 0.75, blue: 0.95),
    traceStyle: "verdant", nodeOpacity: 0.93,
    backgroundAsset: "farfield", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Synthwave — neon dusk.
  public static let afterglow = OttoThemeDefinition(
    id: "afterglow", displayName: "Afterglow", version: 2,
    ink: ThemeColor(red: 0.07, green: 0.03, blue: 0.11),
    surface: ThemeColor(red: 0.11, green: 0.05, blue: 0.16),
    raised: ThemeColor(red: 0.16, green: 0.08, blue: 0.22),
    paper: ThemeColor(red: 0.96, green: 0.91, blue: 0.98),
    muted: ThemeColor(red: 0.70, green: 0.60, blue: 0.80),
    signal: ThemeColor(red: 0.99, green: 0.42, blue: 0.74),
    amber: ThemeColor(red: 0.97, green: 0.66, blue: 0.28),
    red: ThemeColor(red: 0.98, green: 0.34, blue: 0.38),
    cyan: ThemeColor(red: 0.40, green: 0.90, blue: 0.95),
    traceStyle: "neon", nodeOpacity: 0.92
  )

  /// Showpiece — polar sky over dark water, live animated background.
  public static let aurora = OttoThemeDefinition(
    id: "aurora", displayName: "Aurora", version: 1,
    ink: ThemeColor(red: 0.030, green: 0.050, blue: 0.100),
    surface: ThemeColor(red: 0.055, green: 0.085, blue: 0.150),
    raised: ThemeColor(red: 0.090, green: 0.130, blue: 0.210),
    paper: ThemeColor(red: 0.90, green: 0.95, blue: 0.97),
    muted: ThemeColor(red: 0.56, green: 0.66, blue: 0.74),
    signal: ThemeColor(red: 0.45, green: 0.94, blue: 0.70),
    amber: ThemeColor(red: 0.95, green: 0.70, blue: 0.30),
    red: ThemeColor(red: 0.96, green: 0.40, blue: 0.44),
    cyan: ThemeColor(red: 0.40, green: 0.85, blue: 0.95),
    traceStyle: "aurora", nodeOpacity: 0.93,
    backgroundAsset: "aurora", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Light landscape — dramatic verdant highlands under a golden sky.
  public static let highfell = OttoThemeDefinition(
    id: "highfell", displayName: "Highfell", version: 1,
    ink: ThemeColor(red: 0.93, green: 0.91, blue: 0.84),
    surface: ThemeColor(red: 0.97, green: 0.95, blue: 0.89),
    raised: ThemeColor(red: 1.0, green: 0.98, blue: 0.93),
    paper: ThemeColor(red: 0.14, green: 0.16, blue: 0.11),
    muted: ThemeColor(red: 0.36, green: 0.38, blue: 0.31),
    signal: ThemeColor(red: 0.13, green: 0.42, blue: 0.20),
    amber: ThemeColor(red: 0.55, green: 0.35, blue: 0.05),
    red: ThemeColor(red: 0.68, green: 0.16, blue: 0.12),
    cyan: ThemeColor(red: 0.05, green: 0.38, blue: 0.42),
    traceStyle: "verdant", nodeOpacity: 0.95,
    backgroundAsset: "highfell", surfaceMaterial: OttoSurfaceMaterial.glassLight.rawValue
  )

  /// Light landscape — silver forest valley, low mist, gold light rays.
  public static let silverbough = OttoThemeDefinition(
    id: "silverbough", displayName: "Silverbough", version: 1,
    ink: ThemeColor(red: 0.90, green: 0.93, blue: 0.92),
    surface: ThemeColor(red: 0.95, green: 0.97, blue: 0.96),
    raised: ThemeColor(red: 0.99, green: 1.0, blue: 0.99),
    paper: ThemeColor(red: 0.10, green: 0.16, blue: 0.14),
    muted: ThemeColor(red: 0.33, green: 0.40, blue: 0.38),
    signal: ThemeColor(red: 0.10, green: 0.40, blue: 0.26),
    amber: ThemeColor(red: 0.55, green: 0.38, blue: 0.08),
    red: ThemeColor(red: 0.66, green: 0.18, blue: 0.16),
    cyan: ThemeColor(red: 0.05, green: 0.36, blue: 0.40),
    traceStyle: "sylvan", nodeOpacity: 0.94,
    backgroundAsset: "silverbough", surfaceMaterial: OttoSurfaceMaterial.glassLight.rawValue
  )

  /// Light landscape — ink-wash mountains dissolving into mist.
  public static let mistfall = OttoThemeDefinition(
    id: "mistfall", displayName: "Mistfall", version: 1,
    ink: ThemeColor(red: 0.94, green: 0.94, blue: 0.93),
    surface: ThemeColor(red: 0.97, green: 0.97, blue: 0.96),
    raised: ThemeColor(red: 1.0, green: 1.0, blue: 0.99),
    paper: ThemeColor(red: 0.12, green: 0.12, blue: 0.13),
    muted: ThemeColor(red: 0.38, green: 0.38, blue: 0.40),
    signal: ThemeColor(red: 0.20, green: 0.25, blue: 0.50),
    amber: ThemeColor(red: 0.55, green: 0.30, blue: 0.10),
    red: ThemeColor(red: 0.65, green: 0.15, blue: 0.13),
    cyan: ThemeColor(red: 0.08, green: 0.35, blue: 0.40),
    traceStyle: "wash", nodeOpacity: 0.95,
    backgroundAsset: "mistfall", surfaceMaterial: OttoSurfaceMaterial.glassLight.rawValue
  )

  /// Light landscape — dawn dunes, warm haze.
  public static let duneveil = OttoThemeDefinition(
    id: "duneveil", displayName: "Duneveil", version: 1,
    ink: ThemeColor(red: 0.94, green: 0.89, blue: 0.80),
    surface: ThemeColor(red: 0.97, green: 0.93, blue: 0.86),
    raised: ThemeColor(red: 1.0, green: 0.97, blue: 0.91),
    paper: ThemeColor(red: 0.18, green: 0.12, blue: 0.08),
    muted: ThemeColor(red: 0.42, green: 0.35, blue: 0.28),
    signal: ThemeColor(red: 0.55, green: 0.26, blue: 0.08),
    amber: ThemeColor(red: 0.56, green: 0.35, blue: 0.05),
    red: ThemeColor(red: 0.66, green: 0.16, blue: 0.10),
    cyan: ThemeColor(red: 0.05, green: 0.37, blue: 0.38),
    traceStyle: "ember", nodeOpacity: 0.95,
    backgroundAsset: "duneveil", surfaceMaterial: OttoSurfaceMaterial.glassLight.rawValue
  )

  /// Gothic spires at dusk — lamplit gold on storm gray.
  public static let nightspire = OttoThemeDefinition(
    id: "nightspire", displayName: "Nightspire", version: 2,
    ink: ThemeColor(red: 0.055, green: 0.050, blue: 0.045),
    surface: ThemeColor(red: 0.090, green: 0.083, blue: 0.075),
    raised: ThemeColor(red: 0.130, green: 0.118, blue: 0.104),
    paper: ThemeColor(red: 0.94, green: 0.90, blue: 0.83),
    muted: ThemeColor(red: 0.64, green: 0.60, blue: 0.54),
    signal: ThemeColor(red: 0.99, green: 0.74, blue: 0.24),
    amber: ThemeColor(red: 0.93, green: 0.58, blue: 0.26),
    red: ThemeColor(red: 0.94, green: 0.36, blue: 0.28),
    cyan: ThemeColor(red: 0.44, green: 0.78, blue: 0.74),
    traceStyle: "forge", nodeOpacity: 0.95,
    backgroundAsset: "nightspire", surfaceMaterial: OttoSurfaceMaterial.glassDark.rawValue
  )

  /// Matte dusk — plum twilight behind soft, non-reflective surfaces. Uses the `matte`
  /// surface material (shared with Nightscreen): node shells render as flat translucent
  /// color at the user's adjustable matte transparency instead of glass or opaque panels.
  public static let velvet = OttoThemeDefinition(
    id: "velvet", displayName: "Velvet", version: 1,
    ink: ThemeColor(red: 0.055, green: 0.045, blue: 0.065),
    surface: ThemeColor(red: 0.10, green: 0.085, blue: 0.115),
    raised: ThemeColor(red: 0.15, green: 0.125, blue: 0.165),
    paper: ThemeColor(red: 0.95, green: 0.92, blue: 0.94),
    muted: ThemeColor(red: 0.72, green: 0.65, blue: 0.72),
    signal: ThemeColor(red: 0.93, green: 0.60, blue: 0.66),
    amber: ThemeColor(red: 0.95, green: 0.68, blue: 0.36),
    red: ThemeColor(red: 0.96, green: 0.42, blue: 0.42),
    cyan: ThemeColor(red: 0.55, green: 0.80, blue: 0.85),
    traceStyle: "plume", nodeOpacity: 0.86,
    backgroundAsset: "velvet", surfaceMaterial: OttoSurfaceMaterial.matte.rawValue
  )

  /// Nightscreen — painted character art behind dark glass. The wallpaper is the room and
  /// the UI is smoked glass laid over it: matte shells at a low default opacity so the
  /// art reads through every panel, one violet accent, and a moonlit teal for needs-you.
  /// Palette sampled from the shipped illustration (`nightscreen.heic`).
  public static let nightscreen = OttoThemeDefinition(
    id: "nightscreen", displayName: "Nightscreen", version: 1,
    ink: ThemeColor(red: 0.043, green: 0.039, blue: 0.071),
    surface: ThemeColor(red: 0.075, green: 0.067, blue: 0.110),
    raised: ThemeColor(red: 0.115, green: 0.100, blue: 0.160),
    paper: ThemeColor(red: 0.93, green: 0.918, blue: 0.96),
    muted: ThemeColor(red: 0.64, green: 0.62, blue: 0.72),
    signal: ThemeColor(red: 0.67, green: 0.68, blue: 0.96),
    amber: ThemeColor(red: 0.94, green: 0.70, blue: 0.35),
    red: ThemeColor(red: 0.95, green: 0.43, blue: 0.43),
    cyan: ThemeColor(red: 0.37, green: 0.77, blue: 0.85),
    traceStyle: "plume", nodeOpacity: 0.78,
    backgroundAsset: "nightscreen", surfaceMaterial: OttoSurfaceMaterial.matte.rawValue
  )

  /// Light window glass — the desktop shows through the whole window behind a bright
  /// frost, like a pane of etched glass laid over the wallpaper.
  public static let glasswing = OttoThemeDefinition(
    id: "glasswing", displayName: "Glasswing", version: 2,
    ink: ThemeColor(red: 0.93, green: 0.94, blue: 0.96),
    surface: ThemeColor(red: 0.94, green: 0.95, blue: 0.97),
    raised: ThemeColor(red: 0.98, green: 0.985, blue: 1.0),
    paper: ThemeColor(red: 0.15, green: 0.15, blue: 0.19),
    muted: ThemeColor(red: 0.34, green: 0.35, blue: 0.40),
    signal: ThemeColor(red: 0.36, green: 0.30, blue: 0.62),
    amber: ThemeColor(red: 0.59, green: 0.38, blue: 0.08),
    red: ThemeColor(red: 0.78, green: 0.18, blue: 0.20),
    cyan: ThemeColor(red: 0.10, green: 0.42, blue: 0.52),
    traceStyle: "wash", nodeOpacity: 0.18,
    backgroundAsset: "glass", surfaceMaterial: OttoSurfaceMaterial.windowGlass.rawValue
  )

  /// Dark window glass — smoked frost over the desktop, the whole window a dimmed pane.
  public static let nightglass = OttoThemeDefinition(
    id: "nightglass", displayName: "Nightglass", version: 2,
    ink: ThemeColor(red: 0.07, green: 0.07, blue: 0.09),
    surface: ThemeColor(red: 0.10, green: 0.10, blue: 0.13),
    raised: ThemeColor(red: 0.15, green: 0.15, blue: 0.19),
    paper: ThemeColor(red: 0.95, green: 0.95, blue: 0.97),
    muted: ThemeColor(red: 0.64, green: 0.65, blue: 0.70),
    signal: ThemeColor(red: 0.67, green: 0.68, blue: 0.96),
    amber: ThemeColor(red: 0.95, green: 0.70, blue: 0.36),
    red: ThemeColor(red: 0.96, green: 0.44, blue: 0.44),
    cyan: ThemeColor(red: 0.52, green: 0.80, blue: 0.88),
    traceStyle: "mono", nodeOpacity: 0.18,
    backgroundAsset: "glass", surfaceMaterial: OttoSurfaceMaterial.windowGlass.rawValue
  )

  /// Neutral dark — deep focus.
  public static let graphite = OttoThemeDefinition(
    id: "graphite", displayName: "Graphite", version: 1,
    ink: ThemeColor(red: 0.050, green: 0.050, blue: 0.055),
    surface: ThemeColor(red: 0.085, green: 0.087, blue: 0.092),
    raised: ThemeColor(red: 0.120, green: 0.122, blue: 0.128),
    paper: ThemeColor(red: 0.90, green: 0.90, blue: 0.92),
    muted: ThemeColor(red: 0.58, green: 0.59, blue: 0.62),
    signal: ThemeColor(red: 0.52, green: 0.74, blue: 0.98),
    amber: ThemeColor(red: 0.94, green: 0.68, blue: 0.30),
    red: ThemeColor(red: 0.95, green: 0.38, blue: 0.36),
    cyan: ThemeColor(red: 0.42, green: 0.80, blue: 0.86),
    traceStyle: "mono", nodeOpacity: 0.97
  )
}

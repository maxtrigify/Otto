import CoreGraphics
import Foundation
import ImageIO
import OttoModels
import Testing

@Suite("Theme catalogue")
struct ThemeTests {
  @Test("Every installed theme satisfies text contrast invariants")
  func contrast() {
    #expect(OttoThemeCatalog.all.count == 17)
    #expect(Set(OttoThemeCatalog.all.map(\.id)).count == 17)
    for theme in OttoThemeCatalog.all {
      #expect(theme.paper.contrastRatio(with: theme.ink) >= 7)
      #expect(theme.muted.contrastRatio(with: theme.ink) >= 4.5)
      #expect(theme.signal.contrastRatio(with: theme.ink) >= 4.5)
      // Translucent materials carry their own AA proofs down to the transparency floor
      // (velvet/glass contract tests); opaque-ish themes keep the 0.75 shell floor.
      let shellRange: ClosedRange<Double>
      switch theme.resolvedSurfaceMaterial {
      case .matte: shellRange = OttoMatteTransparency.range
      case .windowGlass: shellRange = OttoWindowGlassTransparency.range
      default: shellRange = 0.75...1
      }
      #expect(shellRange.contains(theme.nodeOpacity), "\(theme.id)")
    }
  }

  @Test("Text stays legible composited over the worst in-contract backdrop pixel")
  func compositedBackdropContrast() {
    // Flat pairs above prove nothing about text over an animated or procedural backdrop —
    // the exact bug class a comparable product shipped (white text over a bright video).
    // Every theme with a backdrop commits to a luminance bound on its artwork; contrast is
    // judged against the worst in-contract pixel seen through the scrim.
    for theme in OttoThemeCatalog.all where theme.backgroundAsset != nil {
      // Window glass deliberately leaves bare wallpaper visible. Its dense text lives on local
      // material-backed surfaces and has a separate contrast/visibility contract below.
      if theme.resolvedSurfaceMaterial == .windowGlass { continue }
      // Where the persistent HUD sits (the scrim's deep stop), paper text must hold WCAG AA.
      let deep = theme.worstCaseScrimmedBackdrop(scrimOpacity: theme.scrimDeepOpacity)
      let paperDeep = theme.paper.contrastRatio(with: deep)
      #expect(paperDeep >= 4.5, "\(theme.id): paper over deep scrim is \(paperDeep)")

      // At the weakest stop the shipped scrim does NOT reach AA over the brightest permitted
      // art region (paper lands 2.4–3.3 across the catalogue today). This floor pins the
      // measured reality so it cannot silently regress; raising it to 4.5 needs a darker
      // scrim top or darker art — a design decision.
      let floor = theme.worstCaseScrimmedBackdrop(scrimOpacity: theme.scrimFloorOpacity)
      let paperFloor = theme.paper.contrastRatio(with: floor)
      #expect(paperFloor >= 2.3, "\(theme.id): paper over weakest scrim is \(paperFloor)")

      // Muted text has no legibility guarantee over raw backdrop at any stop — it must only
      // ever appear on opaque or near-opaque panels, which the flat-pair invariants cover.
    }
  }

  @Test("Shipped backdrop artwork honours its theme's luminance contract")
  func backdropArtworkWithinContract() throws {
    // The composited invariant above only holds if the art actually stays inside the bound
    // it was judged against, so measure the shipped bytes. Dark-scrim themes cap how bright
    // large regions may be (90th-percentile luminance); light-scrim themes cap how dark
    // (10th percentile). Procedural scenes (aurora, landscape codes) are code-bounded and
    // not decoded here.
    let themesDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ThemeTests.swift
      .deletingLastPathComponent()  // OttoModelsTests
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("Sources/OttoApp/Resources/Themes")
    for theme in OttoThemeCatalog.all {
      guard let asset = theme.backgroundAsset else { continue }
      let url = themesDirectory.appendingPathComponent("\(asset).heic")
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let luminances = try #require(Self.pixelLuminances(url: url), "decode \(asset).heic")
      let sorted = luminances.sorted()
      func percentile(_ p: Double) -> Double {
        sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
      }
      if theme.resolvedSurfaceMaterial == .glassLight {
        let darkTail = percentile(0.10)
        #expect(
          darkTail >= theme.backdropLuminanceBound,
          "\(theme.id): 10th-percentile luminance \(darkTail) darker than contract")
      } else {
        let brightTail = percentile(0.90)
        #expect(
          brightTail <= theme.backdropLuminanceBound,
          "\(theme.id): 90th-percentile luminance \(brightTail) brighter than contract")
      }
    }
  }

  /// WCAG relative luminance of every pixel in a 256px decode of the asset.
  private static func pixelLuminances(url: URL) -> [Double]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 256,
        ] as CFDictionary),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    return (0..<(image.width * image.height)).map { index in
      let color = ThemeColor(
        red: Double(data[index * 4]) / 255,
        green: Double(data[index * 4 + 1]) / 255,
        blue: Double(data[index * 4 + 2]) / 255
      )
      return color.luminance
    }
  }

  @Test("Surface materials parse to a known material")
  func surfaceMaterials() {
    for theme in OttoThemeCatalog.all {
      #expect(OttoSurfaceMaterial(rawValue: theme.surfaceMaterial) != nil)
    }
  }

  @Test("Legacy and renamed theme IDs resolve to installed themes")
  func legacyAliases() {
    #expect(OttoThemeCatalog.theme(id: "lakeside").id == "shorelight")
    #expect(OttoThemeCatalog.theme(id: "cobalt").id == "farfield")
    #expect(OttoThemeCatalog.theme(id: "fathom").id == "farfield")
    #expect(OttoThemeCatalog.theme(id: "outrun").id == "afterglow")
    #expect(OttoThemeCatalog.theme(id: "nocturne").id == "ringfall")
    #expect(OttoThemeCatalog.theme(id: "aperture").id == "nightspire")
    #expect(OttoThemeCatalog.canonicalID("lakeside") == "shorelight")
    #expect(OttoThemeCatalog.canonicalID("shorelight") == "shorelight")
    #expect(OttoThemeCatalog.canonicalID("does-not-exist") == nil)
    #expect(OttoThemeCatalog.theme(id: "does-not-exist").id == OttoThemeCatalog.fieldNotes.id)
  }

  @Test("No installed theme reuses another product's theme names")
  func noBorrowedNames() {
    let borrowed = ["lakeside", "cobalt", "outrun", "hyperdrive"]
    for theme in OttoThemeCatalog.all {
      #expect(!borrowed.contains(theme.id))
      #expect(!borrowed.contains(theme.displayName.lowercased()))
    }
  }

  @Test("Theme definitions without background fields still decode")
  func decodeLegacyDefinition() throws {
    var legacy = OttoThemeCatalog.fieldNotes
    legacy.backgroundAsset = nil
    legacy.surfaceMaterial = OttoSurfaceMaterial.opaque.rawValue
    let encoded = try JSONEncoder().encode(legacy)
    var object =
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
    object.removeValue(forKey: "backgroundAsset")
    object.removeValue(forKey: "surfaceMaterial")
    let stripped = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(OttoThemeDefinition.self, from: stripped)
    #expect(decoded == legacy)
  }

  @Test("Aurora is the showpiece animated theme")
  func auroraShowpiece() {
    let aurora = OttoThemeCatalog.theme(id: "aurora")
    #expect(aurora.backgroundAsset == "aurora")
    #expect(aurora.resolvedSurfaceMaterial == .glassDark)
  }

  @Test("Painted dark-glass themes ship artwork matching their ID")
  func paintedDarkThemes() {
    for id in ["shorelight", "halcyon", "ringfall", "farfield", "nightspire"] {
      let theme = OttoThemeCatalog.theme(id: id)
      #expect(theme.backgroundAsset == id)
      #expect(theme.resolvedSurfaceMaterial == .glassDark)
      #expect(!theme.isLightAppearance)
    }
    // Deliberately artwork-free minimal themes.
    #expect(OttoThemeCatalog.fieldNotes.backgroundAsset == nil)
    #expect(OttoThemeCatalog.graphite.backgroundAsset == nil)
    #expect(OttoThemeCatalog.afterglow.backgroundAsset == nil)
  }

  @Test("Matte themes keep paper text legible down to the transparency floor")
  func matteThemes() {
    let matte = OttoThemeCatalog.all.filter { $0.resolvedSurfaceMaterial == .matte }
    // The matte transparency preference is shared by exactly these themes; adding one here
    // means auditing its sheer-shell contrast below and the Settings copy that names them.
    #expect(Set(matte.map(\.id)) == ["velvet", "nightscreen"])
    for theme in matte {
      #expect(theme.backgroundAsset != nil)
      #expect(!theme.isLightAppearance)
      #expect(OttoMatteTransparency.range.contains(theme.nodeOpacity))
      // Matte shells composite at down to the transparency floor over the scrimmed backdrop;
      // paper text on such a shell must keep AA against the worst in-contract pixel seen
      // through scrim floor + a floor-opacity surface.
      let backdrop = theme.worstCaseScrimmedBackdrop(scrimOpacity: theme.scrimFloorOpacity)
      let sheerShell = theme.surface.blended(
        over: backdrop, opacity: OttoMatteTransparency.range.lowerBound)
      #expect(theme.paper.contrastRatio(with: sheerShell) >= 4.5, "\(theme.id)")
    }
  }

  @Test("Nightscreen is painted character art behind matte glass")
  func nightscreen() {
    let theme = OttoThemeCatalog.theme(id: "nightscreen")
    #expect(theme.backgroundAsset == "nightscreen")
    #expect(theme.resolvedSurfaceMaterial == .matte)
    // Sheerer than Velvet by design: the artwork is the point, the shells are smoked glass.
    #expect(theme.nodeOpacity < OttoThemeCatalog.velvet.nodeOpacity)
  }

  @Test("Window-glass themes preserve wallpaper and keep material-backed cards legible")
  func windowGlassContract() {
    let glassThemes = OttoThemeCatalog.all.filter {
      $0.resolvedSurfaceMaterial == .windowGlass
    }
    #expect(Set(glassThemes.map(\.id)) == ["glasswing", "nightglass"])
    #expect(glassThemes.contains { $0.isLightAppearance })
    #expect(glassThemes.contains { !$0.isLightAppearance })
    for theme in glassThemes {
      // The desktop wallpaper is unbounded, so probe BOTH extremes behind the frost:
      // a pure-white and a pure-black pixel. The generic composited test only checks the
      // theme's declared worst side; glass must hold on the opposite extreme too.
      let white = ThemeColor(red: 1, green: 1, blue: 1)
      let black = ThemeColor(red: 0, green: 0, blue: 0)
      let wallpaperContribution =
        (1 - OttoThemeDefinition.windowGlassMaterialTintOpacity)
        * (1 - theme.scrimFloorOpacity)
      #expect(
        wallpaperContribution >= 0.80,
        "\(theme.id): the acrylic sheet hides too much of the wallpaper")
      #expect(OttoWindowGlassTransparency.range.contains(theme.nodeOpacity))
      for extreme in [white, black] {
        // The system blur material sits under the frost and is credited with its assumed
        // surface-equivalent tint — the same composition worstCaseScrimmedBackdrop uses.
        let materialTinted = theme.surface.blended(
          over: extreme, opacity: OttoThemeDefinition.windowGlassMaterialTintOpacity)
        let frosted = theme.surface.blended(
          over: materialTinted, opacity: theme.scrimFloorOpacity)
        let panelMaterial = theme.surface.blended(
          over: frosted, opacity: OttoThemeDefinition.windowGlassPanelMaterialTintOpacity)
        let shell = theme.surface.blended(over: panelMaterial, opacity: theme.nodeOpacity)
        #expect(
          theme.paper.contrastRatio(with: shell) >= 4.5,
          "\(theme.id): paper on acrylic card above \(extreme) wallpaper")
      }
    }
  }

  @Test("Matte transparency preference resolves with clamping and theme fallback")
  func matteTransparencyResolution() {
    #expect(OttoMatteTransparency.resolve(preference: nil, themeDefault: 0.86) == 0.86)
    #expect(OttoMatteTransparency.resolve(preference: 0, themeDefault: 0.86) == 0.86)
    #expect(OttoMatteTransparency.resolve(preference: 0.7, themeDefault: 0.86) == 0.7)
    #expect(OttoMatteTransparency.resolve(preference: 0.1, themeDefault: 0.86) == 0.55)
    #expect(OttoMatteTransparency.resolve(preference: 2, themeDefault: 0.86) == 1.0)
  }

  @Test("Catalog offers light-appearance landscape themes")
  func lightThemes() {
    let light = OttoThemeCatalog.all.filter(\.isLightAppearance)
    #expect(
      light.map(\.id).sorted()
        == ["duneveil", "glasswing", "highfell", "mistfall", "silverbough"])
    for theme in light {
      #expect(theme.backgroundAsset != nil)
      #expect(
        theme.resolvedSurfaceMaterial == .glassLight
          || theme.resolvedSurfaceMaterial == .windowGlass)
      #expect(theme.ink.isLight)
      #expect(!theme.paper.isLight)
    }
    // Dark themes must not accidentally flip system chrome.
    #expect(!OttoThemeCatalog.fieldNotes.isLightAppearance)
    #expect(!OttoThemeCatalog.aurora.isLightAppearance)
  }

  @Test("New workspaces and canvases open in Highfell")
  func newWorkspacesUseHighfell() {
    #expect(OttoThemeCatalog.defaultThemeID == OttoThemeCatalog.highfell.id)
    #expect(OttoCanvas(name: "New").themeID == "highfell")
    #expect(WorkspaceSnapshot.starter.canvases.allSatisfy { $0.themeID == "highfell" })
  }
}

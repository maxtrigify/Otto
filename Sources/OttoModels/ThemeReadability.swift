import Foundation

/// WCAG contrast floors every built-in theme is held to. Body text needs 4.5:1; secondary
/// text, fine print and glyph-only controls need 3:1 (WCAG 1.4.3 large text / 1.4.11).
public enum OttoTextContrast {
  public static let body = 4.5
  public static let secondary = 3.0
}

extension ThemeColor {
  public static let black = ThemeColor(red: 0, green: 0, blue: 0)
  public static let white = ThemeColor(red: 1, green: 1, blue: 1)

  /// Black or white, whichever reads better on every one of `fills` (for text laid over a
  /// gradient or a fill that varies between two colours).
  public static func bestText(on fills: [ThemeColor]) -> ThemeColor {
    let onBlack = fills.map { black.contrastRatio(with: $0) }.min() ?? 0
    let onWhite = fills.map { white.contrastRatio(with: $0) }.min() ?? 0
    return onBlack >= onWhite ? black : white
  }

  /// This colour moved the shortest distance toward `anchor` (or toward black/white, whichever
  /// contrasts more with `background`) that reaches `target` contrast. Hue survives where it
  /// can, so a dark-theme blue stays recognisably blue on a light theme instead of vanishing.
  /// Already-readable colours are returned unchanged.
  public func raisingContrast(
    to target: Double, against background: ThemeColor, toward anchor: ThemeColor? = nil
  ) -> ThemeColor {
    if contrastRatio(with: background) >= target { return self }
    let extreme: ThemeColor = {
      if let anchor, anchor.contrastRatio(with: background) >= target { return anchor }
      return Self.black.contrastRatio(with: background) >= Self.white.contrastRatio(
        with: background) ? Self.black : Self.white
    }()
    // Contrast against a fixed background is monotonic along the blend toward the extreme, so
    // a short bisection finds the least change that clears the floor.
    var low = 0.0
    var high = 1.0
    for _ in 0..<18 {
      let mid = (low + high) / 2
      if extreme.blended(over: self, opacity: mid).contrastRatio(with: background) >= target {
        high = mid
      } else {
        low = mid
      }
    }
    return extreme.blended(over: self, opacity: high)
  }
}

extension OttoThemeDefinition {
  /// Text and glyph colour for chrome bands (window header strips) and anything else that
  /// sits on `chromeBand`. Always the theme's own text colour, so the band never flips to
  /// white-on-light or black-on-dark when the theme changes.
  public var chromeForeground: ThemeColor { paper }

  /// The ink tint behind header bands that float over artwork or the desktop. Artwork can
  /// hold any pixel (Home and Chat keep the backdrop nearly unscrimmed), so the opacity is
  /// sized for the worst case on both sides: a pure-white and a pure-black pixel. The theme
  /// tests prove `chromeForeground` keeps body contrast through exactly this value.
  public var chromeBandOpacity: Double {
    let extremes = [ThemeColor.black, ThemeColor.white]
    func holds(_ opacity: Double) -> Bool {
      extremes.allSatisfy {
        paper.contrastRatio(with: ink.blended(over: $0, opacity: opacity))
          >= OttoTextContrast.body
      }
    }
    // Round up to a whole percent so the rendered value is never below the proven one.
    for percent in 0...100 where holds(Double(percent) / 100) {
      return Double(percent) / 100
    }
    return 1
  }

  /// The colour the band paints, resolved against `backdrop`, for contrast audits.
  public func chromeBand(over backdrop: ThemeColor) -> ThemeColor {
    ink.blended(over: backdrop, opacity: chromeBandOpacity)
  }

  /// Backdrop pixels artwork can put behind a wash: a grey ramp from pure black to pure white.
  /// The extremes alone are not enough. Mid-tone text (`muted`) loses most against a mid-tone
  /// pixel, which a black/white-only check never tries.
  public static let artworkBackdropRamp: [ThemeColor] = (0...20).map {
    let level = Double($0) / 20
    return ThemeColor(red: level, green: level, blue: level)
  }

  /// The ink wash behind text that sits straight on theme artwork with no panel of its own:
  /// the Chat sidebar column and the transcript's secondary rows (activity notices, thinking
  /// steps, tool rows). Sized like `chromeBandOpacity`, but for every role that text takes
  /// there: body text (`paper`, and the rail's resting `paper` at 78%) holds 4.5:1, and
  /// secondary text (`muted`) and status glyphs (`signal`, `cyan`, `amber`: the info icon,
  /// activity dots, "needs you") hold 3:1, over any pixel on `artworkBackdropRamp`.
  public var artworkWashOpacity: Double {
    func holds(_ opacity: Double) -> Bool {
      Self.artworkBackdropRamp.allSatisfy { pixel in
        let wash = artworkWash(over: pixel, opacity: opacity)
        return paper.contrastRatio(with: wash) >= OttoTextContrast.body
          && paper.blended(over: wash, opacity: Self.restingTextOpacity).contrastRatio(
            with: wash) >= OttoTextContrast.body
          && [muted, signal, cyan, amber].allSatisfy {
            $0.contrastRatio(with: wash) >= OttoTextContrast.secondary
          }
      }
    }
    // Body text over the ramp's extremes is exactly the header band's condition, so the wash
    // starts there. Whole percents keep the rendered value at or above the proven one.
    let start = Int((chromeBandOpacity * 100).rounded())
    for percent in start...100 where holds(Double(percent) / 100) {
      return Double(percent) / 100
    }
    return 1
  }

  /// The faintest `paper` opacity rows on the wash use for body text (resting sidebar rows).
  public static let restingTextOpacity = 0.78

  /// The colour the wash paints over `backdrop`, for contrast audits.
  public func artworkWash(over backdrop: ThemeColor) -> ThemeColor {
    artworkWash(over: backdrop, opacity: artworkWashOpacity)
  }

  private func artworkWash(over backdrop: ThemeColor, opacity: Double) -> ThemeColor {
    ink.blended(over: backdrop, opacity: opacity)
  }

  /// Whether Chat's sidebar and transcript rows sit on theme artwork with nothing but the
  /// light frost between them. Window glass is excluded: the desktop arrives through the
  /// system's behind-window material, which carries its own vibrancy contrast.
  public var drawsTextOverArtwork: Bool {
    backgroundAsset != nil && resolvedSurfaceMaterial != .windowGlass
  }

  /// Text on a fill that runs from `signal` to `cyan` (avatar tiles, hero badges).
  public var onAccentGradient: ThemeColor { ThemeColor.bestText(on: [signal, cyan]) }
}

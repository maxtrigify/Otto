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

  /// Text on a fill that runs from `signal` to `cyan` (avatar tiles, hero badges).
  public var onAccentGradient: ThemeColor { ThemeColor.bestText(on: [signal, cyan]) }
}

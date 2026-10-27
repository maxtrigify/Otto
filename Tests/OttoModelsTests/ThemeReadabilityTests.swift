import Foundation
import OttoModels
import Testing

/// Every built-in theme, every text/background pair the app actually paints. The palette
/// invariants in `ThemeTests` cover text on the window ink; these cover the other surfaces
/// text lands on (raised cards, panels, header bands, accent fills, the terminal) — the
/// places issue #10 found white-after-black text that vanished on one theme or another.
@Suite("Theme readability")
struct ThemeReadabilityTests {
  private static func textTokens(_ theme: OttoThemeDefinition) -> [(String, ThemeColor)] {
    [
      ("paper", theme.paper), ("muted", theme.muted), ("signal", theme.signal),
      ("amber", theme.amber), ("red", theme.red), ("cyan", theme.cyan),
    ]
  }
  private static func surfaceTokens(_ theme: OttoThemeDefinition) -> [(String, ThemeColor)] {
    [("ink", theme.ink), ("surface", theme.surface), ("raised", theme.raised)]
  }

  @Test("Every text token reads as body text on every opaque surface")
  func textTokensOnSurfaces() {
    for theme in OttoThemeCatalog.all {
      for (textName, text) in Self.textTokens(theme) {
        for (surfaceName, surface) in Self.surfaceTokens(theme) {
          let ratio = text.contrastRatio(with: surface)
          #expect(
            ratio >= OttoTextContrast.body,
            "\(theme.id): \(textName) on \(surfaceName) is \(ratio)")
        }
      }
    }
  }

  @Test("Header band text holds body contrast over any backdrop pixel")
  func chromeBand() {
    for theme in OttoThemeCatalog.all {
      // Home and Chat keep the artwork (or the desktop) nearly unscrimmed under the band,
      // so judge it over both extremes as well as the theme's own planes.
      for backdrop in [ThemeColor.black, .white, theme.ink, theme.surface] {
        let band = theme.chromeBand(over: backdrop)
        let ratio = theme.chromeForeground.contrastRatio(with: band)
        #expect(
          ratio >= OttoTextContrast.body,
          "\(theme.id): header text over \(backdrop) is \(ratio)")
      }
      // A band that is just the ink plane would also pass; keep it a tint.
      #expect(theme.chromeBandOpacity < 0.8, "\(theme.id)")
    }
  }

  @Test("The old fixed header wash fails light themes (regression guard)")
  func oldHeaderWashFailed() {
    // White glyphs over a 28% black wash: what both header bands shipped in 0.2.7.
    let failing = OttoThemeCatalog.all.filter { theme in
      let band = ThemeColor.black.blended(over: theme.ink, opacity: 0.28)
      return ThemeColor.white.contrastRatio(with: band) < OttoTextContrast.secondary
    }
    #expect(
      Set(failing.map(\.id)) == ["highfell", "silverbough", "mistfall", "duneveil", "glasswing"])
  }

  @Test("Text on the signal-to-cyan gradient reads at both ends")
  func accentGradient() {
    for theme in OttoThemeCatalog.all {
      for end in [theme.signal, theme.cyan] {
        let ratio = theme.onAccentGradient.contrastRatio(with: end)
        // The gradient carries one bold 22pt initial: WCAG large text.
        #expect(ratio >= OttoTextContrast.secondary, "\(theme.id): \(ratio)")
      }
    }
  }

  @Test("Raising contrast keeps readable colours and fixes unreadable ones minimally")
  func raisingContrast() {
    let ink = OttoThemeCatalog.highfell.ink
    let paper = OttoThemeCatalog.highfell.paper
    // Already readable: untouched.
    #expect(paper.raisingContrast(to: 4.5, against: ink) == paper)
    // White on a light theme becomes readable, toward the theme text colour.
    let fixed = ThemeColor.white.raisingContrast(to: 4.5, against: ink, toward: paper)
    #expect(fixed.contrastRatio(with: ink) >= 4.5)
    // A dark-theme blue stays bluish rather than collapsing to the anchor.
    let blue = ThemeColor(red: 0.45, green: 0.62, blue: 1.0)
    let darkInk = OttoThemeCatalog.graphite.ink
    let lifted = ThemeColor(red: 0.29, green: 0.18, blue: 0.88)
      .raisingContrast(to: 4.5, against: darkInk)
    #expect(lifted.contrastRatio(with: darkInk) >= 4.5)
    #expect(lifted.blue > lifted.red && lifted.blue > lifted.green)
    #expect(blue.raisingContrast(to: 4.5, against: darkInk) == blue)
  }
}

/// The embedded terminal: agent CLIs write colours for whatever terminal they assume, so the
/// filter must make every one of them readable on every built-in theme.
@Suite("Terminal contrast filter")
struct TerminalContrastFilterTests {
  /// Output a dark-tuned TUI (and a light-tuned one) typically writes: white and pale-grey
  /// body text, dim fine print, a blue slash-command hint, black text, 256-colour and
  /// truecolor variants, and colon-form SGR.
  private static let sample =
    "plain \u{1B}[97mbright white\u{1B}[0m \u{1B}[37mwhite\u{1B}[39m "
    + "\u{1B}[2mdim fine print \u{1B}[34m/mcp\u{1B}[22m\u{1B}[39m "
    + "\u{1B}[30mblack\u{1B}[m \u{1B}[1;30mbold black\u{1B}[0m "
    + "\u{1B}[38;5;231m256 white\u{1B}[38;5;244m 256 grey\u{1B}[38;5;16m 256 black\u{1B}[0m "
    + "\u{1B}[38;2;255;255;255mtrue white\u{1B}[38;2;153;153;153m true grey\u{1B}[0m "
    + "\u{1B}[38:2::255:255:255mcolon white\u{1B}[38:5:250m colon grey\u{1B}[0m "
    + "\u{1B}[2;38;2;136;136;136mdim grey\u{1B}[0m"

  private struct Cell {
    var character: Character
    var foreground: ThemeColor
    var background: ThemeColor
    var dim: Bool
  }

  /// A minimal renderer for the filter's output: it resolves exactly what the emulator would
  /// paint for each character, and fails on any foreground form the filter must have removed.
  private static func render(
    _ bytes: [UInt8], theme: OttoThemeDefinition
  ) -> [Cell] {
    var cells: [Cell] = []
    var foreground = theme.paper
    var background = theme.ink
    var dim = false
    let text = String(decoding: bytes, as: UTF8.self)
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if character == "\u{1B}" {
        let afterEscape = text.index(after: index)
        guard afterEscape < text.endIndex, text[afterEscape] == "[" else {
          index = afterEscape
          continue
        }
        var end = text.index(after: afterEscape)
        while end < text.endIndex, !(text[end].asciiValue.map { (0x40...0x7E).contains($0) } ?? false) {
          end = text.index(after: end)
        }
        let parameters = String(text[text.index(after: afterEscape)..<end])
        if end < text.endIndex, text[end] == "m" {
          var groups = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
          if parameters.contains(":") { Issue.record("colon-form colour survived: \(parameters)") }
          while !groups.isEmpty {
            let code = groups.removeFirst()
            switch code {
            case 0:
              foreground = theme.paper
              background = theme.ink
              dim = false
            case 2: dim = true
            case 22: dim = false
            case 39: foreground = theme.paper
            case 49: background = theme.ink
            case 30...37, 90...97:
              Issue.record("palette foreground survived: \(code)")
            case 40...47: background = OttoTerminalColors.indexed(code - 40)
            case 100...107: background = OttoTerminalColors.indexed(code - 100 + 8)
            case 38:
              guard groups.count >= 4, groups[0] == 2 else {
                Issue.record("non-truecolor foreground survived: \(parameters)")
                groups.removeAll()
                break
              }
              foreground = ThemeColor(
                red: Double(groups[1]) / 255, green: Double(groups[2]) / 255,
                blue: Double(groups[3]) / 255)
              groups.removeFirst(4)
            case 48:
              if groups.first == 5, groups.count >= 2 {
                background = OttoTerminalColors.indexed(groups[1])
                groups.removeFirst(2)
              } else if groups.first == 2, groups.count >= 4 {
                background = ThemeColor(
                  red: Double(groups[1]) / 255, green: Double(groups[2]) / 255,
                  blue: Double(groups[3]) / 255)
                groups.removeFirst(4)
              }
            default: break
            }
          }
        }
        index = end < text.endIndex ? text.index(after: end) : end
        continue
      }
      cells.append(
        Cell(character: character, foreground: foreground, background: background, dim: dim))
      index = text.index(after: index)
    }
    return cells
  }

  private static func painted(_ cell: Cell) -> ThemeColor {
    // SwiftTerm paints dim text halfway toward the cell background.
    cell.dim ? cell.foreground.blended(over: cell.background, opacity: 0.5) : cell.foreground
  }

  @Test("Every colour a TUI writes is readable on every built-in theme")
  func readableOnEveryTheme() {
    for theme in OttoThemeCatalog.all {
      var filter = TerminalContrastFilter(theme: theme)
      let output = filter.process(Array(Self.sample.utf8))
      let cells = Self.render(output, theme: theme)
      #expect(cells.count > 100)
      for cell in cells where cell.character != " " {
        let ratio = Self.painted(cell).contrastRatio(with: cell.background)
        #expect(
          ratio >= OttoTextContrast.secondary,
          "\(theme.id): '\(cell.character)' at \(ratio)")
      }
      // Undimmed text must reach body contrast; the filter strips dim, so all of it is.
      #expect(cells.allSatisfy { !$0.dim }, "\(theme.id): dim reached the emulator")
    }
  }

  @Test("Body and fine-print floors: bright text reaches 4.5, dim text reaches 3")
  func floorsByRole() throws {
    let theme = OttoThemeCatalog.highfell
    var filter = TerminalContrastFilter(theme: theme)
    let body = Self.render(filter.process(Array("\u{1B}[97mW".utf8)), theme: theme)
    let bodyCell = try #require(body.last)
    #expect(bodyCell.foreground.contrastRatio(with: theme.ink) >= OttoTextContrast.body)
    filter.reset()
    let dim = Self.render(filter.process(Array("\u{1B}[2mW".utf8)), theme: theme)
    let dimCell = try #require(dim.last)
    let ratio = dimCell.foreground.contrastRatio(with: theme.ink)
    #expect(ratio >= OttoTextContrast.secondary)
    // Dim stays visibly quieter than body text.
    #expect(ratio < theme.paper.contrastRatio(with: theme.ink))
  }

  @Test("Explicit backgrounds are honoured and judged against")
  func explicitBackgrounds() {
    for theme in OttoThemeCatalog.all {
      var filter = TerminalContrastFilter(theme: theme)
      // A dark status bar with default text, a blue badge with white text, a pale 256-colour
      // highlight with white text (unreadable as written on any theme).
      let input =
        "\u{1B}[48;5;236mstatus\u{1B}[0m \u{1B}[44;97mbadge\u{1B}[0m \u{1B}[48;5;255;97mpale\u{1B}[0m"
      let cells = Self.render(filter.process(Array(input.utf8)), theme: theme)
      for cell in cells where cell.character != " " {
        let ratio = cell.foreground.contrastRatio(with: cell.background)
        #expect(ratio >= OttoTextContrast.body, "\(theme.id): '\(cell.character)' at \(ratio)")
      }
    }
  }

  @Test("Default text and non-colour sequences pass through byte for byte")
  func passthrough() {
    var filter = TerminalContrastFilter(theme: OttoThemeCatalog.graphite)
    let input =
      "hello \u{1B}[1mbold\u{1B}[0m\r\n\u{1B}[2J\u{1B}[3;4H\u{1B}[?1049h\u{1B}[?1049l"
      + "\u{1B}]0;title;with m\u{07}\u{1B}]8;;https://x.test\u{1B}\\link\u{1B}]8;;\u{1B}\\"
      + "\u{1B}[>4;2m\u{1B}[?25l\u{1B}(B\u{1B}[4:3m"
    #expect(filter.process(Array(input.utf8)) == Array(input.utf8))
  }

  @Test("Sequences split across chunks are rewritten identically")
  func chunking() {
    let theme = OttoThemeCatalog.mistfall
    var whole = TerminalContrastFilter(theme: theme)
    let expected = whole.process(Array(Self.sample.utf8))
    var split = TerminalContrastFilter(theme: theme)
    var output: [UInt8] = []
    for byte in Self.sample.utf8 { output += split.process([byte]) }
    #expect(output == expected)
  }

  @Test("Background changes re-judge the active foreground")
  func backgroundChangeReemitsForeground() {
    let theme = OttoThemeCatalog.graphite
    var filter = TerminalContrastFilter(theme: theme)
    // White text, then a white background arrives in a separate sequence.
    let cells = Self.render(
      filter.process(Array("\u{1B}[97ma\u{1B}[107mb\u{1B}[49mc".utf8)), theme: theme)
    #expect(cells.count == 3)
    for cell in cells {
      #expect(cell.foreground.contrastRatio(with: cell.background) >= OttoTextContrast.body)
    }
  }

  @Test("Save and restore cursor bring the pen back with it")
  func saveRestore() {
    let theme = OttoThemeCatalog.duneveil
    var filter = TerminalContrastFilter(theme: theme)
    // Pen is white (adjusted); save; reset to default; restore; then a bare background change
    // must still re-emit for the restored white pen, not assume default.
    let output = filter.process(
      Array("\u{1B}[97m\u{1B}7\u{1B}[0m\u{1B}8\u{1B}[44mx".utf8))
    let text = String(decoding: output, as: UTF8.self)
    // Bright white (ANSI 15) is (233, 235, 235) and already reads on the blue badge.
    #expect(text.hasSuffix("\u{1B}[44;38;2;233;235;235mx"))
  }

  @Test("A theme change re-judges colours without losing the pen")
  func themeChange() {
    var filter = TerminalContrastFilter(theme: OttoThemeCatalog.graphite)
    _ = filter.process(Array("\u{1B}[97m".utf8))
    let light = OttoThemeCatalog.highfell
    filter.setColors(foreground: light.paper, background: light.ink)
    let cells = Self.render(filter.process(Array("\u{1B}[1mx".utf8)), theme: light)
    #expect(cells.count == 1)
    #expect(cells[0].foreground.contrastRatio(with: light.ink) >= OttoTextContrast.body)
  }
}

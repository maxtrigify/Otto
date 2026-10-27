import Foundation

/// The colours Otto's embedded terminal is configured with, so contrast can be judged against
/// exactly what the emulator paints.
public enum OttoTerminalColors {
  /// The 16 ANSI colours installed into the emulator (Terminal.app's classic set). Explicit
  /// foreground colours never reach the screen unadjusted (see `TerminalContrastFilter`), so
  /// this mainly decides how explicit *background* colours look.
  public static let ansi16: [ThemeColor] = [
    (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
    (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
    (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
    (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
  ].map { ThemeColor(red: Double($0.0) / 255, green: Double($0.1) / 255, blue: Double($0.2) / 255) }

  /// The xterm 256-colour palette: `ansi16`, the 6×6×6 cube, then the 24-step grey ramp. The
  /// emulator is pinned to this strategy so indexed colours mean what TUIs expect.
  public static func indexed(_ index: Int) -> ThemeColor {
    let index = min(max(index, 0), 255)
    if index < 16 { return ansi16[index] }
    if index < 232 {
      let levels = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF]
      let cube = index - 16
      return ThemeColor(
        red: Double(levels[(cube / 36) % 6]) / 255,
        green: Double(levels[(cube / 6) % 6]) / 255,
        blue: Double(levels[cube % 6]) / 255)
    }
    let grey = Double(8 + (index - 232) * 10) / 255
    return ThemeColor(red: grey, green: grey, blue: grey)
  }
}

/// Rewrites terminal output so every foreground colour stays readable on the active theme.
///
/// Agent CLIs pick text colours for a terminal background they assume rather than the one
/// Otto paints: a TUI tuned for a dark terminal writes white and pale-grey text, which
/// vanishes on a light theme, and a light-tuned one writes black on a dark theme. Dim/faint
/// text (SGR 2) halves contrast again. This filter tracks the SGR pen across the byte stream
/// and replaces every explicit foreground with a colour that clears `OttoTextContrast.body`
/// (or `.secondary` for dim text) against the cell's real background — the same idea as
/// iTerm's and Ghostty's "minimum contrast". Backgrounds, cursor movement and everything else
/// pass through untouched, and default-coloured text on the default background is left alone.
public struct TerminalContrastFilter: Sendable {
  enum Spec: Hashable, Sendable {
    case `default`
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
  }

  struct Pen: Hashable, Sendable {
    var foreground = Spec.default
    var background = Spec.default
    var bold = false
    var dim = false
    var inverse = false
  }

  /// What the emulator itself currently holds as its foreground.
  enum Emitted: Equatable, Sendable {
    case `default`
    case rgb(UInt8, UInt8, UInt8)
  }

  private enum ParseState: Sendable {
    case ground
    case escape
    case csi
    /// OSC, DCS, APC, PM or SOS payload; `sawEscape` tracks a possible ST (ESC \).
    case string(sawEscape: Bool)
  }

  public private(set) var foreground: ThemeColor
  public private(set) var background: ThemeColor
  private var pen = Pen()
  private var emitted = Emitted.default
  private var saved: (pen: Pen, emitted: Emitted)?
  private var state = ParseState.ground
  private var csiBuffer: [UInt8] = []
  private var cache: [Pen: Emitted] = [:]

  /// Long CSI sequences are not SGR we can rewrite; flush them verbatim past this length.
  private static let maximumCSILength = 512

  public init(foreground: ThemeColor, background: ThemeColor) {
    self.foreground = foreground
    self.background = background
  }

  public init(theme: OttoThemeDefinition) {
    self.init(foreground: theme.paper, background: theme.ink)
  }

  /// Follows a theme change. The pen survives so already-styled output continues correctly.
  public mutating func setColors(foreground: ThemeColor, background: ThemeColor) {
    guard foreground != self.foreground || background != self.background else { return }
    self.foreground = foreground
    self.background = background
    cache.removeAll()
  }

  /// Matches a terminal reset (RIS) or a fresh replay of the scrollback.
  public mutating func reset() {
    pen = Pen()
    emitted = .default
    saved = nil
    state = .ground
    csiBuffer.removeAll()
  }

  public mutating func process(_ input: some Sequence<UInt8>) -> [UInt8] {
    var output: [UInt8] = []
    output.reserveCapacity(input.underestimatedCount + 16)
    for byte in input {
      switch state {
      case .ground:
        if byte == 0x1B {
          state = .escape
        } else {
          output.append(byte)
        }
      case .escape:
        switch byte {
        case UInt8(ascii: "["):
          state = .csi
          csiBuffer.removeAll(keepingCapacity: true)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"),
          UInt8(ascii: "X"):
          output.append(contentsOf: [0x1B, byte])
          state = .string(sawEscape: false)
        case UInt8(ascii: "c"):
          output.append(contentsOf: [0x1B, byte])
          reset()
        case UInt8(ascii: "7"):
          output.append(contentsOf: [0x1B, byte])
          saved = (pen, emitted)
          state = .ground
        case UInt8(ascii: "8"):
          output.append(contentsOf: [0x1B, byte])
          restore()
          state = .ground
        case 0x1B:
          output.append(0x1B)
        default:
          output.append(contentsOf: [0x1B, byte])
          state = .ground
        }
      case .csi:
        if byte == 0x1B {
          output.append(contentsOf: [0x1B, UInt8(ascii: "[")])
          output.append(contentsOf: csiBuffer)
          state = .escape
        } else if byte == 0x18 || byte == 0x1A {
          // CAN / SUB abort the sequence.
          output.append(contentsOf: [0x1B, UInt8(ascii: "[")])
          output.append(contentsOf: csiBuffer)
          output.append(byte)
          state = .ground
        } else if (0x40...0x7E).contains(byte) {
          finishCSI(final: byte, into: &output)
          state = .ground
        } else {
          csiBuffer.append(byte)
          if csiBuffer.count > Self.maximumCSILength {
            output.append(contentsOf: [0x1B, UInt8(ascii: "[")])
            output.append(contentsOf: csiBuffer)
            csiBuffer.removeAll(keepingCapacity: true)
            state = .ground
          }
        }
      case .string(let sawEscape):
        output.append(byte)
        if byte == 0x07 || (sawEscape && byte == UInt8(ascii: "\\")) {
          state = .ground
        } else {
          state = .string(sawEscape: byte == 0x1B)
        }
      }
    }
    return output
  }

  private mutating func restore() {
    if let saved {
      pen = saved.pen
      emitted = saved.emitted
    } else {
      pen = Pen()
      emitted = .default
    }
  }

  private mutating func finishCSI(final: UInt8, into output: inout [UInt8]) {
    let parameters = csiBuffer
    let isPlainParameters = parameters.allSatisfy {
      ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || $0 == UInt8(ascii: ";")
        || $0 == UInt8(ascii: ":")
    }
    if final == UInt8(ascii: "m"), isPlainParameters {
      rewriteSGR(parameters, into: &output)
      return
    }
    output.append(contentsOf: [0x1B, UInt8(ascii: "[")])
    output.append(contentsOf: parameters)
    output.append(final)
    let text = String(decoding: parameters, as: UTF8.self)
    if final == UInt8(ascii: "p"), text == "!" {
      // DECSTR soft reset clears SGR.
      pen = Pen()
      emitted = .default
    } else if final == UInt8(ascii: "h") || final == UInt8(ascii: "l"),
      text.hasPrefix("?")
    {
      let modes = text.dropFirst().split(separator: ";")
      if modes.contains("1048") || modes.contains("1049") {
        if final == UInt8(ascii: "h") { saved = (pen, emitted) } else { restore() }
      }
    }
  }

  private mutating func rewriteSGR(_ parameters: [UInt8], into output: inout [UInt8]) {
    let groups = String(decoding: parameters, as: UTF8.self)
      .split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    var kept: [String] = []
    var index = 0
    while index < groups.count {
      let group = groups[index]
      if group.contains(":") {
        let sub = group.split(separator: ":", omittingEmptySubsequences: false).map {
          Int($0) ?? 0
        }
        switch sub.first {
        case 38: pen.foreground = Self.colonColor(sub) ?? pen.foreground
        case 48:
          pen.background = Self.colonColor(sub) ?? pen.background
          kept.append(group)
        default: kept.append(group)
        }
        index += 1
        continue
      }
      let code = Int(group) ?? 0
      switch code {
      case 0:
        pen = Pen()
        emitted = .default
        kept.append(group)
      case 1:
        pen.bold = true
        kept.append(group)
      case 2:
        pen.dim = true
      case 22:
        pen.bold = false
        pen.dim = false
        kept.append(group)
      case 7:
        pen.inverse = true
        kept.append(group)
      case 27:
        pen.inverse = false
        kept.append(group)
      case 30...37: pen.foreground = .indexed(code - 30)
      case 90...97: pen.foreground = .indexed(code - 90 + 8)
      case 39: pen.foreground = .default
      case 40...47:
        pen.background = .indexed(code - 40)
        kept.append(group)
      case 100...107:
        pen.background = .indexed(code - 100 + 8)
        kept.append(group)
      case 49:
        pen.background = .default
        kept.append(group)
      case 38, 48, 58:
        let (spec, consumed) = Self.semicolonColor(groups, at: index)
        if code == 38 {
          if let spec { pen.foreground = spec }
        } else {
          if code == 48, let spec { pen.background = spec }
          kept.append(contentsOf: groups[index..<min(groups.count, index + consumed)])
        }
        index += consumed
        continue
      default:
        kept.append(group)
      }
      index += 1
    }

    let desired = resolvedForeground()
    var emittedGroups = kept
    if desired != emitted {
      switch desired {
      case .default: emittedGroups.append("39")
      case .rgb(let r, let g, let b): emittedGroups.append("38;2;\(r);\(g);\(b)")
      }
      emitted = desired
    }
    guard !emittedGroups.isEmpty else { return }
    output.append(contentsOf: [0x1B, UInt8(ascii: "[")])
    output.append(contentsOf: Array(emittedGroups.joined(separator: ";").utf8))
    output.append(UInt8(ascii: "m"))
  }

  /// `38;5;n` / `38;2;r;g;b` (semicolon form). Returns the colour and how many groups it used.
  private static func semicolonColor(_ groups: [String], at index: Int) -> (Spec?, Int) {
    guard index + 1 < groups.count else { return (nil, 1) }
    switch Int(groups[index + 1]) {
    case 5:
      guard index + 2 < groups.count, let value = Int(groups[index + 2]) else {
        return (nil, min(groups.count - index, 3))
      }
      return (.indexed(min(max(value, 0), 255)), 3)
    case 2:
      guard index + 4 < groups.count else { return (nil, groups.count - index) }
      let channels = groups[(index + 2)...(index + 4)].map { UInt8(clamping: Int($0) ?? 0) }
      return (.rgb(channels[0], channels[1], channels[2]), 5)
    default:
      return (nil, 2)
    }
  }

  /// `38:5:n`, `38:2:r:g:b` and `38:2:colourspace:r:g:b` (colon form).
  private static func colonColor(_ sub: [Int]) -> Spec? {
    guard sub.count >= 3 else { return nil }
    switch sub[1] {
    case 5: return .indexed(min(max(sub[2], 0), 255))
    case 2:
      guard sub.count >= 5 else { return nil }
      let channels = sub.suffix(3).map { UInt8(clamping: $0) }
      return .rgb(channels[0], channels[1], channels[2])
    default: return nil
    }
  }

  private func color(_ spec: Spec, isForeground: Bool, bold: Bool) -> ThemeColor {
    switch spec {
    case .default: return isForeground ? foreground : background
    case .indexed(let index):
      // The emulator renders bold low-intensity colours with their bright variant.
      let resolved = isForeground && bold && index < 7 ? index + 8 : index
      return OttoTerminalColors.indexed(resolved)
    case .rgb(let r, let g, let b):
      return ThemeColor(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
  }

  private mutating func resolvedForeground() -> Emitted {
    // Default text on the default background is the theme's own pair: already readable, and
    // leaving it as "default" keeps the emulator following later theme changes.
    if pen.foreground == .default, pen.background == .default, !pen.dim { return .default }
    if let cached = cache[pen] { return cached }
    let result: Emitted
    let text = color(pen.foreground, isForeground: true, bold: pen.bold)
    if pen.inverse {
      // Inverse swaps the roles: the text colour becomes the cell fill. Keep it as written.
      result = pen.foreground == .default ? .default : Self.quantize(text)
    } else {
      let cell = color(pen.background, isForeground: false, bold: false)
      let isDefaultCell = pen.background == .default
      let base = pen.dim ? text.blended(over: cell, opacity: 0.5) : text
      let target = pen.dim ? OttoTextContrast.secondary : OttoTextContrast.body
      // A small margin keeps the 8-bit quantised result above the floor.
      let readable = base.raisingContrast(
        to: target + 0.05, against: cell, toward: isDefaultCell ? foreground : nil)
      result = Self.quantize(readable)
    }
    cache[pen] = result
    return result
  }

  private static func quantize(_ color: ThemeColor) -> Emitted {
    func channel(_ value: Double) -> UInt8 { UInt8(clamping: Int((value * 255).rounded())) }
    return .rgb(channel(color.red), channel(color.green), channel(color.blue))
  }
}

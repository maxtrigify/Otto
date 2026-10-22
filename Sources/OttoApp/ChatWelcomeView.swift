import AppKit
import CoreText
import OttoModels
import SwiftUI

/// Pieces of the blank chat welcome: a small live Otto whose eyes follow the pointer, the
/// suggestion links and the bots that can be brought in. Deliberately quiet; Otto's sparks are
/// the only colour. The composer itself stays owned by `AgentConversationBody`.

enum OttoSerifFont {
  static let registered: Bool = {
    var ok = true
    for name in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
      guard
        let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
      else {
        ok = false
        continue
      }
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        // Already-registered is fine: tests and previews may load the bundle more than once.
        ok =
          ok
          && (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains(
            "Instrument Serif") == true
      }
    }
    return ok
  }()
}

extension Font {
  /// Editorial serif used only for the blank chat greeting. Falls back to the display face.
  static func ottoSerif(_ size: CGFloat, italic: Bool = false) -> Font {
    guard OttoSerifFont.registered else { return ottoDisplay(size) }
    let font = Font.custom("Instrument Serif", size: size, relativeTo: .largeTitle)
    return italic ? font.italic() : font
  }
}

/// Otto drawn from the brand mark's geometry (two round bodies, big eyes, nub feet, sparks) so
/// the pupils can move. `look` is a unit-ish vector toward where Otto should look.
struct OttoFace: View {
  var size: CGFloat
  var look: CGSize = .zero
  var body_: Color = Color(red: 0.11, green: 0.12, blue: 0.15)
  var showsSparks = true
  var blinking = false

  var body: some View {
    Canvas { context, canvasSize in
      let k = canvasSize.width / 260
      func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: (x - r) * k, y: (y - r) * k, width: 2 * r * k, height: 2 * r * k))
      }
      let ink = GraphicsContext.Shading.color(body_)
      let white = GraphicsContext.Shading.color(Color(red: 0.965, green: 0.957, blue: 0.933))

      if showsSparks {
        let spark = Color(red: 1, green: 0.353, blue: 0.122)
        for (a, b) in [
          (CGPoint(x: 206, y: 40), CGPoint(x: 211, y: 58)),
          (CGPoint(x: 228, y: 54), CGPoint(x: 240, y: 44)),
          (CGPoint(x: 232, y: 78), CGPoint(x: 250, y: 80)),
        ] {
          var line = Path()
          line.move(to: CGPoint(x: a.x * k, y: a.y * k))
          line.addLine(to: CGPoint(x: b.x * k, y: b.y * k))
          context.stroke(line, with: .color(spark), style: StrokeStyle(lineWidth: 11 * k, lineCap: .round))
        }
      }
      for foot in [CGRect(x: 58, y: 196, width: 42, height: 26), CGRect(x: 152, y: 196, width: 46, height: 26)] {
        let r = CGRect(x: foot.minX * k, y: foot.minY * k, width: foot.width * k, height: foot.height * k)
        context.fill(Path(roundedRect: r, cornerRadius: 13 * k), with: ink)
      }
      context.fill(circle(80, 150, 60), with: ink)
      context.fill(circle(172, 124, 76), with: ink)

      if blinking {
        for (x, y, w) in [(CGFloat(74), CGFloat(152), CGFloat(30)), (168, 122, 40)] {
          var lid = Path()
          lid.move(to: CGPoint(x: (x - w) * k, y: y * k))
          lid.addQuadCurve(
            to: CGPoint(x: (x + w) * k, y: y * k), control: CGPoint(x: x * k, y: (y + 10) * k))
          context.stroke(lid, with: white, style: StrokeStyle(lineWidth: 6 * k, lineCap: .round))
        }
        return
      }
      context.fill(circle(74, 152, 35), with: white)
      context.fill(circle(168, 122, 48), with: white)
      // Pupils rest up-and-right like the brand mark, then travel toward `look`.
      let dx = max(-1, min(1, look.width)) * 12
      let dy = max(-1, min(1, look.height)) * 12
      context.fill(circle(74 + 4 + dx * 0.8, 152 - 6 + dy * 0.8, 18), with: ink)
      context.fill(circle(74 + 11 + dx * 0.8, 152 - 14 + dy * 0.8, 5), with: white)
      context.fill(circle(168 + 6 + dx, 122 - 8 + dy, 23), with: ink)
      context.fill(circle(168 + 15 + dx, 122 - 18 + dy, 6.5), with: white)
    }
    .frame(width: size, height: size)
    // The faint light edge from `OttoMark` keeps the ink body readable on dark themes.
    .shadow(color: .white.opacity(0.45), radius: 0.6)
    .shadow(color: .white.opacity(0.22), radius: 1.4)
    .accessibilityHidden(true)
  }
}

/// One suggestion under the centered composer: quiet text that brightens on hover, separated
/// from its neighbour by a small dot. Seeds the composer rather than sending.
struct WelcomeLink: View {
  @Environment(\.ottoPalette) private var palette
  let label: String
  let leadingDot: Bool
  let scale: Double
  let pick: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 0) {
      if leadingDot {
        Circle()
          .fill(palette.muted.opacity(0.45))
          .frame(width: 2.5 * scale, height: 2.5 * scale)
          .padding(.horizontal, 9 * scale)
          .accessibilityHidden(true)
      }
      Button(action: pick) {
        Text(label)
          .font(.ottoDisplay(max(9, 10.5 * scale)))
          .foregroundStyle(hovering ? palette.paper : palette.paper.opacity(0.62))
          .lineLimit(1)
          .padding(.vertical, 4 * scale)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.14), value: hovering)
      .accessibilityLabel("Use prompt: \(label)")
    }
  }
}

struct WelcomeSuggestion: Identifiable {
  let symbol: String
  let label: String
  /// Text placed in the composer; the person finishes it and presses Return.
  let seed: String
  var id: String { label }

  static let workspace: [WelcomeSuggestion] = [
    .init(
      symbol: "sun.max", label: "Brief me on today",
      seed: "Brief me on today: my calendar, inbox and anything waiting on me."),
    .init(symbol: "doc.text", label: "Draft a doc", seed: "Draft a doc about "),
    .init(symbol: "globe", label: "Research a website", seed: "Research this website and summarise it: "),
    .init(symbol: "bolt", label: "Automate something", seed: "Set up an automation that "),
  ]

  static let code: [WelcomeSuggestion] = [
    .init(symbol: "binoculars", label: "Explore this code", seed: "Explore and explain this codebase."),
    .init(symbol: "hammer", label: "Build a feature", seed: "Build "),
    .init(symbol: "text.magnifyingglass", label: "Review my changes", seed: "Review my uncommitted changes and suggest improvements."),
    .init(symbol: "ladybug", label: "Fix a failure", seed: "Find and fix "),
  ]

  /// Code prompts only make sense when the chat works inside a git checkout.
  static func forDirectory(_ path: String?) -> [WelcomeSuggestion] {
    guard let path, !path.isEmpty else { return workspace }
    let git = URL(fileURLWithPath: path).appendingPathComponent(".git").path
    return FileManager.default.fileExists(atPath: git) ? code : workspace
  }
}

enum WelcomeGreeting {
  static func text(now: Date = Date()) -> String {
    let hour = Calendar.current.component(.hour, from: now)
    let part = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
    let first =
      FirstRunPreferences.preferredFirstName
      ?? NSFullUserName().split(separator: " ").first.map(String.init)
    return first.map { "\(part), \($0)." } ?? "\(part)."
  }
}

/// Wraps chips onto as many lines as they need, centring each line.
struct WelcomeChipFlow: Layout {
  var spacing: CGFloat = 8

  private func rows(width: CGFloat, subviews: Subviews) -> [[(Int, CGSize)]] {
    var rows: [[(Int, CGSize)]] = [[]]
    var x: CGFloat = 0
    for (index, view) in subviews.enumerated() {
      let size = view.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        rows.append([])
        x = 0
      }
      rows[rows.count - 1].append((index, size))
      x += size.width + spacing
    }
    return rows
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = min(proposal.width ?? 600, 10_000)
    let lines = rows(width: width, subviews: subviews)
    let height = lines.reduce(CGFloat(0)) { total, line in
      total + (line.map(\.1.height).max() ?? 0)
    } + spacing * CGFloat(max(0, lines.count - 1))
    let widest = lines.map { line in
      line.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(0, line.count - 1))
    }.max() ?? 0
    return CGSize(width: min(widest, width), height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for line in rows(width: bounds.width, subviews: subviews) {
      let lineWidth =
        line.reduce(CGFloat(0)) { $0 + $1.1.width } + spacing * CGFloat(max(0, line.count - 1))
      var x = bounds.midX - lineWidth / 2
      let height = line.map(\.1.height).max() ?? 0
      for (index, size) in line {
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += height + spacing
    }
  }
}

/// One @mentionable bot in the welcome's "or bring in" row.
struct WelcomeCrewFace: View {
  @Environment(\.ottoPalette) private var palette
  let profile: AgentProfile
  let scale: Double
  let pick: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: pick) {
      BotAvatarView(
        presentation: BotAvatarPresentation(id: profile.id, name: profile.name),
        size: 18 * scale,
        showsStateBadge: false
      )
      .opacity(hovering ? 1 : 0.7)
      .offset(y: hovering ? -2 : 0)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .help("@\(profile.handle) · \(profile.role)")
    .accessibilityLabel("Mention \(profile.name)")
  }
}

import OttoModels
import SwiftUI

/// Otto and his family, drawn from the brand mark's geometry (two round bodies, big eyes, nub
/// feet) so the eyes can move and react. Otto himself is the dark body with orange sparks;
/// bots wear their own colour and one accessory from `BotFamily`.
struct OttoFace: View {
  enum Eyes: Equatable {
    case open
    case closed
    case crossed
  }

  static let ink = Color(red: 0.11, green: 0.12, blue: 0.15)

  var size: CGFloat
  /// A unit-ish vector toward where the eyes should look.
  var look: CGSize = .zero
  var bodyColor: Color = OttoFace.ink
  var showsSparks = true
  var accessory: BotFamily.Accessory = .none
  var eyes: Eyes = .open
  var blinking = false

  var body: some View {
    let isOtto = showsSparks
    Canvas { context, canvasSize in
      Self.draw(
        in: &context, width: canvasSize.width, look: look, bodyColor: bodyColor,
        sparks: showsSparks, accessory: accessory, eyes: blinking ? .closed : eyes)
    }
    .frame(width: size, height: size)
    // The faint light edge from `OttoMark` keeps Otto's ink body readable on dark themes.
    .shadow(color: .white.opacity(isOtto ? 0.45 : 0), radius: 0.6)
    .shadow(color: .white.opacity(isOtto ? 0.22 : 0), radius: 1.4)
    .accessibilityHidden(true)
  }

  // swiftlint:disable:next function_parameter_count
  private static func draw(
    in context: inout GraphicsContext, width: CGFloat, look: CGSize, bodyColor: Color,
    sparks: Bool, accessory: BotFamily.Accessory, eyes: Eyes
  ) {
    let k = width / 260
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
      Path(ellipseIn: CGRect(x: (x - r) * k, y: (y - r) * k, width: 2 * r * k, height: 2 * r * k))
    }
    func stroke(_ path: Path, _ color: Color, _ lineWidth: CGFloat) {
      context.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
    }
    let fill = GraphicsContext.Shading.color(bodyColor)
    let white = Color(red: 0.965, green: 0.957, blue: 0.933)

    if sparks {
      let spark = Color(red: 1, green: 0.353, blue: 0.122)
      for (a, b) in [((206, 40), (211, 58)), ((228, 54), (240, 44)), ((232, 78), (250, 80))] {
        var line = Path()
        line.move(to: point(CGFloat(a.0), CGFloat(a.1)))
        line.addLine(to: point(CGFloat(b.0), CGFloat(b.1)))
        stroke(line, spark, 11)
      }
    }
    for foot in [CGRect(x: 58, y: 196, width: 42, height: 26), CGRect(x: 152, y: 196, width: 46, height: 26)] {
      let rect = CGRect(x: foot.minX * k, y: foot.minY * k, width: foot.width * k, height: foot.height * k)
      context.fill(Path(roundedRect: rect, cornerRadius: 13 * k), with: fill)
    }
    context.fill(circle(80, 150, 60), with: fill)
    context.fill(circle(172, 124, 76), with: fill)

    switch eyes {
    case .closed:
      for (x, y, w) in [(CGFloat(74), CGFloat(152), CGFloat(30)), (168, 122, 40)] {
        var lid = Path()
        lid.move(to: point(x - w, y))
        lid.addQuadCurve(to: point(x + w, y), control: point(x, y + 10))
        stroke(lid, white, 6)
      }
    case .crossed:
      context.fill(circle(74, 152, 35), with: .color(white))
      context.fill(circle(168, 122, 48), with: .color(white))
      for (x, y, r) in [(CGFloat(74), CGFloat(152), CGFloat(13)), (168, 122, 17)] {
        var cross = Path()
        cross.move(to: point(x - r, y - r))
        cross.addLine(to: point(x + r, y + r))
        cross.move(to: point(x + r, y - r))
        cross.addLine(to: point(x - r, y + r))
        stroke(cross, bodyColor, 7)
      }
    case .open:
      context.fill(circle(74, 152, 35), with: .color(white))
      context.fill(circle(168, 122, 48), with: .color(white))
      // Pupils rest up-and-right like the brand mark, then travel toward `look`.
      let dx = max(-1, min(1, look.width)) * 12
      let dy = max(-1, min(1, look.height)) * 12
      context.fill(circle(78 + dx * 0.8, 146 + dy * 0.8, 18), with: fill)
      context.fill(circle(85 + dx * 0.8, 138 + dy * 0.8, 5), with: .color(white))
      context.fill(circle(174 + dx, 114 + dy, 23), with: fill)
      context.fill(circle(183 + dx, 104 + dy, 6.5), with: .color(white))
    }

    drawAccessory(accessory, in: &context, k: k)
  }

  private static func drawAccessory(
    _ accessory: BotFamily.Accessory, in context: inout GraphicsContext, k: CGFloat
  ) {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
      Path(ellipseIn: CGRect(x: (x - r) * k, y: (y - r) * k, width: 2 * r * k, height: 2 * r * k))
    }
    func stroke(_ path: Path, _ color: Color, _ lineWidth: CGFloat) {
      context.stroke(
        path, with: .color(color),
        style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
    }
    let light = Color(red: 0.91, green: 0.93, blue: 0.95)
    switch accessory {
    case .none:
      break
    case .glasses:
      let gold = Color(red: 0.95, green: 0.76, blue: 0.31)
      stroke(circle(74, 152, 40), gold, 7)
      stroke(circle(168, 122, 53), gold, 7)
      var bridge = Path()
      bridge.move(to: point(112, 140))
      bridge.addQuadCurve(to: point(122, 130), control: point(116, 132))
      stroke(bridge, gold, 7)
    case .headset:
      var band = Path()
      band.move(to: point(110, 74))
      band.addQuadCurve(to: point(236, 80), control: point(172, 12))
      stroke(band, light, 10)
      context.fill(
        Path(roundedRect: CGRect(x: 226 * k, y: 86 * k, width: 22 * k, height: 44 * k), cornerRadius: 10 * k),
        with: .color(light))
      var mic = Path()
      mic.move(to: point(238, 128))
      mic.addQuadCurve(to: point(198, 180), control: point(238, 172))
      stroke(mic, light, 6)
      context.fill(circle(196, 180, 8), with: .color(light))
    case .hardHat:
      let yellow = Color(red: 1, green: 0.81, blue: 0.2)
      var dome = Path()
      dome.move(to: point(112, 70))
      dome.addQuadCurve(to: point(234, 70), control: point(172, -8))
      dome.closeSubpath()
      context.fill(dome, with: .color(yellow))
      context.fill(
        Path(roundedRect: CGRect(x: 98 * k, y: 64 * k, width: 150 * k, height: 14 * k), cornerRadius: 7 * k),
        with: .color(yellow))
      context.fill(
        Path(roundedRect: CGRect(x: 166 * k, y: 22 * k, width: 12 * k, height: 44 * k), cornerRadius: 6 * k),
        with: .color(Color(red: 0.9, green: 0.7, blue: 0)))
    case .beret:
      let pink = Color(red: 1, green: 0.48, blue: 0.66)
      var beret = context
      beret.translateBy(x: 160 * k, y: 52 * k)
      beret.rotate(by: .degrees(-14))
      beret.fill(
        Path(ellipseIn: CGRect(x: -70 * k, y: -16 * k, width: 140 * k, height: 44 * k)), with: .color(pink))
      beret.fill(
        Path(ellipseIn: CGRect(x: -8 * k, y: -26 * k, width: 16 * k, height: 16 * k)), with: .color(pink))
    case .antenna:
      var stalk = Path()
      stalk.move(to: point(64, 92))
      stalk.addQuadCurve(to: point(80, 32), control: point(58, 52))
      stroke(stalk, light, 7)
      context.fill(circle(82, 30, 12), with: .color(Color(red: 0.36, green: 0.95, blue: 0.65)))
    }
  }
}

extension OttoFace {
  /// A bot as a member of Otto's family, reacting to its state.
  init(bot accessory: BotFamily.Accessory, color: Color, state: BotAvatarState, size: CGFloat) {
    self.init(
      size: size,
      look: state == .working ? CGSize(width: 0.7, height: -0.7) : state == .needsUser ? CGSize(width: -0.4, height: 0.5) : .zero,
      bodyColor: color,
      showsSparks: false,
      accessory: accessory,
      eyes: state == .failed ? .crossed : state == .offline ? .closed : .open)
  }
}

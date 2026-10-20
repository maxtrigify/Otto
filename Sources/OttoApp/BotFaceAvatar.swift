import OttoModels
import SwiftUI

/// A bot's face, drawn rather than imported. Two eyes and a mouth carry more identity at 18pt
/// than an emoji does, and because the geometry is code the face can answer for the bot: it
/// blinks while idle, scans while working, looks straight at you when it needs an answer, and
/// closes its eyes when the bot is offline.
///
/// Only the features are drawn here. The coloured plate and the shape mask stay in
/// `BotAvatarView`, so a face composes with the colour and shape the user already picked.
struct BotFaceAvatar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ottoWindowIsActive) private var windowIsActive

  let faceID: String
  let state: BotAvatarState
  let color: Color
  let size: CGFloat

  /// Rail rows render dozens of avatars at 18pt, where a blink is illegible and a per-frame
  /// redraw is pure cost. Faces animate only where they are large enough to read.
  private var animates: Bool {
    size >= 26 && !reduceMotion && windowIsActive && state != .offline
  }

  var body: some View {
    Group {
      if animates {
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
          canvas(at: timeline.date.timeIntervalSinceReferenceDate)
        }
      } else {
        canvas(at: 0)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private func canvas(at time: TimeInterval) -> some View {
    let geometry = BotFaceGeometry.face(for: faceID)
    let animation = BotFaceAnimation(
      geometry: geometry,
      state: state,
      time: animates ? time : nil,
      seed: BotFaceGeometry.seed(for: faceID)
    )
    return Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
      BotFaceRenderer.draw(
        animation, in: &context, size: canvasSize, color: color)
    }
  }
}

// MARK: - Geometry

/// One face's fixed proportions, in a unit square. Everything scales from here, so a face
/// reads the same at 18pt in the rail and 56pt in the hire sheet.
struct BotFaceGeometry: Equatable {
  var eyeRadiusX: CGFloat
  var eyeRadiusY: CGFloat
  /// Distance of each eye's centre from the vertical midline.
  var eyeOffsetX: CGFloat
  var eyeCentreY: CGFloat
  /// 0 draws an ellipse; above 0 rounds a rectangle by that fraction of its width.
  var eyeCornerFraction: CGFloat
  var mouthHalfWidth: CGFloat
  /// Positive smiles, negative frowns, zero draws a flat line.
  var mouthCurve: CGFloat
  var mouthCentreY: CGFloat
  var browTilt: CGFloat
  var hasBrows: Bool
  var isCyclops: Bool

  static func face(for id: String) -> BotFaceGeometry {
    switch id {
    case "face.sol":
      // Arc eyes and a wide smile: permanently delighted.
      return BotFaceGeometry(
        eyeRadiusX: 0.10, eyeRadiusY: 0.055, eyeOffsetX: 0.17, eyeCentreY: 0.41,
        eyeCornerFraction: 0.5, mouthHalfWidth: 0.17, mouthCurve: 0.13, mouthCentreY: 0.62,
        browTilt: 0, hasBrows: false, isCyclops: false)
    case "face.mochi":
      // Oversized eyes, tiny mouth: perpetually curious.
      return BotFaceGeometry(
        eyeRadiusX: 0.115, eyeRadiusY: 0.125, eyeOffsetX: 0.19, eyeCentreY: 0.44,
        eyeCornerFraction: 0, mouthHalfWidth: 0.05, mouthCurve: 0.04, mouthCentreY: 0.69,
        browTilt: 0, hasBrows: false, isCyclops: false)
    case "face.bit":
      // Square eyes on a narrow line: the machine in the roster.
      return BotFaceGeometry(
        eyeRadiusX: 0.075, eyeRadiusY: 0.075, eyeOffsetX: 0.17, eyeCentreY: 0.43,
        eyeCornerFraction: 0.22, mouthHalfWidth: 0.13, mouthCurve: 0, mouthCentreY: 0.66,
        browTilt: 0, hasBrows: false, isCyclops: false)
    case "face.nox":
      // Half-lidded under flat brows: unimpressed by everything. Any tilt at all tipped this
      // into anger, so the brows stay level and the lids do the work.
      return BotFaceGeometry(
        eyeRadiusX: 0.10, eyeRadiusY: 0.048, eyeOffsetX: 0.18, eyeCentreY: 0.44,
        eyeCornerFraction: 0.4, mouthHalfWidth: 0.11, mouthCurve: -0.02, mouthCentreY: 0.67,
        browTilt: 0, hasBrows: true, isCyclops: false)
    case "face.vex":
      // Brows down toward the nose: the reviewer who finds things. Tilting them the other way
      // read as worried rather than sharp.
      return BotFaceGeometry(
        eyeRadiusX: 0.085, eyeRadiusY: 0.07, eyeOffsetX: 0.175, eyeCentreY: 0.46,
        eyeCornerFraction: 0, mouthHalfWidth: 0.12, mouthCurve: -0.05, mouthCentreY: 0.69,
        browTilt: 0.13, hasBrows: true, isCyclops: false)
    case "face.echo":
      // A single wide eye. Strange on purpose, and unmistakable in a list.
      return BotFaceGeometry(
        eyeRadiusX: 0.155, eyeRadiusY: 0.155, eyeOffsetX: 0, eyeCentreY: 0.43,
        eyeCornerFraction: 0, mouthHalfWidth: 0.10, mouthCurve: 0.05, mouthCentreY: 0.74,
        browTilt: 0, hasBrows: false, isCyclops: true)
    case "face.zip":
      // Close-set eyes and a grin that runs past them: eager. The grin carries it, so no brows.
      return BotFaceGeometry(
        eyeRadiusX: 0.06, eyeRadiusY: 0.075, eyeOffsetX: 0.125, eyeCentreY: 0.40,
        eyeCornerFraction: 0, mouthHalfWidth: 0.20, mouthCurve: 0.11, mouthCentreY: 0.62,
        browTilt: 0, hasBrows: false, isCyclops: false)
    default:
      // face.pip — the friendly default.
      return BotFaceGeometry(
        eyeRadiusX: 0.09, eyeRadiusY: 0.10, eyeOffsetX: 0.175, eyeCentreY: 0.42,
        eyeCornerFraction: 0, mouthHalfWidth: 0.13, mouthCurve: 0.08, mouthCentreY: 0.66,
        browTilt: 0, hasBrows: false, isCyclops: false)
    }
  }

  /// A stable per-face offset so a row of avatars never blinks in unison, which reads as a
  /// glitch rather than as a set of separate characters.
  static func seed(for id: String) -> Double {
    let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return Double(hash % 1000) / 1000.0
  }
}

// MARK: - Animation

/// The face's resolved pose for one frame: how open the eyes are, where they are looking, and
/// how the mouth is shaped. Keeping this separate from drawing makes the expression rules
/// readable and lets the static case reuse the same code path with `time` nil.
struct BotFaceAnimation {
  let geometry: BotFaceGeometry
  /// 1 is fully open, 0 is shut.
  let eyeOpenness: CGFloat
  let gaze: CGSize
  let mouthCurve: CGFloat
  let eyeScale: CGFloat
  let browLift: CGFloat

  init(geometry: BotFaceGeometry, state: BotAvatarState, time: TimeInterval?, seed: Double) {
    self.geometry = geometry

    guard let time else {
      // The still pose. Offline keeps its eyes closed; everything else rests open.
      eyeOpenness = state == .offline ? 0.08 : 1
      gaze = .zero
      mouthCurve = BotFaceAnimation.restingMouth(geometry: geometry, state: state)
      eyeScale = state == .needsUser ? 1.12 : 1
      browLift = state == .needsUser ? 0.22 : 0
      return
    }

    let t = time + seed * 10

    // Blink: a brief close on a loose cycle, so faces feel alive without demanding attention.
    let blinkPeriod: Double = state == .working ? 2.6 : 4.4
    let phase = (t.truncatingRemainder(dividingBy: blinkPeriod)) / blinkPeriod
    let blinkWidth = 0.055
    if phase < blinkWidth {
      let progress = phase / blinkWidth
      // Down and back up within the window.
      eyeOpenness = CGFloat(abs(cos(progress * .pi)))
    } else {
      eyeOpenness = 1
    }

    switch state {
    case .working:
      // Reading something: the eyes track left to right and back.
      gaze = CGSize(width: CGFloat(sin(t * 1.9)) * 0.030, height: CGFloat(sin(t * 0.7)) * 0.008)
      eyeScale = 0.94
      browLift = 0
    case .needsUser:
      // Looking straight at you, eyes a little wider, brows up.
      gaze = .zero
      eyeScale = 1.12
      browLift = 0.22
    case .failed:
      gaze = CGSize(width: 0, height: 0.022)
      eyeScale = 0.9
      browLift = -0.1
    case .offline:
      gaze = .zero
      eyeScale = 1
      browLift = 0
    case .idle:
      // A slow drift, so an idle bot looks thoughtful rather than frozen.
      gaze = CGSize(width: CGFloat(sin(t * 0.44)) * 0.022, height: CGFloat(sin(t * 0.31)) * 0.010)
      eyeScale = 1
      browLift = 0
    }

    mouthCurve = BotFaceAnimation.restingMouth(geometry: geometry, state: state)
  }

  private static func restingMouth(geometry: BotFaceGeometry, state: BotAvatarState) -> CGFloat {
    switch state {
    case .failed: return -abs(geometry.mouthCurve) - 0.04
    case .needsUser: return geometry.mouthCurve * 0.35
    case .offline: return 0
    case .working, .idle: return geometry.mouthCurve
    }
  }
}

// MARK: - Rendering

enum BotFaceRenderer {
  static func draw(
    _ animation: BotFaceAnimation, in context: inout GraphicsContext, size: CGSize, color: Color
  ) {
    let unit = min(size.width, size.height)
    let originX = size.width / 2
    let geometry = animation.geometry
    let shading = GraphicsContext.Shading.color(color)

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: originX + x * unit, y: y * unit)
    }

    // Eyes. Openness squashes the height and keeps the centre, which is what a real blink does.
    let openness = max(0.06, animation.eyeOpenness)
    let radiusX = geometry.eyeRadiusX * animation.eyeScale
    let radiusY = geometry.eyeRadiusY * animation.eyeScale * openness
    let eyeCentres: [CGFloat] =
      geometry.isCyclops ? [0] : [-geometry.eyeOffsetX, geometry.eyeOffsetX]

    for centreX in eyeCentres {
      let centre = point(
        centreX + animation.gaze.width,
        geometry.eyeCentreY + animation.gaze.height)
      let rect = CGRect(
        x: centre.x - radiusX * unit,
        y: centre.y - radiusY * unit,
        width: radiusX * 2 * unit,
        height: radiusY * 2 * unit)
      let path: Path =
        geometry.eyeCornerFraction > 0
        ? Path(roundedRect: rect, cornerRadius: rect.height * geometry.eyeCornerFraction)
        : Path(ellipseIn: rect)
      context.fill(path, with: shading)
    }

    // Brows sit above the eyes and lift when the bot needs an answer.
    if geometry.hasBrows {
      let browY = geometry.eyeCentreY - geometry.eyeRadiusY - 0.075 - animation.browLift * 0.05
      let browHalf = geometry.eyeRadiusX * 1.05
      for centreX in eyeCentres {
        // Tilt mirrors across the midline so the pair reads as one expression.
        let direction: CGFloat = centreX < 0 ? 1 : -1
        let tilt = geometry.browTilt * direction
        var brow = Path()
        brow.move(to: point(centreX - browHalf, browY - tilt))
        brow.addLine(to: point(centreX + browHalf, browY + tilt))
        context.stroke(
          brow, with: shading,
          style: StrokeStyle(lineWidth: max(1, unit * 0.035), lineCap: .round))
      }
    }

    // Mouth. A flat curve draws as a line, so `mouthCurve` alone covers smile, frown and deadpan.
    var mouth = Path()
    let mouthY = geometry.mouthCentreY
    mouth.move(to: point(-geometry.mouthHalfWidth, mouthY))
    mouth.addQuadCurve(
      to: point(geometry.mouthHalfWidth, mouthY),
      control: point(0, mouthY + animation.mouthCurve * 2))
    context.stroke(
      mouth, with: shading,
      style: StrokeStyle(lineWidth: max(1, unit * 0.042), lineCap: .round))
  }
}

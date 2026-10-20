import SwiftUI

/// Declarative description of a painterly procedural landscape backdrop:
/// a sky gradient, optional sun glow and light rays, layered ridgelines
/// (back to front, lighter to darker for aerial perspective), drifting mist
/// and clouds. Everything but mist, clouds, and ray shimmer is static, so
/// the animated result stays calm and the reduced-motion still looks intact.
struct LandscapeScene {
  struct Ridge {
    /// Fractions of canvas height/width; seed varies the silhouette per ridge.
    var baseY: Double
    var amplitude: Double
    var frequency: Double
    var seed: UInt64
    var color: Color
    /// 0 = rolling hills, 1 = sharp alpine peaks.
    var jaggedness: Double = 0
  }

  struct MistBand {
    var centerY: Double
    var height: Double
    var opacity: Double
    var driftSpeed: Double  // canvas widths per second, signed
    var seed: UInt64
  }

  struct Cloud {
    var y: Double
    var scale: Double
    var opacity: Double
    var driftSpeed: Double
    var seed: UInt64
  }

  var skyTop: Color
  var skyHorizon: Color
  var horizonY: Double
  var sun: (position: CGPoint, color: Color, radius: Double)?
  var rayColor: Color?
  var ridges: [Ridge]
  var mist: [MistBand]
  var clouds: [Cloud]
  var mistColor: Color = .white

  static let builtIn: [String: LandscapeScene] = [
    "highfell": highfell, "silverbough": silverbough, "mistfall": mistfall, "duneveil": duneveil,
    "velvet": velvet,
  ]

  /// Plum twilight for the matte theme: hazy dusk glow, mauve ridges, low rose mist.
  /// Deliberately no rays and gentle drift only — matte surfaces want no specular sparkle.
  static let velvet = LandscapeScene(
    skyTop: Color(red: 0.15, green: 0.10, blue: 0.21),
    skyHorizon: Color(red: 0.42, green: 0.24, blue: 0.33),
    horizonY: 0.58,
    sun: (CGPoint(x: 0.68, y: 0.40), Color(red: 0.92, green: 0.62, blue: 0.52), 0.30),
    rayColor: nil,
    ridges: [
      Ridge(
        baseY: 0.50, amplitude: 0.13, frequency: 4.4, seed: 131,
        color: Color(red: 0.33, green: 0.21, blue: 0.34), jaggedness: 0.55),
      Ridge(
        baseY: 0.66, amplitude: 0.09, frequency: 3.2, seed: 139,
        color: Color(red: 0.23, green: 0.14, blue: 0.25), jaggedness: 0.3),
      Ridge(
        baseY: 0.82, amplitude: 0.06, frequency: 2.3, seed: 149,
        color: Color(red: 0.14, green: 0.085, blue: 0.16)),
    ],
    mist: [
      MistBand(centerY: 0.56, height: 0.09, opacity: 0.22, driftSpeed: 0.005, seed: 47),
      MistBand(centerY: 0.72, height: 0.10, opacity: 0.18, driftSpeed: -0.004, seed: 51),
    ],
    clouds: [
      Cloud(y: 0.14, scale: 1.0, opacity: 0.20, driftSpeed: 0.005, seed: 55),
      Cloud(y: 0.26, scale: 0.7, opacity: 0.16, driftSpeed: 0.008, seed: 59),
    ],
    mistColor: Color(red: 0.86, green: 0.68, blue: 0.72)
  )

  /// Dramatic verdant highlands under a golden sky.
  static let highfell = LandscapeScene(
    skyTop: Color(red: 0.99, green: 0.95, blue: 0.82),
    skyHorizon: Color(red: 0.90, green: 0.88, blue: 0.70),
    horizonY: 0.62,
    sun: (CGPoint(x: 0.78, y: 0.18), Color(red: 1.0, green: 0.93, blue: 0.72), 0.30),
    rayColor: nil,
    ridges: [
      Ridge(
        baseY: 0.50, amplitude: 0.16, frequency: 5.2, seed: 11,
        color: Color(red: 0.66, green: 0.73, blue: 0.64), jaggedness: 0.85),
      Ridge(
        baseY: 0.64, amplitude: 0.10, frequency: 3.6, seed: 23,
        color: Color(red: 0.50, green: 0.62, blue: 0.45), jaggedness: 0.4),
      Ridge(
        baseY: 0.80, amplitude: 0.06, frequency: 2.4, seed: 37,
        color: Color(red: 0.34, green: 0.50, blue: 0.30)),
    ],
    mist: [
      MistBand(centerY: 0.60, height: 0.10, opacity: 0.35, driftSpeed: 0.008, seed: 5),
      MistBand(centerY: 0.74, height: 0.08, opacity: 0.25, driftSpeed: -0.005, seed: 9),
    ],
    clouds: [
      Cloud(y: 0.14, scale: 1.0, opacity: 0.5, driftSpeed: 0.006, seed: 3),
      Cloud(y: 0.26, scale: 0.7, opacity: 0.35, driftSpeed: 0.010, seed: 7),
    ]
  )

  /// Silver forest valley — low mist, pale gold light rays.
  static let silverbough = LandscapeScene(
    skyTop: Color(red: 0.93, green: 0.96, blue: 0.97),
    skyHorizon: Color(red: 0.97, green: 0.95, blue: 0.86),
    horizonY: 0.58,
    sun: (CGPoint(x: 0.24, y: 0.12), Color(red: 1.0, green: 0.97, blue: 0.85), 0.34),
    rayColor: Color(red: 1.0, green: 0.96, blue: 0.80),
    ridges: [
      Ridge(
        baseY: 0.54, amplitude: 0.09, frequency: 4.0, seed: 41,
        color: Color(red: 0.74, green: 0.81, blue: 0.79), jaggedness: 0.2),
      Ridge(
        baseY: 0.68, amplitude: 0.08, frequency: 3.0, seed: 53,
        color: Color(red: 0.60, green: 0.70, blue: 0.66), jaggedness: 0.1),
      Ridge(
        baseY: 0.83, amplitude: 0.05, frequency: 2.2, seed: 67,
        color: Color(red: 0.44, green: 0.57, blue: 0.51)),
    ],
    mist: [
      MistBand(centerY: 0.58, height: 0.12, opacity: 0.45, driftSpeed: 0.006, seed: 13),
      MistBand(centerY: 0.72, height: 0.10, opacity: 0.40, driftSpeed: -0.004, seed: 17),
      MistBand(centerY: 0.88, height: 0.10, opacity: 0.30, driftSpeed: 0.003, seed: 19),
    ],
    clouds: [
      Cloud(y: 0.10, scale: 0.8, opacity: 0.30, driftSpeed: 0.005, seed: 21)
    ]
  )

  /// Ink-wash mountains dissolving into mist.
  static let mistfall = LandscapeScene(
    skyTop: Color(red: 0.96, green: 0.96, blue: 0.95),
    skyHorizon: Color(red: 0.90, green: 0.90, blue: 0.89),
    horizonY: 0.55,
    sun: nil,
    rayColor: nil,
    ridges: [
      Ridge(
        baseY: 0.40, amplitude: 0.14, frequency: 4.6, seed: 71,
        color: Color(red: 0.79, green: 0.80, blue: 0.81), jaggedness: 0.7),
      Ridge(
        baseY: 0.58, amplitude: 0.11, frequency: 3.4, seed: 83,
        color: Color(red: 0.64, green: 0.65, blue: 0.68), jaggedness: 0.55),
      Ridge(
        baseY: 0.78, amplitude: 0.08, frequency: 2.6, seed: 97,
        color: Color(red: 0.47, green: 0.48, blue: 0.52), jaggedness: 0.3),
    ],
    mist: [
      MistBand(centerY: 0.46, height: 0.14, opacity: 0.55, driftSpeed: 0.005, seed: 25),
      MistBand(centerY: 0.66, height: 0.16, opacity: 0.60, driftSpeed: -0.004, seed: 29),
      MistBand(centerY: 0.90, height: 0.16, opacity: 0.50, driftSpeed: 0.003, seed: 31),
    ],
    clouds: []
  )

  /// Dawn dunes under a warm haze.
  static let duneveil = LandscapeScene(
    skyTop: Color(red: 0.99, green: 0.90, blue: 0.78),
    skyHorizon: Color(red: 0.97, green: 0.84, blue: 0.68),
    horizonY: 0.60,
    sun: (CGPoint(x: 0.32, y: 0.34), Color(red: 1.0, green: 0.88, blue: 0.62), 0.26),
    rayColor: nil,
    ridges: [
      Ridge(
        baseY: 0.60, amplitude: 0.05, frequency: 1.8, seed: 101,
        color: Color(red: 0.91, green: 0.80, blue: 0.62)),
      Ridge(
        baseY: 0.72, amplitude: 0.07, frequency: 1.4, seed: 113,
        color: Color(red: 0.85, green: 0.70, blue: 0.50)),
      Ridge(
        baseY: 0.86, amplitude: 0.08, frequency: 1.1, seed: 127,
        color: Color(red: 0.76, green: 0.58, blue: 0.38)),
    ],
    mist: [
      MistBand(centerY: 0.62, height: 0.08, opacity: 0.30, driftSpeed: 0.004, seed: 35)
    ],
    clouds: [
      Cloud(y: 0.12, scale: 0.9, opacity: 0.25, driftSpeed: 0.007, seed: 39),
      Cloud(y: 0.22, scale: 0.6, opacity: 0.20, driftSpeed: 0.011, seed: 43),
    ],
    mistColor: Color(red: 1.0, green: 0.94, blue: 0.85)
  )
}

/// Renders a LandscapeScene. Ridges and sky are static; mist, clouds, and
/// ray shimmer animate at 24 fps. `animated == false` renders one still frame.
struct LandscapeSceneView: View {
  let scene: LandscapeScene
  let animated: Bool

  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
        frame(time: timeline.date.timeIntervalSinceReferenceDate)
      }
    } else {
      frame(time: 0)
    }
  }

  private func frame(time: TimeInterval) -> some View {
    Canvas(rendersAsynchronously: true) { context, size in
      drawSky(in: &context, size: size)
      if let sun = scene.sun { drawSun(sun, in: &context, size: size) }
      if let rayColor = scene.rayColor, let sun = scene.sun {
        drawRays(from: sun.position, color: rayColor, time: time, in: &context, size: size)
      }
      var soft = context
      soft.addFilter(.blur(radius: 22))
      for cloud in scene.clouds { drawCloud(cloud, time: time, in: &soft, size: size) }
      for (index, ridge) in scene.ridges.enumerated() {
        drawRidge(ridge, in: &context, size: size)
        // Interleave mist between ridge layers for depth: band i sits over ridge i.
        for band in scene.mist where mistLayer(for: band) == index {
          drawMist(band, time: time, in: &soft, size: size)
        }
      }
      for band in scene.mist where mistLayer(for: band) >= scene.ridges.count {
        drawMist(band, time: time, in: &soft, size: size)
      }
    }
  }

  private func mistLayer(for band: LandscapeScene.MistBand) -> Int {
    for (index, ridge) in scene.ridges.enumerated() where band.centerY < ridge.baseY {
      return index
    }
    return scene.ridges.count
  }

  private func drawSky(in context: inout GraphicsContext, size: CGSize) {
    context.fill(
      Path(CGRect(origin: .zero, size: size)),
      with: .linearGradient(
        Gradient(stops: [
          .init(color: scene.skyTop, location: 0),
          .init(color: scene.skyHorizon, location: scene.horizonY),
          .init(color: scene.skyHorizon, location: 1),
        ]),
        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
      )
    )
  }

  private func drawSun(
    _ sun: (position: CGPoint, color: Color, radius: Double),
    in context: inout GraphicsContext, size: CGSize
  ) {
    let center = CGPoint(x: sun.position.x * size.width, y: sun.position.y * size.height)
    let radius = sun.radius * min(size.width, size.height)
    context.fill(
      Path(
        ellipseIn: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
      with: .radialGradient(
        Gradient(stops: [
          .init(color: sun.color.opacity(0.85), location: 0),
          .init(color: sun.color.opacity(0.30), location: 0.35),
          .init(color: sun.color.opacity(0), location: 1),
        ]),
        center: center, startRadius: 0, endRadius: radius
      )
    )
  }

  private func drawRays(
    from origin: CGPoint, color: Color, time: TimeInterval,
    in context: inout GraphicsContext, size: CGSize
  ) {
    let anchor = CGPoint(x: origin.x * size.width, y: origin.y * size.height)
    let reach = max(size.width, size.height) * 1.4
    for index in 0..<5 {
      let base = 0.95 + Double(index) * 0.20
      let sway = 0.02 * sin(time * 0.05 + Double(index) * 1.7)
      let angle = base + sway
      let halfWidth = 0.025 + 0.012 * Double(index % 3)
      let shimmer = 0.55 + 0.45 * sin(time * 0.09 + Double(index) * 2.3)
      var path = Path()
      path.move(to: anchor)
      path.addLine(
        to: CGPoint(
          x: anchor.x + reach * cos(angle - halfWidth), y: anchor.y + reach * sin(angle - halfWidth)
        ))
      path.addLine(
        to: CGPoint(
          x: anchor.x + reach * cos(angle + halfWidth), y: anchor.y + reach * sin(angle + halfWidth)
        ))
      path.closeSubpath()
      context.fill(path, with: .color(color.opacity(0.10 * shimmer)))
    }
  }

  private func drawRidge(
    _ ridge: LandscapeScene.Ridge, in context: inout GraphicsContext, size: CGSize
  ) {
    var phases: [Double] = []
    var seed = ridge.seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
    for _ in 0..<3 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      phases.append(Double(seed >> 11) / Double(UInt64.max >> 11) * 2 * .pi)
    }
    var path = Path()
    let steps = 96
    path.move(to: CGPoint(x: -2, y: size.height + 2))
    for step in 0...steps {
      let fraction = Double(step) / Double(steps)
      let x = fraction * size.width
      var offset = 0.0
      var amplitude = 1.0
      var frequency = ridge.frequency
      for octave in 0..<3 {
        let wave = sin(fraction * frequency * 2 * .pi + phases[octave])
        // Jagged ridges fold the sine into triangular peaks.
        offset +=
          amplitude
          * (ridge.jaggedness > 0
            ? wave * (1 - ridge.jaggedness) + ridge.jaggedness * (2 * abs(wave) - 1)
            : wave)
        amplitude *= 0.45
        frequency *= 2.3
      }
      let y = (ridge.baseY + ridge.amplitude * offset * 0.6) * size.height
      path.addLine(to: CGPoint(x: x, y: y))
    }
    path.addLine(to: CGPoint(x: size.width + 2, y: size.height + 2))
    path.closeSubpath()
    context.fill(path, with: .color(ridge.color))
  }

  private func drawMist(
    _ band: LandscapeScene.MistBand, time: TimeInterval,
    in context: inout GraphicsContext, size: CGSize
  ) {
    let drift = (time * band.driftSpeed).truncatingRemainder(dividingBy: 1)
    let bandHeight = band.height * size.height
    let y = band.centerY * size.height
    // Three overlapping soft blobs per band, wrapping horizontally as they drift.
    for index in 0..<3 {
      let seedOffset = Double((band.seed &+ UInt64(index) &* 7919) % 100) / 100
      var x = ((seedOffset + drift).truncatingRemainder(dividingBy: 1) * 1.6 - 0.3) * size.width
      if x > size.width * 1.3 { x -= size.width * 1.6 }
      let width = size.width * (0.55 + 0.25 * seedOffset)
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: x - width / 2, y: y - bandHeight, width: width, height: bandHeight * 2)),
        with: .color(scene.mistColor.opacity(band.opacity))
      )
    }
  }

  private func drawCloud(
    _ cloud: LandscapeScene.Cloud, time: TimeInterval,
    in context: inout GraphicsContext, size: CGSize
  ) {
    let seedOffset = Double(cloud.seed % 100) / 100
    let drift = (seedOffset + time * cloud.driftSpeed).truncatingRemainder(dividingBy: 1)
    let x = (drift * 1.5 - 0.25) * size.width
    let y = cloud.y * size.height
    let width = size.width * 0.34 * cloud.scale
    let height = size.height * 0.055 * cloud.scale
    context.fill(
      Path(ellipseIn: CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)),
      with: .color(scene.mistColor.opacity(cloud.opacity))
    )
    context.fill(
      Path(
        ellipseIn: CGRect(
          x: x - width * 0.28, y: y - height * 0.9, width: width * 0.55, height: height)),
      with: .color(scene.mistColor.opacity(cloud.opacity * 0.8))
    )
  }
}

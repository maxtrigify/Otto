import AVFoundation
import AppKit
import ImageIO
import OttoModels
import SwiftUI

/// Resolved presentation for a theme's `backgroundAsset`.
///
/// Extension-qualified names resolve against the bundled `Themes/` resource directory
/// (`.mov`/`.mp4`/`.m4v` loop as video, `.heic`/`.png`/`.jpg` render as a still).
/// Bare names resolve to built-in procedural scenes so a theme can ship animation
/// without a licensed video asset.
enum ThemeBackground: Equatable {
  case video(URL)
  case image(URL)
  case auroraScene
  case landscape(String)
  /// The desktop wallpaper seen through a transparent window behind a system blur.
  case desktopGlass

  private static let videoExtensions = ["mov", "mp4", "m4v"]
  private static let imageExtensions = ["heic", "png", "jpg", "jpeg"]

  static func resolve(_ asset: String?) -> ThemeBackground? {
    guard let asset, !asset.isEmpty else { return nil }
    if asset == "glass" { return .desktopGlass }
    let name = asset as NSString
    let ext = name.pathExtension.lowercased()
    if ext.isEmpty {
      // Bare names prefer dropped-in artwork over the built-in procedural scene,
      // so shipping real art for a theme is: add "<name>.png"/".mov" to
      // Resources/Themes — no code change.
      if let media = bundledMedia(basename: asset) { return media }
      if asset == "aurora" { return .auroraScene }
      return LandscapeScene.builtIn[asset] != nil ? .landscape(asset) : nil
    }
    guard
      let url = OttoAppResources.url(
        forResource: name.deletingPathExtension, withExtension: ext, subdirectory: "Themes")
    else { return nil }
    if videoExtensions.contains(ext) { return .video(url) }
    if imageExtensions.contains(ext) { return .image(url) }
    return nil
  }

  private static func bundledMedia(basename: String) -> ThemeBackground? {
    for ext in videoExtensions {
      if let url = OttoAppResources.url(
        forResource: basename, withExtension: ext, subdirectory: "Themes")
      {
        return .video(url)
      }
    }
    for ext in imageExtensions {
      if let url = OttoAppResources.url(
        forResource: basename, withExtension: ext, subdirectory: "Themes")
      {
        return .image(url)
      }
    }
    return nil
  }
}

/// Full-window animated theme backdrop with the accessibility ladder:
/// reduced transparency removes the backdrop entirely (solid ink stays underneath),
/// reduced motion freezes it on a still frame, and a scrim keyed to the theme's
/// surface material keeps text contrast close to the plain-ink baseline.
struct ThemeBackgroundView: View {
  let theme: OttoThemeDefinition
  let isActive: Bool
  /// Home and Chat put text on solid cards or give it a halo, so they keep the photo nearly
  /// clear; the full contract scrim stays for Canvas, where text sits straight on the art.
  /// Reduce Transparency always gets the full scrim.
  var scrimScale: Double = 1
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  /// Full-window SwiftUI Canvas redraws are intentionally opt-in. The static frame keeps the
  /// visual identity while allowing an untouched workspace to become CPU-idle.
  @AppStorage("otto.visuals.animatedBackgrounds") private var animatedBackgrounds = false

  private var motionEnabled: Bool {
    isActive && animatedBackgrounds && !reduceMotion
  }

  var body: some View {
    if !reduceTransparency, let background = ThemeBackground.resolve(theme.backgroundAsset) {
      ZStack {
        switch background {
        case .video(let url):
          LoopingVideoView(url: url, frozen: !motionEnabled)
        case .image(let url):
          AnimatedStillBackdrop(
            url: url,
            motion: ImageMotion.forAsset(theme.backgroundAsset),
            animated: motionEnabled
          )
        case .auroraScene:
          AuroraSceneView(theme: theme, animated: motionEnabled)
        case .landscape(let name):
          if let scene = LandscapeScene.builtIn[name] {
            LandscapeSceneView(scene: scene, animated: motionEnabled)
          }
        case .desktopGlass:
          DesktopGlassView(lightAppearance: theme.isLightAppearance)
        }
        scrim
      }
      .transition(.opacity)
      .accessibilityHidden(true)
    }
  }

  private var scrim: some View {
    // Floor and deep stops are contract, not styling: the theme tests prove text legibility
    // through exactly these opacities over the worst in-contract backdrop pixel.
    // Window glass frosts with the surface tone instead of ink — it must be able to
    // *lighten* a dark wallpaper for light-appearance glass, not only darken bright art.
    let tone = theme.resolvedSurfaceMaterial == .windowGlass ? palette.surface : palette.ink
    let scale = reduceTransparency ? 1 : scrimScale
    let base = theme.scrimFloorOpacity * scale
    return LinearGradient(
      stops: [
        .init(color: tone.opacity(base), location: 0),
        .init(
          color: tone.opacity(
            base + (theme.resolvedSurfaceMaterial == .windowGlass ? 0.04 : 0.10) * scale),
          location: 0.55),
        .init(color: tone.opacity(theme.scrimDeepOpacity * scale), location: 1),
      ],
      startPoint: .top, endPoint: .bottom
    )
  }
}

/// Behind-window system blur for `windowGlass` themes. While mounted it makes the hosting
/// window non-opaque with a clear background so the desktop shows through, and restores the
/// window's previous state when it leaves (theme switch, reduced transparency, teardown).
private struct DesktopGlassView: NSViewRepresentable {
  let lightAppearance: Bool

  func makeNSView(context: Context) -> GlassEffectView {
    let view = GlassEffectView()
    view.blendingMode = .behindWindow
    view.state = .active
    // Menu acrylic preserves recognisable wallpaper colour and large forms while diffusing
    // desktop detail. Changing the effect view's alpha does not weaken its blur; AppKit first
    // resolves the material to a dark plate and then fades that plate, which reads as black.
    view.material = .menu
    return view
  }

  func updateNSView(_ view: GlassEffectView, context: Context) {
    view.appearance = NSAppearance(named: lightAppearance ? .aqua : .darkAqua)
  }

  final class GlassEffectView: NSVisualEffectView {
    private var previousOpaque: Bool?
    private var previousBackground: NSColor?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      if previousOpaque == nil {
        previousOpaque = window.isOpaque
        previousBackground = window.backgroundColor
      }
      window.isOpaque = false
      window.backgroundColor = .clear
      window.contentView?.wantsLayer = true
      window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if newWindow == nil, let window, let previousOpaque {
        window.isOpaque = previousOpaque
        window.backgroundColor = previousBackground
        self.previousOpaque = nil
        self.previousBackground = nil
      }
      super.viewWillMove(toWindow: newWindow)
    }
  }
}

/// Motion applied over a still backdrop so painted artwork reads as alive without
/// needing a video loop: a slow Ken Burns breathe plus an optional specular water
/// shimmer (drifting light streaks and twinkling glints) confined to a region of
/// the image. Tuned per asset; the default suits lake/valley compositions with
/// water in the lower half.
struct ImageMotion {
  /// Unit-space region that reads as water; shimmer stays inside it.
  var shimmerRegion: CGRect?
  var shimmerIntensity: Double
  var glintCount: Int
  /// Maximum extra scale for the Ken Burns breathe (0 disables).
  var breatheScale: Double

  static let standard = ImageMotion(
    shimmerRegion: CGRect(x: 0, y: 0.55, width: 1, height: 0.45),
    shimmerIntensity: 0.5, glintCount: 26, breatheScale: 0.018
  )

  /// Per-asset overrides, keyed by the theme's `backgroundAsset` basename.
  /// Regions trace where water sits in each shipped painting.
  private static let overrides: [String: ImageMotion] = [
    // Turquoise lake fills the lower-left two-thirds — the hero shimmer.
    "shorelight": ImageMotion(
      shimmerRegion: CGRect(x: 0, y: 0.48, width: 0.72, height: 0.52),
      shimmerIntensity: 0.6, glintCount: 32, breatheScale: 0.018),
    // River winds through the lower middle of the elven valley.
    "silverbough": ImageMotion(
      shimmerRegion: CGRect(x: 0.28, y: 0.66, width: 0.55, height: 0.34),
      shimmerIntensity: 0.35, glintCount: 14, breatheScale: 0.015),
    // Fog-lake below the ink-wash ridges; keep it barely-there.
    "mistfall": ImageMotion(
      shimmerRegion: CGRect(x: 0, y: 0.70, width: 1, height: 0.30),
      shimmerIntensity: 0.28, glintCount: 8, breatheScale: 0.012),
    // No water in the highlands or dunes — breathe only.
    "highfell": ImageMotion(
      shimmerRegion: nil, shimmerIntensity: 0, glintCount: 0, breatheScale: 0.015),
    "duneveil": ImageMotion(
      shimmerRegion: nil, shimmerIntensity: 0, glintCount: 0, breatheScale: 0.012),
    // Small river-lake at center-right of the field; keep it faint.
    "farfield": ImageMotion(
      shimmerRegion: CGRect(x: 0.45, y: 0.58, width: 0.35, height: 0.24),
      shimmerIntensity: 0.32, glintCount: 12, breatheScale: 0.015),
    // Waterfall lakes wind through the valley center.
    "ringfall": ImageMotion(
      shimmerRegion: CGRect(x: 0.28, y: 0.58, width: 0.50, height: 0.36),
      shimmerIntensity: 0.40, glintCount: 16, breatheScale: 0.015),
    // Broad lake below the storybook castle.
    "halcyon": ImageMotion(
      shimmerRegion: CGRect(x: 0.30, y: 0.55, width: 0.55, height: 0.40),
      shimmerIntensity: 0.50, glintCount: 22, breatheScale: 0.016),
    // Moody dusk water; low-key glints so the mood holds.
    "nightspire": ImageMotion(
      shimmerRegion: CGRect(x: 0.15, y: 0.62, width: 0.72, height: 0.38),
      shimmerIntensity: 0.34, glintCount: 14, breatheScale: 0.013),
    // Painted character art, no water: a slow breathe only, so the figure never swims.
    "nightscreen": ImageMotion(
      shimmerRegion: nil, shimmerIntensity: 0, glintCount: 0, breatheScale: 0.010),
  ]

  static func forAsset(_ asset: String?) -> ImageMotion {
    guard let asset else { return .standard }
    let basename = (asset as NSString).deletingPathExtension
    return overrides[basename] ?? .standard
  }
}

/// Still image + ImageMotion. Reduced motion renders the plain downsampled still.
private struct AnimatedStillBackdrop: View {
  let url: URL
  let motion: ImageMotion
  let animated: Bool

  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
        let time = timeline.date.timeIntervalSinceReferenceDate
        DownsampledThemeImage(url: url)
          .scaleEffect(1 + motion.breatheScale * (0.5 + 0.5 * sin(time * 2 * .pi / 47)))
          .overlay {
            if let region = motion.shimmerRegion, motion.shimmerIntensity > 0 {
              ShimmerOverlay(
                region: region, intensity: motion.shimmerIntensity,
                glintCount: motion.glintCount, time: time)
            }
          }
      }
    } else {
      DownsampledThemeImage(url: url)
    }
  }
}

/// Specular life on water: two broad drifting light streaks plus small glints that
/// twinkle out of phase, all masked to the configured region and screen-blended so
/// they brighten the artwork rather than paint over it.
private struct ShimmerOverlay: View {
  let region: CGRect
  let intensity: Double
  let glintCount: Int
  let time: TimeInterval

  var body: some View {
    Canvas(rendersAsynchronously: true) { context, size in
      let area = CGRect(
        x: region.minX * size.width, y: region.minY * size.height,
        width: region.width * size.width, height: region.height * size.height)
      context.clip(to: Path(area))
      context.blendMode = .screen

      var streaks = context
      streaks.addFilter(.blur(radius: 18))
      for index in 0..<2 {
        let phase = time * (0.014 + 0.009 * Double(index)) + Double(index) * 0.47
        let drift = phase.truncatingRemainder(dividingBy: 1)
        let x = area.minX + (drift * 1.4 - 0.2) * area.width
        let width = area.width * 0.30
        let pulse = 0.6 + 0.4 * sin(time * 0.11 + Double(index) * 2.1)
        streaks.fill(
          Path(
            CGRect(x: x - width / 2, y: area.minY, width: width, height: area.height)),
          with: .linearGradient(
            Gradient(stops: [
              .init(color: .clear, location: 0),
              .init(color: .white.opacity(0.10 * intensity * pulse), location: 0.5),
              .init(color: .clear, location: 1),
            ]),
            startPoint: CGPoint(x: x - width / 2, y: 0),
            endPoint: CGPoint(x: x + width / 2, y: 0)
          )
        )
      }

      var seed: UInt64 = 0xD1B5_4A32_D192_ED03
      func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(UInt64.max >> 11)
      }
      for _ in 0..<glintCount {
        let x = area.minX + next() * area.width
        let y = area.minY + next() * area.height
        let phase = next() * 2 * .pi
        let rate = 0.35 + next() * 0.8
        let twinkle = max(0, sin(time * rate + phase))
        let radius = 0.8 + next() * 1.6
        context.fill(
          Path(
            ellipseIn: CGRect(
              x: x - radius, y: y - radius * 0.45, width: radius * 2, height: radius * 0.9)),
          with: .color(.white.opacity(0.35 * intensity * twinkle * twinkle))
        )
      }
    }
    .allowsHitTesting(false)
  }
}

/// Decodes still backdrops close to their actual on-screen pixel size instead of retaining the
/// source bitmap at full resolution. Layout changes are bucketed to avoid repeated decoding.
private struct DownsampledThemeImage: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> ThemeImageView {
    let view = ThemeImageView()
    view.setSource(url)
    return view
  }

  func updateNSView(_ view: ThemeImageView, context: Context) {
    view.setSource(url)
  }

  /// The backdrop always takes exactly the space it is offered. It must never report the
  /// photo's own size, or SwiftUI sizes the window's backdrop to the bitmap and leaves bare
  /// strips at the edges until the next resize.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThemeImageView, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 10, height: proposal.height ?? 10)
  }

  /// Draws the photo aspect-filled into a layer, cropping the overflow like a wallpaper.
  final class ThemeImageView: NSView {
    private var sourceURL: URL?
    private var decodedPixelBucket = 0
    private var decoded: CGImage?

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      layerContentsRedrawPolicy = .onSetNeedsDisplay
      layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
      NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override var isOpaque: Bool { true }

    func setSource(_ url: URL) {
      guard sourceURL != url else { return }
      sourceURL = url
      decodedPixelBucket = 0
      needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      decodedPixelBucket = 0
      needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      needsDisplay = true
    }

    /// Aspect fill: scale until both sides are covered, centre, and let the bounds crop.
    override func draw(_ dirtyRect: NSRect) {
      guard let decoded, let context = NSGraphicsContext.current?.cgContext else { return }
      let imageSize = CGSize(width: decoded.width, height: decoded.height)
      guard imageSize.width > 0, imageSize.height > 0 else { return }
      let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
      let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
      let rect = CGRect(
        x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
        width: size.width, height: size.height)
      context.interpolationQuality = .high
      context.draw(decoded, in: rect)
    }

    override func layout() {
      super.layout()
      guard let sourceURL else { return }
      let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
      // Aspect fill crops one axis, so decode for the longer side of the window.
      let requiredPixels = max(bounds.width, bounds.height) * backingScale * 1.2
      guard requiredPixels > 1 else { return }
      let bucket = max(256, Int(ceil(requiredPixels / 256)) * 256)
      guard bucket != decodedPixelBucket else { return }

      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, options) else { return }
      let thumbnailOptions =
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true,
          kCGImageSourceThumbnailMaxPixelSize: bucket,
        ] as CFDictionary
      guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
      else { return }
      decoded = thumbnail
      decodedPixelBucket = bucket
      needsDisplay = true
    }
  }
}

/// Muted, seamlessly looping video layer for theme backdrops. When `frozen`
/// (reduced motion) it holds the first frame as a static poster.
private struct LoopingVideoView: NSViewRepresentable {
  let url: URL
  let frozen: Bool

  func makeNSView(context: Context) -> PlayerView { PlayerView(url: url) }

  func updateNSView(_ view: PlayerView, context: Context) {
    view.load(url: url)
    view.setFrozen(frozen)
  }

  final class PlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var currentURL: URL?

    init(url: URL) {
      super.init(frame: .zero)
      wantsLayer = true
      player.isMuted = true
      player.preventsDisplaySleepDuringVideoPlayback = false
      load(url: url)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
      let layer = AVPlayerLayer(player: player)
      layer.videoGravity = .resizeAspectFill
      return layer
    }

    func load(url: URL) {
      guard url != currentURL else { return }
      currentURL = url
      looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    }

    func setFrozen(_ frozen: Bool) {
      if frozen {
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
      } else if player.timeControlStatus != .playing {
        player.play()
      }
    }
  }
}

/// Built-in procedural backdrop: slow aurora curtains drifting over a starfield.
/// Runs at 24 fps through TimelineView; `animated == false` renders one still frame.
private struct AuroraSceneView: View {
  let theme: OttoThemeDefinition
  let animated: Bool

  var body: some View {
    if animated {
      TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
        scene(time: timeline.date.timeIntervalSinceReferenceDate)
      }
    } else {
      scene(time: 0)
    }
  }

  private func scene(time: TimeInterval) -> some View {
    Canvas(rendersAsynchronously: true) { context, size in
      drawSky(in: &context, size: size)
      drawStars(in: &context, size: size)
      var ribbons = context
      ribbons.addFilter(.blur(radius: 46))
      for band in Self.bands {
        drawRibbon(band, time: time, in: &ribbons, size: size)
      }
    }
  }

  private func drawSky(in context: inout GraphicsContext, size: CGSize) {
    let ink = Color(red: theme.ink.red, green: theme.ink.green, blue: theme.ink.blue)
    let horizon = Color(
      red: theme.surface.red, green: theme.surface.green, blue: theme.surface.blue)
    context.fill(
      Path(CGRect(origin: .zero, size: size)),
      with: .linearGradient(
        Gradient(colors: [ink, horizon]),
        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
      )
    )
  }

  private func drawStars(in context: inout GraphicsContext, size: CGSize) {
    // Deterministic LCG so the starfield is stable frame to frame.
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Double {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(seed >> 11) / Double(UInt64.max >> 11)
    }
    for _ in 0..<110 {
      let x = next() * size.width
      let y = next() * size.height * 0.72
      let radius = 0.4 + next() * 0.9
      let alpha = 0.12 + next() * 0.30
      context.fill(
        Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
        with: .color(.white.opacity(alpha))
      )
    }
  }

  private struct Band {
    let baseY: Double  // fraction of height
    let amplitude: Double  // fraction of height
    let wavelength: Double  // fraction of width
    let drift: Double  // radians per second
    let width: Double  // stroke width in points
    let opacity: Double
    let colors: [Color]
  }

  private static let bands: [Band] = [
    Band(
      baseY: 0.24, amplitude: 0.055, wavelength: 0.9, drift: 0.05, width: 150, opacity: 0.30,
      colors: [
        Color(red: 0.20, green: 0.90, blue: 0.55), Color(red: 0.25, green: 0.75, blue: 0.95),
      ]
    ),
    Band(
      baseY: 0.38, amplitude: 0.075, wavelength: 1.25, drift: -0.036, width: 190, opacity: 0.22,
      colors: [
        Color(red: 0.30, green: 0.85, blue: 0.90), Color(red: 0.50, green: 0.40, blue: 0.95),
      ]
    ),
    Band(
      baseY: 0.16, amplitude: 0.045, wavelength: 0.7, drift: 0.028, width: 110, opacity: 0.18,
      colors: [
        Color(red: 0.55, green: 0.95, blue: 0.65), Color(red: 0.30, green: 0.60, blue: 0.95),
      ]
    ),
  ]

  private func drawRibbon(
    _ band: Band, time: TimeInterval, in context: inout GraphicsContext, size: CGSize
  ) {
    let phase = time * band.drift
    let breathe = 1 + 0.18 * sin(time * band.drift * 2.6 + band.baseY * 17)
    var path = Path()
    let steps = 48
    for step in 0...steps {
      let fraction = Double(step) / Double(steps)
      let x = (fraction * 1.2 - 0.1) * size.width
      let angle = fraction * 2 * .pi / band.wavelength + phase * 2 * .pi
      let y = (band.baseY + band.amplitude * breathe * sin(angle)) * size.height
      if step == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }
    context.stroke(
      path,
      with: .linearGradient(
        Gradient(colors: band.colors.map { $0.opacity(band.opacity) }),
        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
      ),
      style: StrokeStyle(lineWidth: band.width, lineCap: .round)
    )
  }
}

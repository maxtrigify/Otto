import OttoVoice
import SwiftUI

/// What the glow along the bottom of the window is showing.
enum VoiceGlowPhase: Equatable {
  case hidden
  /// The person is holding the key or speaking.
  case hearing
  /// Otto has the request and is working on it.
  case working
  /// Otto is talking.
  case speaking

  /// An open microphone that hears nothing shows nothing: a permanent glow reads as Otto
  /// eavesdropping. The glow rises when the person holds the key or actually speaks.
  static func resolve(state: VoiceState, holding: Bool) -> VoiceGlowPhase {
    switch state {
    case .speaking: .speaking
    case .thinking, .callingTool, .endOfTurn: .working
    case .userSpeaking: .hearing
    case .listening: holding ? .hearing : .hidden
    // Still connecting: the pale breath says "not yet", so the gold means Otto is hearing.
    case .connecting: holding ? .working : .hidden
    case .disconnected, .sleeping, .interrupted, .error:
      holding ? .hearing : .hidden
    }
  }

  /// How strongly a loudness reading moves the glow. Speech sits around 0.03 to 0.2, so the
  /// curve is steep at the quiet end and levels off rather than clipping on a loud word.
  static func energy(forLevel level: Double) -> Double {
    min(1, (max(0, level) * 6).squareRoot())
  }
}

/// A glow that rises from the bottom edge of the window while voice is in use, and moves with
/// whoever is talking: gold with the person's voice, cyan with Otto's.
struct VoiceShorelineGlow: View {
  @ObservedObject var voice: VoiceController
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = Motion()

  private static let height: CGFloat = 210

  private var phase: VoiceGlowPhase {
    VoiceGlowPhase.resolve(state: voice.snapshot.state, holding: voice.isHoldingVoice)
  }

  var body: some View {
    let phase = phase
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      ZStack(alignment: .bottom) {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase == .hidden)) { timeline in
          Canvas { context, size in
            draw(in: &context, size: size, phase: phase, date: timeline.date)
          }
        }
        .blur(radius: 20)
        waterline(phase: phase)
      }
      .frame(height: Self.height)
    }
    .opacity(phase == .hidden ? 0 : 1)
    .animation(.easeInOut(duration: 0.35), value: phase)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func color(for phase: VoiceGlowPhase) -> Color {
    switch phase {
    case .speaking: palette.cyan
    case .working: palette.paper
    case .hearing, .hidden: palette.signal
    }
  }

  private func waterline(phase: VoiceGlowPhase) -> some View {
    let color = color(for: phase)
    return LinearGradient(
      stops: [
        .init(color: color.opacity(0), location: 0.06),
        .init(color: color, location: 0.32),
        .init(color: .white.opacity(0.85), location: 0.5),
        .init(color: color, location: 0.68),
        .init(color: color.opacity(0), location: 0.94),
      ],
      startPoint: .leading, endPoint: .trailing
    )
    .frame(height: 3)
    .opacity(phase == .working ? 0.45 : 0.9)
  }

  private func draw(
    in context: inout GraphicsContext, size: CGSize, phase: VoiceGlowPhase, date: Date
  ) {
    guard phase != .hidden else { return }
    let time = date.timeIntervalSinceReferenceDate
    let target: Double
    switch phase {
    case .hearing:
      target =
        0.18 + 0.82
        * VoiceGlowPhase.energy(
          forLevel: VoiceActivityLevels.shared.inputLevel(at: date))
    case .speaking:
      target =
        0.18 + 0.82
        * VoiceGlowPhase.energy(
          forLevel: VoiceActivityLevels.shared.outputLevel(at: date))
    case .working:
      // No voice to follow: a slow breath shows Otto is still at work.
      target = 0.16 + 0.07 * sin(time * 2.2)
    case .hidden:
      target = 0
    }
    let energy = reduceMotion ? 0.4 : motion.follow(target)
    let drift = reduceMotion ? 0 : time
    let color = color(for: phase)
    let width = size.width
    let height = size.height

    // Three sheets of light drift across one another at different speeds, so the edge never
    // repeats: slow and tall at the back, quick and low at the front.
    let layers: [(scale: Double, speed: Double, wave: Double, shift: Double, opacity: Double)] = [
      (1.0, 0.9, 1.6, 0.0, 0.26),
      (0.74, -1.5, 2.6, 1.9, 0.34),
      (0.5, 2.3, 4.1, 4.2, 0.5),
    ]
    for layer in layers {
      let base = height * (0.14 + 0.5 * energy) * layer.scale
      let swell = height * (0.02 + 0.2 * energy) * layer.scale
      var path = Path()
      path.move(to: CGPoint(x: 0, y: height))
      var x: CGFloat = 0
      while x <= width + 12 {
        let position = Double(x / max(1, width))
        // The light gathers in the middle of the window and thins to nothing at the corners.
        let offset = (position - 0.5) / 0.3
        let gather = exp(-offset * offset)
        let ripple =
          0.6 * sin(position * layer.wave * 2 * .pi + drift * layer.speed + layer.shift)
          + 0.4 * sin(position * layer.wave * 5.3 - drift * layer.speed * 1.7 + layer.shift * 2)
        let rise = gather * (base + swell * ripple)
        path.addLine(to: CGPoint(x: x, y: height - max(0, rise)))
        x += 12
      }
      path.addLine(to: CGPoint(x: width, y: height))
      path.closeSubpath()
      context.fill(path, with: .color(color.opacity(layer.opacity)))
    }
  }

  /// Follows the loudness quickly on the way up and lets go slowly, the way a flame does, so the
  /// glow tracks syllables without flickering between them.
  final class Motion {
    private var value = 0.0

    func follow(_ target: Double) -> Double {
      let rate = target > value ? 0.45 : 0.12
      value += (target - value) * rate
      return value
    }
  }
}

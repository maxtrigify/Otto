import OttoModels
import SwiftUI

extension Notification.Name {
  static let ottoStartHomeTour = Notification.Name("io.openotto.start-home-tour")
}

/// Where each tour target sits on screen, gathered from the views that carry it.
struct HomeTourAnchorsKey: PreferenceKey {
  static let defaultValue: [HomeTourTarget: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [HomeTourTarget: Anchor<CGRect>],
    nextValue: () -> [HomeTourTarget: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

extension View {
  /// Marks this view as something the Home tour can spotlight.
  func homeTourTarget(_ target: HomeTourTarget) -> some View {
    anchorPreference(key: HomeTourAnchorsKey.self, value: .bounds) { [target: $0] }
  }
}

/// The first-run tour: dims the window, cuts a spotlight around one real control at a time
/// and explains it in a card beside it. Every step offers Skip.
struct HomeTourOverlay: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  @Environment(\.openSettings) private var openSettings
  let anchors: [HomeTourTarget: Anchor<CGRect>]
  @Binding var stepIndex: Int
  let finish: () -> Void

  private let steps = HomeTourCatalog.steps
  private let cardWidth: CGFloat = 340

  var body: some View {
    GeometryReader { geometry in
      let step = steps[min(stepIndex, steps.count - 1)]
      let spot = step.target.flatMap { anchors[$0] }.map { geometry[$0].insetBy(dx: -8, dy: -8) }
      ZStack(alignment: .topLeading) {
        dimming(spot: spot)
          .contentShape(Rectangle())
          .onTapGesture {}
        if let spot {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
            .shadow(color: .white.opacity(0.35), radius: 12)
            .frame(width: spot.width, height: spot.height)
            .offset(x: spot.minX, y: spot.minY)
            .allowsHitTesting(false)
        }
        card(step)
          .frame(width: cardWidth)
          .fixedSize(horizontal: false, vertical: true)
          .offset(cardOffset(spot: spot, in: geometry.size))
      }
      .animation(motion.enter(.moderate), value: stepIndex)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("home.tour")
  }

  private func dimming(spot: CGRect?) -> some View {
    Canvas { context, size in
      var path = Path(CGRect(origin: .zero, size: size))
      if let spot {
        path.addPath(Path(roundedRect: spot, cornerRadius: 12, style: .continuous))
      }
      context.fill(path, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
    }
  }

  /// Beside the target when there is room, otherwise below it, otherwise above; centred
  /// when the step has no target.
  private func cardOffset(spot: CGRect?, in size: CGSize) -> CGSize {
    let estimatedHeight: CGFloat = 230
    guard let spot else {
      return CGSize(width: (size.width - cardWidth) / 2, height: size.height * 0.3)
    }
    var x = spot.maxX + 18
    var y = spot.minY
    if x + cardWidth > size.width - 16 {
      x = min(max(16, spot.minX), size.width - cardWidth - 16)
      y = spot.maxY + 16
      if y + estimatedHeight > size.height - 16 { y = spot.minY - estimatedHeight - 16 }
    }
    return CGSize(width: x, height: max(16, min(y, size.height - estimatedHeight - 16)))
  }

  private func card(_ step: HomeTourStep) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(step.kicker)
        .font(.ottoMicro)
        .tracking(1.8)
        .foregroundStyle(palette.signal)
      Text(step.title).font(.ottoDisplay(16).weight(.semibold))
      switch step.body {
      case .text(let paragraphs):
        ForEach(paragraphs, id: \.self) { paragraph in
          Text(paragraph)
            .font(.ottoDisplay(13))
            .foregroundStyle(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      case .comparison(let terms):
        VStack(alignment: .leading, spacing: 0) {
          ForEach(terms, id: \.term) { item in
            Divider().overlay(palette.paper.opacity(0.08))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
              Text(item.term)
                .font(.ottoDisplay(12).weight(.semibold))
                .frame(width: 58, alignment: .leading)
              Text(item.meaning)
                .font(.ottoDisplay(12))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 6)
          }
        }
      }
      if step.action == .openSettings {
        Button("Open Settings") { openSettings() }
          .buttonStyle(.plain)
          .font(.ottoDisplay(12).weight(.medium))
          .foregroundStyle(palette.cyan)
      }
      HStack(spacing: 10) {
        HStack(spacing: 4) {
          ForEach(steps.indices, id: \.self) { index in
            Capsule()
              .fill(index == stepIndex ? palette.signal : palette.paper.opacity(0.18))
              .frame(width: index == stepIndex ? 14 : 6, height: 6)
          }
        }
        Spacer(minLength: 4)
        Button("Skip tour", action: finish)
          .buttonStyle(.plain)
          .font(.ottoDisplay(12))
          .foregroundStyle(palette.muted)
          .keyboardShortcut(.cancelAction)
          .fixedSize()
          .accessibilityIdentifier("home.tour.skip")
        if stepIndex > 0 {
          Button("Back") { stepIndex -= 1 }
            .buttonStyle(.plain)
            .fixedSize()
            .font(.ottoDisplay(12))
            .foregroundStyle(palette.muted)
        }
        Button {
          if stepIndex + 1 < steps.count { stepIndex += 1 } else { finish() }
        } label: {
          Text(nextTitle)
            .font(.ottoDisplay(12).weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(palette.ink)
            .background(palette.paper, in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("home.tour.next")
      }
      .padding(.top, 6)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .background(palette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(palette.paper.opacity(0.08))
    )
    .foregroundStyle(palette.paper)
    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
  }

  private var nextTitle: String {
    if stepIndex == 0 { return "Show me around" }
    return stepIndex + 1 < steps.count ? "Next" : "Finish"
  }
}

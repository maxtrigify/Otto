import AppKit
import OttoModels
import SwiftUI

struct BotAvatarPresentation: Identifiable, Equatable {
  var id: UUID
  var name: String
  var appearance: BotAppearance?
  var photoURL: URL?
  var state: BotAvatarState

  init(
    id: UUID,
    name: String,
    appearance: BotAppearance? = nil,
    photoURL: URL? = nil,
    state: BotAvatarState = .idle
  ) {
    self.id = id
    self.name = name
    self.appearance = appearance
    self.photoURL = photoURL
    self.state = state
  }

  var initials: String {
    if let stored = appearance?.initials?.trimmingCharacters(in: .whitespacesAndNewlines),
      !stored.isEmpty
    {
      return stored
    }
    let generated = name.split(whereSeparator: \.isWhitespace).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
    return generated.isEmpty ? String(name.prefix(2)).uppercased() : generated
  }
}

struct BotAvatarView: View {
  @Environment(\.ottoPalette) private var palette

  let presentation: BotAvatarPresentation
  var size: CGFloat
  var showsStateBadge = true

  /// List-sized avatars are a calm gradient circle with an initial; the detailed faces only
  /// show where there is room to read them.
  private var isCompact: Bool { size < 48 }

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      if isCompact {
        compactAvatar
      } else {
        avatarContent
          .frame(width: size, height: size)
          .clipShape(avatarShape)
          .overlay(avatarShape.stroke(palette.paper.opacity(0.12), lineWidth: 1))

        if showsStateBadge {
          stateBadge
            .offset(x: size * 0.04, y: size * 0.04)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(presentation.name), \(presentation.state.accessibilityLabel)")
  }

  @ViewBuilder
  private var avatarContent: some View {
    if let photoURL = presentation.photoURL, let image = NSImage(contentsOf: photoURL) {
      Image(nsImage: image)
        .resizable()
        .scaledToFill()
    } else {
      plate
        .overlay {
          if BotFaceCatalog.contains(presentation.appearance?.avatarRef),
            let face = presentation.appearance?.avatarRef
          {
            BotFaceAvatar(
              faceID: face,
              state: presentation.state,
              color: markColor,
              size: size
            )
          } else if let icon = presentation.appearance?.avatarRef,
            BotIconCatalog.symbols.contains(icon)
          {
            Text(icon).font(.system(size: max(11, size * 0.48)))
          } else {
            Text(presentation.initials)
              .font(.ottoMono(max(7, size * 0.22), weight: .black))
              .foregroundStyle(markColor)
          }
        }
    }
  }

  @ViewBuilder private var compactAvatar: some View {
    Group {
      if let photoURL = presentation.photoURL, let image = NSImage(contentsOf: photoURL) {
        Image(nsImage: image).resizable().scaledToFill()
      } else if BotFaceCatalog.contains(presentation.appearance?.avatarRef),
        let face = presentation.appearance?.avatarRef
      {
        // The bot's chosen face, drawn in white inside its colour circle.
        Circle().fill(gradient)
          .overlay(
            BotFaceAvatar(faceID: face, state: presentation.state, color: .white, size: size * 0.86)
          )
      } else if let icon = presentation.appearance?.avatarRef,
        BotIconCatalog.symbols.contains(icon)
      {
        Circle().fill(gradient)
          .overlay(Text(icon).font(.system(size: size * 0.5)))
      } else {
        Circle().fill(gradient)
          .overlay(
            Text(String(presentation.name.prefix(1)).uppercased())
              .font(.ottoDisplay(size * 0.46).weight(.semibold))
              .foregroundStyle(.white.opacity(0.95)))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    // Status only when it matters: a quiet ring when the bot needs you or hit a problem.
    .overlay {
      if showsStateBadge, let ring = statusRing {
        Circle().stroke(ring, lineWidth: max(1.5, size * 0.07)).padding(-max(1.5, size * 0.07))
      }
    }
  }

  private var statusRing: Color? {
    switch presentation.state {
    case .needsUser: palette.cyan
    case .failed: palette.red
    default: nil
    }
  }

  /// The bot's chosen colour, or a pleasant one picked steadily from its name.
  private var baseColor: Color {
    if let chosen = Color(hex: presentation.appearance?.colorHex) { return chosen }
    let choices: [Color] = [
      Color(red: 0.43, green: 0.55, blue: 0.95), Color(red: 0.36, green: 0.72, blue: 0.62),
      Color(red: 0.93, green: 0.55, blue: 0.40), Color(red: 0.69, green: 0.50, blue: 0.92),
      Color(red: 0.90, green: 0.45, blue: 0.62), Color(red: 0.42, green: 0.70, blue: 0.86),
      Color(red: 0.85, green: 0.68, blue: 0.32),
    ]
    let seed = presentation.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return choices[seed % choices.count]
  }

  private var gradient: LinearGradient {
    LinearGradient(
      colors: [baseColor.opacity(0.95), baseColor.opacity(0.65)],
      startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var avatarColor: Color {
    Color(hex: presentation.appearance?.colorHex) ?? palette.signal
  }

  private var colorIsDark: Bool {
    Color.isDarkHex(presentation.appearance?.colorHex)
  }

  private var plate: Color {
    colorIsDark ? palette.paper.opacity(0.16) : avatarColor.opacity(0.28)
  }

  private var markColor: Color {
    colorIsDark ? palette.paper : avatarColor
  }

  private var avatarShape: AnyShape {
    switch presentation.appearance?.shape {
    case "circle": AnyShape(Circle())
    case "diamond": AnyShape(RoundedRectangle(cornerRadius: size * 0.2).rotation(.degrees(45)))
    default: AnyShape(RoundedRectangle(cornerRadius: size * 0.27))
    }
  }

  private var stateBadge: some View {
    Image(systemName: stateSymbol)
      .font(.system(size: max(5, size * 0.18), weight: .black))
      .foregroundStyle(palette.ink)
      .frame(width: max(10, size * 0.3), height: max(10, size * 0.3))
      .background(stateColor, in: Circle())
      .overlay(Circle().stroke(palette.ink, lineWidth: 2))
      .accessibilityHidden(true)
  }

  private var stateSymbol: String {
    switch presentation.state {
    case .idle: "minus"
    case .working: "ellipsis"
    case .needsUser: "hand.raised.fill"
    case .failed: "exclamationmark"
    case .offline: "wifi.slash"
    }
  }

  private var stateColor: Color {
    switch presentation.state {
    case .idle: palette.muted
    case .working: palette.amber
    case .needsUser: palette.cyan
    case .failed: palette.red
    case .offline: palette.paper.opacity(0.45)
    }
  }
}

struct TeamAvatarView: View {
  @Environment(\.ottoPalette) private var palette

  let name: String
  let members: [BotAvatarPresentation]
  var size: CGFloat

  var body: some View {
    ZStack {
      ForEach(Array(visibleMembers.enumerated()), id: \.element.id) { index, member in
        BotAvatarView(
          presentation: member,
          size: composition.memberSize(containerSize: size),
          showsStateBadge: composition.memberSize(containerSize: size) >= 24
        )
        .offset(composition.offset(for: index, containerSize: size))
        .zIndex(Double(index))
      }

      if overflowCount > 0 {
        Text("+\(overflowCount)")
          .font(.ottoMono(max(6, size * 0.16), weight: .black))
          .foregroundStyle(palette.paper)
          .frame(width: size * 0.42, height: size * 0.32)
          .background(palette.ink.opacity(0.9), in: Capsule())
          .overlay(Capsule().stroke(palette.paper.opacity(0.22), lineWidth: 1))
          .offset(x: size * 0.27, y: size * 0.29)
          .zIndex(4)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(teamAccessibilityLabel)
  }

  private var visibleMembers: [BotAvatarPresentation] {
    Array(members.prefix(composition.visibleCount))
  }

  private var composition: TeamAvatarComposition { TeamAvatarComposition(count: members.count) }
  private var overflowCount: Int { composition.overflowCount }

  private var teamAccessibilityLabel: String {
    let stateSummary = members.map {
      "\($0.name) \($0.state.accessibilityLabel.lowercased())"
    }.joined(separator: ", ")
    return stateSummary.isEmpty ? "\(name), empty team" : "\(name): \(stateSummary)"
  }
}

struct TeamAvatarComposition: Equatable {
  let count: Int

  var visibleCount: Int { min(max(0, count), 3) }
  var overflowCount: Int { max(0, count - visibleCount) }

  func memberSize(containerSize: CGFloat) -> CGFloat {
    switch count {
    case 0: containerSize
    case 1: containerSize
    case 2: containerSize * 0.72
    default: containerSize * 0.6
    }
  }

  func offset(for index: Int, containerSize: CGFloat) -> CGSize {
    switch count {
    case 0, 1:
      .zero
    case 2:
      CGSize(width: (index == 0 ? -1 : 1) * containerSize * 0.16, height: 0)
    default:
      switch index {
      case 0: CGSize(width: -containerSize * 0.17, height: -containerSize * 0.15)
      case 1: CGSize(width: containerSize * 0.17, height: -containerSize * 0.15)
      default: CGSize(width: 0, height: containerSize * 0.18)
      }
    }
  }
}

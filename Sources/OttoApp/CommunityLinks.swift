import AppKit
import OttoModels
import OttoRuntime
import SwiftUI

/// Opens the Otto Discord and remembers that the person has been, so Home's Getting started
/// card can tick "Join the community" without us ever asking Discord.
enum OttoCommunityLinks {
  /// Set the first time the Discord invite is opened from anywhere in Otto.
  static let discordOpenedKey = "otto.community.discordOpened"

  @MainActor
  static func openDiscord() {
    UserDefaults.standard.set(true, forKey: discordOpenedKey)
    NSWorkspace.shared.open(OttoCommunity.discordInviteURL)
  }
}

/// The Discord mark from the bundled plugin artwork, tinted like a system glyph.
struct DiscordGlyph: View {
  let size: CGFloat
  let color: Color

  var body: some View {
    Group {
      if let image = PluginLogoAssets.image(named: "discord", kind: .template) {
        Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
      } else {
        Image(systemName: "bubble.left.and.bubble.right").resizable().scaledToFit()
      }
    }
    .foregroundStyle(color)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

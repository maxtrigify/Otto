import AppKit
import Foundation
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

/// Opt-in visual check of bot avatars as Otto's family. Set OTTO_FAMILY_SNAPSHOT_DIR to run it.
@Suite("Bot family snapshots")
@MainActor
struct BotFamilySnapshotTests {
  @Test func renderFamily() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FAMILY_SNAPSHOT_DIR"] else {
      return
    }
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "fieldNotes"))
    let bots: [(String, String, String?)] = [
      ("Woody", "#ad6a66", "face.echo"), ("Researcher", "#397b69", "face.mochi"),
      ("Coder", "#087f83", "face.nox"), ("Social Guru", "#526b8e", "face.zip"),
      ("Ops", "#a46e21", nil), ("Quill", "#8a5aa8", "otto.beret"), ("Fox", "#526b8e", "🦊"),
    ]
    func presentation(_ bot: (String, String, String?), state: BotAvatarState = .idle)
      -> BotAvatarPresentation
    {
      let id = UUID()
      return BotAvatarPresentation(
        id: id, name: bot.0,
        appearance: BotAppearance(profileID: id, avatarRef: bot.2, colorHex: bot.1), state: state)
    }
    let view = VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 18) {
        OttoFace(size: 72)
        ForEach(Array(bots.enumerated()), id: \.offset) { _, bot in
          VStack(spacing: 6) {
            BotAvatarView(presentation: presentation(bot), size: 72)
            Text(bot.0).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
          }
        }
      }
      HStack(spacing: 18) {
        ForEach(BotAvatarState.allCases, id: \.self) { state in
          BotAvatarView(presentation: presentation(bots[1], state: state), size: 56)
        }
      }
      HStack(alignment: .bottom, spacing: 24) {
        ForEach([16, 20, 28, 40] as [CGFloat], id: \.self) { size in
          HStack(spacing: 6) {
            ForEach(Array(bots.prefix(4).enumerated()), id: \.offset) { _, bot in
              BotAvatarView(
                presentation: presentation(bot, state: bot.0 == "Coder" ? .needsUser : .idle),
                size: size)
            }
          }
        }
      }
      HStack(spacing: 14) {
        ForEach(BotFamily.Accessory.allCases) { accessory in
          OttoFace(bot: accessory, color: Color(hex: "#397b69") ?? .green, state: .idle, size: 40)
        }
      }
    }
    .padding(28)
    .background(Color(red: 0.08, green: 0.09, blue: 0.10))
    .environment(\.ottoPalette, palette)

    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: "\(output)/bot-family.png"))
  }
}

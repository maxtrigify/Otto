import AppKit
import Foundation
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

/// Optional native captures for eyeballing issue #10's surfaces under a light and a dark
/// theme: the embedded terminal fed dark-tuned TUI output, and the header band over both
/// backdrop extremes. Set OTTO_CONTRAST_SNAPSHOTS to a directory to write PNGs; the
/// contrast guarantees themselves are asserted numerically in OttoModelsTests.
@Suite("Theme contrast snapshots")
@MainActor
struct ThemeContrastSnapshotTests {
  private static let tuiOutput =
    "\u{1B}[1;97m> Welcome back\u{1B}[0m  default text\r\n"
    + "\u{1B}[37mwhite body text from a dark-tuned TUI\u{1B}[0m\r\n"
    + "\u{1B}[2m1 MCP server failed to connect · run \u{1B}[34m/mcp\u{1B}[39m for details\u{1B}[22m\r\n"
    + "\u{1B}[38;5;244mgrey fine print\u{1B}[0m  \u{1B}[38;2;255;255;255mtruecolor white\u{1B}[0m\r\n"
    + "\u{1B}[30mblack text from a light-tuned TUI\u{1B}[0m\r\n"
    + "\u{1B}[48;5;236m status bar with default text \u{1B}[0m \u{1B}[44;97m badge \u{1B}[0m\r\n"

  @Test func renderTerminalAndHeaderBand() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_CONTRAST_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for theme in [OttoThemeCatalog.highfell, OttoThemeCatalog.graphite] {
      let palette = OttoPalette(theme: theme)
      let output = Self.tuiOutput
      let terminal = EmulatedTerminalView(
        output: output, outputStartOffset: 0, outputEndOffset: output.utf8.count,
        sessionKey: "snapshot", acceptsInput: false, replayExistingOutput: true,
        send: { _ in }, resize: { _, _ in }
      )
      .frame(width: 560, height: 150)
      .padding(8)
      .background(palette.ink)
      .environment(\.ottoPalette, palette)
      try await capture(terminal, size: NSSize(width: 576, height: 166), to: directory,
        name: "terminal-\(theme.id)")

      let band = VStack(spacing: 0) {
        ForEach([Color.white, Color.black, Color(nsColor: .systemTeal)], id: \.self) { backdrop in
          HStack(spacing: 14) {
            Image(systemName: "sidebar.left")
            Spacer()
            Text("Work space").font(.system(size: 12, weight: .medium))
            Image(systemName: "paintpalette")
            Image(systemName: "tray")
          }
          .foregroundStyle(palette.chromeForeground)
          .padding(.horizontal, 18)
          .frame(height: 34)
          .background(palette.chromeBand)
          .background(backdrop)
        }
      }
      .frame(width: 420)
      .environment(\.ottoPalette, palette)
      try await capture(band, size: NSSize(width: 420, height: 102), to: directory,
        name: "header-band-\(theme.id)")
    }
  }

  /// A sidebar footer and a transcript notice over a bright, a mid-tone and a dark backdrop
  /// pixel: the text the Highfell live check found sitting straight on the artwork. The rows
  /// mirror ChatWorkspaceView's rail (wash behind the whole column) and AgentConversationBody's
  /// notice (a wash plate sized to the row); on Graphite neither wash applies, as in the app.
  @Test func renderArtworkRows() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_CONTRAST_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let backdrops: [(String, Color)] = [
      ("bright", .white),
      // Highfell's sunlit grass: a mid-tone, where mid-grey secondary text vanishes.
      ("midtone", Color(red: 0.62, green: 0.70, blue: 0.48)),
      ("dark", .black),
    ]
    for theme in [OttoThemeCatalog.highfell, OttoThemeCatalog.graphite] {
      let base = OttoPalette(theme: theme)
      // Chat marks its palette as over artwork whenever the theme brings artwork.
      let palette = theme.backgroundAsset != nil ? base.overThemeArtwork() : base
      for (name, backdrop) in backdrops {
        let view = HStack(alignment: .top, spacing: 0) {
          sidebarFooter(palette)
            .frame(width: 248)
            .background(palette.washesTextOverArtwork ? palette.artworkWash : Color.clear)
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
              Image(systemName: "info.circle").foregroundStyle(palette.cyan)
              Text("Approved Bash: echo hi > a.txt")
                .font(.ottoMono(8, weight: .medium))
                .foregroundStyle(palette.muted)
            }
            .ottoArtworkBacking(cornerRadius: 6, horizontalPadding: 6, verticalPadding: 3)
            HStack(spacing: 7) {
              Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
              Text("Thought through 3 steps").font(.ottoDisplay(10.5).weight(.medium))
              Spacer(minLength: 0)
            }
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .ottoArtworkBacking(cornerRadius: 9, horizontalPadding: 4)
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 150)
        .background(backdrop)
        .environment(\.ottoPalette, palette)
        try await capture(view, size: NSSize(width: 560, height: 150), to: directory,
          name: "artwork-rows-\(theme.id)-\(name)")
      }
    }
  }

  private func sidebarFooter(_ palette: OttoPalette) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("SESSIONS").font(.ottoMicro).tracking(2.2).foregroundStyle(palette.muted)
      VStack(alignment: .leading, spacing: 2) {
        Text("Approval probe 4").font(.ottoDisplay(13))
          .foregroundStyle(palette.paper.opacity(OttoThemeDefinition.restingTextOpacity))
        Text("In a single message, call these…").font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
      }
      HStack(spacing: 10) {
        Image(systemName: "mic.slash.fill").font(.system(size: 12, weight: .bold))
          .foregroundStyle(palette.muted)
          .frame(width: 24, height: 24)
          .background(palette.raised, in: Circle())
        VStack(alignment: .leading, spacing: 1) {
          Text("Voice").font(.ottoDisplay(12.5).weight(.medium)).foregroundStyle(palette.paper)
          Text("Off").font(.ottoDisplay(10.5)).foregroundStyle(palette.muted)
        }
      }
      HStack(spacing: 6) {
        Image(systemName: "gearshape").font(.system(size: 12))
        Text("Settings").font(.ottoDisplay(12))
        Spacer()
        Circle().fill(palette.signal).frame(width: 6, height: 6)
        Text("0 ACTIVE").font(.ottoMicro).tracking(1.6)
      }
      .foregroundStyle(palette.muted)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func capture(
    _ view: some View, size: NSSize, to directory: String, name: String
  ) async throws {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }
}

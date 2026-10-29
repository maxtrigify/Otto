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
      try await capture(
        terminal, size: NSSize(width: 576, height: 166), to: directory,
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
      try await capture(
        band, size: NSSize(width: 420, height: 102), to: directory,
        name: "header-band-\(theme.id)")
    }
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

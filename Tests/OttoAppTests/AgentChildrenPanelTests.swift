import AppKit
import OttoModels
import OttoRuntime
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Inline subagents")
struct AgentChildrenPanelTests {
  /// Opt-in rendering exercises real SwiftUI layout at narrow and wide conversation sizes.
  @Test @MainActor func renderReferenceStates() async throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_CHILD_PANEL_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let states: [AgentChildRunState] = [.done, .working, .working, .failed, .waiting]
    let names = ["Review", "Runtime", "Interface", "Tests", "Verification"]
    let activities = [
      "Checked authentication and session expiry.",
      "Read Sources/OttoRuntime/AgentSupervisor.swift",
      "Edit Sources/OttoApp/AgentChildrenPanel.swift", "Test command exited with code 1.",
      "Waiting for the build to finish…",
    ]
    let children = states.enumerated().map { i, state in
      var child = AgentChildRun(
        id: "\(i)", name: names[i], activity: activities[i], state: state, toolCount: 3)
      child.task = "Verify the implementation and report the result."
      child.activityLog = [activities[i]]
      return child
    }
    for width in [390, 960] {
      for mode in ["expanded", "detail", "collapsed"] {
        let palette = OttoPalette(theme: OttoThemeCatalog.fieldNotes)
        let view = AgentChildrenPanel(
          children: children, parentName: "Claude Code", initiallyExpanded: mode != "collapsed",
          initiallySelectedID: mode == "detail" ? "3" : nil
        )
        .environment(\.ottoPalette, palette)
        .padding(20).frame(width: CGFloat(width)).background(palette.surface)
        let host = NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(
          contentRect: NSRect(x: -10000, y: -10000, width: width, height: 1000),
          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        #expect(height > 40 && height < 900)
        window.setContentSize(NSSize(width: CGFloat(width), height: height))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("\(width)-\(mode).png"))
      }
    }
  }
}

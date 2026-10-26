import AppKit
import Foundation
import OttoModels
import OttoRuntime
import OttoServices
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Chat welcome")
@MainActor
struct ChatWelcomeTests {
  @Test func codePromptsOnlyInsideAGitCheckout() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-welcome-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    #expect(
      WelcomeSuggestion.forDirectory(folder.path).map(\.label)
        == WelcomeSuggestion.workspace.map(\.label))
    #expect(
      WelcomeSuggestion.forDirectory(nil).map(\.label) == WelcomeSuggestion.workspace.map(\.label))

    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(
      WelcomeSuggestion.forDirectory(folder.path).map(\.label)
        == WelcomeSuggestion.code.map(\.label))
  }

  @Test func greetingFollowsTheTimeOfDay() {
    func at(_ hour: Int) -> Date {
      Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }
    #expect(WelcomeGreeting.text(now: at(8)).hasPrefix("Morning"))
    #expect(WelcomeGreeting.text(now: at(14)).hasPrefix("Afternoon"))
    #expect(WelcomeGreeting.text(now: at(21)).hasPrefix("Evening"))
  }

  @Test func serifFontIsBundled() {
    #expect(OttoSerifFont.registered)
  }

  /// Opt-in visual check. Set OTTO_WELCOME_SNAPSHOT_DIR to write PNGs.
  @Test func renderWelcome() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_WELCOME_SNAPSHOT_DIR"] else {
      return
    }
    let palette = OttoPalette(theme: OttoThemeCatalog.theme(id: "fieldNotes"))
    let bots = [
      AgentProfile(name: "Scout", role: "Research", instructions: "", provider: .claudeCode),
      AgentProfile(name: "Echo", role: "Inbox", instructions: "", provider: .codex),
      AgentProfile(name: "Bolt", role: "Ops", instructions: "", provider: .codex),
      AgentProfile(name: "Aria", role: "Writing", instructions: "", provider: .claudeCode),
    ]
    for (name, size, profiles) in [
      ("welcome-wide", CGSize(width: 1040, height: 700), bots),
      ("welcome-large", CGSize(width: 1180, height: 830), bots),
      ("welcome-short", CGSize(width: 720, height: 380), bots),
      ("welcome-no-bots", CGSize(width: 900, height: 640), [AgentProfile]()),
    ] {
      let node = OttoNode(
        kind: .agent, displayName: "Welcome", subtitle: "Codex",
        frame: WorldRect(x: 0, y: 0, width: 800, height: 600), zIndex: 0)
      let queue = AgentMessageQueue(state: { _ in .idle }, send: { _, _ in })
      let view = AgentConversationBody(
        node: node,
        snapshot: AgentRuntimeSnapshot(id: node.id, provider: .codex, state: .idle, confidence: 1),
        turnChanges: nil, turnDiff: { _ in nil }, revertTurn: {}, history: [],
        scale: 1, isSelected: true, presentation: .conversation, isStageMode: false,
        hidesSurfaceBar: true, enterStage: {}, focus: {}, setPresentation: { _ in },
        send: { _, _ in }, sendBytes: { _ in }, resize: { _, _ in }, interrupt: {},
        stop: {}, restart: {}, resolvePermission: { _ in }, alwaysAllowPermission: {},
        resolveChoice: { _ in }, setPermissionMode: { _ in }, setModel: { _, _ in },
        setExecutionStrategy: { _ in }, handoffTargets: { [] }, handoff: { _, _ in },
        openBrowser: { _ in }, mentionProfiles: profiles
      )
      .environmentObject(queue)
      .environment(\.ottoPalette, palette)
      .frame(width: size.width, height: size.height)
      try render(view, size: size, to: "\(output)/\(name).png")
    }

    let faces = HStack(spacing: 24) {
      OttoFace(size: 120)
      OttoFace(size: 120, look: CGSize(width: -1, height: 0.4))
      OttoFace(size: 120, look: CGSize(width: 0.2, height: 1))
      OttoFace(size: 120, blinking: true)
    }
    .padding(30)
    .background(Color(red: 0.08, green: 0.09, blue: 0.11))
    try render(faces, size: CGSize(width: 650, height: 180), to: "\(output)/welcome-faces.png")
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String) throws {
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}

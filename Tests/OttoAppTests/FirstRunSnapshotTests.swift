import AppKit
import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoServices
import SwiftUI
import Testing

@testable import OttoApp

/// Opt-in visual check of the first-run welcome, Home's Getting started card and the Home
/// tour. Set OTTO_FIRST_RUN_SNAPSHOT_DIR to run it.
@Suite("First-run snapshots")
@MainActor
struct FirstRunSnapshotTests {
  @Test func renderFirstRun() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_FIRST_RUN_SNAPSHOT_DIR"] else {
      return
    }
    let workspace = FileManager.default.temporaryDirectory.appending(path: "first-run-\(UUID())")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let canvas = CanvasStore()
    canvas.dispatch(.setTheme("highfell"))
    let services = ApplicationServices(store: canvas, workspacePath: workspace.path)
    let theme = OttoThemeCatalog.theme(id: "highfell")
    let palette = OttoPalette(theme: theme)
    let providers = try JSONDecoder().decode(
      [AgentProviderInfo].self,
      from: Data(
        """
        [{"provider":"Claude Code","installed":true,"compatibility":"supported"},
         {"provider":"Codex","installed":true,"compatibility":"supported"},
         {"provider":"Cursor","installed":false},{"provider":"Grok","installed":false},
         {"provider":"Kimi","installed":false},{"provider":"OpenCode","installed":false},
         {"provider":"Hermes","installed":false}]
        """.utf8))
    let size = CGSize(width: 1280, height: 820)

    for step in 0..<4 {
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        FirstRunWelcomeView(
          services: services, startStep: step, knownProviders: providers, complete: { _ in })
      }
      .environment(\.ottoPalette, palette)
      try render(view, size: size, to: "\(output)/welcome-\(step).png", light: true)
    }

    // Home after hiring Scout: name in the greeting, the first task in the box, the checklist.
    let defaults = UserDefaults.standard
    let keys = [
      FirstRunPreferences.preferredName, FirstRunPreferences.gettingStartedActive,
      FirstRunPreferences.gettingStartedDismissed, FirstRunPreferences.starterBotID,
    ]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
    let scout = try services.createBot(
      BotCreationRequest(
        name: "Scout", role: "Research assistant",
        responsibility: OnboardingInterest.research.starter.responsibility,
        persistResponsibilityAsJobTitle: false, provider: .claudeCode))
    defaults.set("Max", forKey: FirstRunPreferences.preferredName)
    defaults.set(true, forKey: FirstRunPreferences.gettingStartedActive)
    defaults.set(false, forKey: FirstRunPreferences.gettingStartedDismissed)
    defaults.set(scout.id.uuidString, forKey: FirstRunPreferences.starterBotID)

    for (name, step) in [("home", nil), ("tour-0", 0), ("tour-1", 1), ("tour-4", 4), ("tour-8", 8)]
      as [(String, Int?)]
    {
      let view = ZStack {
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        PersonalHomeView(
          store: canvas, services: services, activity: services.botActivity,
          brief: services.dailyBrief,
          draft: .constant(OnboardingInterest.research.starter.firstTask),
          provider: .constant(.claudeCode), conversationTarget: .constant(.bot(scout.id)),
          openMarkdown: { _ in }, openBot: { _ in },
          openAgent: { _ in }, openCloud: {}, openLibrary: { _ in }, hireBot: {},
          submit: { _, _, _ in })
      }
      .overlayPreferenceValue(HomeTourAnchorsKey.self) { anchors in
        if let step {
          HomeTourOverlay(anchors: anchors, stepIndex: .constant(step), finish: {})
        }
      }
      .environment(\.ottoPalette, palette)
      try render(view, size: size, to: "\(output)/\(name).png", light: true)
    }
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String, light: Bool) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}

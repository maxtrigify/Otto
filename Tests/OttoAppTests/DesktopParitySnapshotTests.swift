import AppKit
import OttoCore
import OttoModels
import OttoServices
import SwiftUI
import Testing

@testable import OttoApp

/// Reference renders of the Mac app's main window (Home and Chat) over a theme, so Otto Desktop
/// for Windows and Linux can be matched against the real thing. Opt-in:
/// `OTTO_PARITY_SNAPSHOT_DIR=<out> OTTO_PARITY_SNAPSHOT_WORKSPACE=<seed folder>
///  [OTTO_PARITY_THEME=halcyon]`.
@MainActor
struct DesktopParitySnapshotTests {
  @Test func renderMainWindow() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["OTTO_PARITY_SNAPSHOT_DIR"], let seed = env["OTTO_PARITY_SNAPSHOT_WORKSPACE"]
    else { return }
    let themeID = env["OTTO_PARITY_THEME"] ?? "halcyon"
    let workspace = FileManager.default.temporaryDirectory.appending(path: "parity-\(UUID())")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: seed), to: workspace)
    defer { try? FileManager.default.removeItem(at: workspace) }

    let store = CanvasStore()
    store.dispatch(.setTheme(themeID))
    let services = ApplicationServices(
      store: store, workspacePath: workspace.path,
      personalMemoryPath: workspace.appending(path: "user.md").path)
    let voice = VoiceController(
      registry: services.registry, store: store, services: services, observability: nil,
      workspacePath: workspace.path)
    let theme = OttoThemeCatalog.theme(id: themeID)
    let size = CGSize(width: 1280, height: 820)

    func window<Content: View>(_ content: Content) -> some View {
      ZStack {
        Color(red: theme.ink.red, green: theme.ink.green, blue: theme.ink.blue)
        ThemeBackgroundView(theme: theme, isActive: false, scrimScale: 0.25)
        content
      }
      .environmentObject(services.messageQueue)
      .environment(\.ottoPalette, OttoPalette(theme: theme))
    }

    let home = window(
      WorkspaceView(store: store, services: services, voice: voice, uiState: WorkspaceUIState()))
    try render(home, size: size, to: "\(output)/mac-home-\(themeID).png", light: theme.isLightAppearance)

    let navigation = Binding(
      get: { store.snapshot.chatNavigation }, set: { store.updateChatNavigation($0) })
    let chat = window(
      ChatWorkspaceView(
        store: store, services: services, voice: voice, navigation: navigation,
        launchAgent: {}))
    try render(chat, size: size, to: "\(output)/mac-chat-\(themeID).png", light: theme.isLightAppearance)
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String, light: Bool) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: path))
  }
}

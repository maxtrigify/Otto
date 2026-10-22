import AppKit
import Foundation
import OttoModels
import OttoRuntime
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Chat terminals")
@MainActor
struct ChatTerminalTests {
  @Test("Terminal status follows the runtime and falls back to the saved node status")
  func statusTransitions() {
    func status(_ state: AgentLifecycleState?, exit: Int32? = nil, token: String? = nil)
      -> ChatTerminalStatus
    {
      ChatTerminalStatus.resolve(state: state, exitCode: exit, attentionToken: token)
    }
    #expect(status(.starting) == .starting)
    #expect(status(.working) == .running)
    #expect(
      status(.waitingUser, token: TerminalInputWaitDetector.inputToken)
        == .waiting(hiddenInput: false))
    #expect(
      status(.waitingUser, token: TerminalInputWaitDetector.hiddenInputToken)
        == .waiting(hiddenInput: true))
    #expect(status(.done, exit: 0) == .finished)
    #expect(status(.done, exit: 2) == .failed(exitCode: 2))
    #expect(status(.failed, exit: 1) == .failed(exitCode: 1))
    #expect(status(.stopped) == .stopped)
    #expect(status(.interrupted) == .stopped)
    // No live process (Otto restarted): the saved status decides.
    #expect(ChatTerminalStatus.resolve(state: nil, exitCode: nil, attentionToken: nil) == .stopped)
    #expect(
      ChatTerminalStatus.resolve(state: nil, exitCode: nil, attentionToken: nil, fallback: .done)
        == .finished)

    #expect(ChatTerminalStatus.waiting(hiddenInput: false).label == "Waiting for you")
    #expect(ChatTerminalStatus.running.isLive)
    #expect(ChatTerminalStatus.waiting(hiddenInput: true).isLive)
    #expect(!ChatTerminalStatus.finished.isLive)
    #expect(ChatTerminalStatus.waiting(hiddenInput: false).isWaiting)
    #expect(!ChatTerminalStatus.running.isWaiting)
  }

  @Test("The retired Terminals destination restores Chat without breaking saved workspaces")
  func retiredTerminalsDestinationRestoresChat() throws {
    let encoded = Data("\"Terminals\"".utf8)
    #expect(try JSONDecoder().decode(ChatSurfaceDestination.self, from: encoded) == .conversation)
    #expect(!ChatSurfaceDestination.allCases.contains { $0.rawValue == "Terminals" })
  }

  /// Opt-in visual check of the work panel with a terminal waiting for the person. Set
  /// OTTO_TERMINAL_SNAPSHOT to an output path (for example /tmp/otto-terminal-waiting.png).
  @Test func renderWaitingTerminal() throws {
    guard let path = ProcessInfo.processInfo.environment["OTTO_TERMINAL_SNAPSHOT"] else { return }
    let theme = OttoThemeCatalog.theme(id: "fieldNotes")
    let palette = OttoPalette(theme: theme)
    let output =
      "\u{001B}[1mOtto setup\u{001B}[0m\r\n"
      + "Step 1 of 3  Checking Wrangler… \u{001B}[32mok\u{001B}[0m\r\n"
      + "Step 2 of 3  Cloudflare sign-in\r\n\r\n"
      + "Create a token at https://dash.cloudflare.com/profile/api-tokens\r\n"
      + "Paste your Cloudflare API token: "
    var snapshot = AgentRuntimeSnapshot(
      id: UUID(), provider: .shell, executionMode: .terminal, state: .waitingUser,
      confidence: 0.8, output: output, outputEndOffset: output.utf8.count,
      attentionReason: "Paste your Cloudflare API token:")
    snapshot.attentionToken = TerminalInputWaitDetector.hiddenInputToken
    let notice = ChatTerminalNotice(
      id: snapshot.id, title: "Setup script", prompt: "Paste your Cloudflare API token:",
      hiddenInput: true)

    let view = HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        Text("I've started the setup script. It will ask you for your Cloudflare API token.")
          .font(.ottoDisplay(14))
          .foregroundStyle(palette.paper)
        TerminalWaitingCard(notice: notice, open: {})
        Spacer()
      }
      .padding(22)
      .frame(width: 520)
      .frame(maxHeight: .infinity)
      .background(palette.chatCardSurface)
      Rectangle().fill(palette.paper.opacity(0.08)).frame(width: 1)
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 5) {
          Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
          Text("Setup script").font(.ottoDisplay(12))
          Circle().fill(palette.amber).frame(width: 6, height: 6)
        }
        .foregroundStyle(palette.paper)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        Divider().overlay(palette.paper.opacity(0.08))
        ChatTerminalPane(
          title: "Setup script", command: "bash scripts/setup.sh", ownerName: nil,
          snapshot: snapshot, sessionKey: "snapshot", send: { _ in }, resize: { _, _ in },
          stop: {})
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.paneSurface)
    }
    .background(palette.ink)
    .environment(\.ottoPalette, palette)
    try render(view, size: CGSize(width: 1240, height: 680), to: path)
  }

  private func render<V: View>(_ view: V, size: CGSize, to path: String) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
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

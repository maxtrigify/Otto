import AppKit
import OttoRuntime
import SwiftUI

/// Composer context tray: project · execution location · git branch as small uppercase chips
/// above the agent composer, refreshed live from the supervised process exactly like the node
/// footer badge. Chips open menus with safe actions (reveal, copy) — they never mutate a live
/// agent's checkout; launch-time choices stay in the agent launch sheet.
@MainActor
struct ComposerContextChips: View {
  @Environment(\.ottoPalette) private var palette
  let processID: Int32?
  /// Directory the agent was launched into, from its definition. Doubles as the resolve
  /// fallback and as the reference point for worktree detection.
  let launchDirectory: String?
  let hermesProfileID: String?
  let scale: Double
  let didCopy: (String) -> Void

  @ObservedObject private var monitor: WorkingContextMonitor

  init(
    processID: Int32?,
    launchDirectory: String?,
    hermesProfileID: String?,
    scale: Double,
    didCopy: @escaping (String) -> Void
  ) {
    self.processID = processID
    self.launchDirectory = launchDirectory
    self.hermesProfileID = hermesProfileID
    self.scale = scale
    self.didCopy = didCopy
    _monitor = ObservedObject(
      wrappedValue: WorkingContextMonitors.monitor(
        processID: processID,
        fallbackDirectory: launchDirectory
      ))
  }

  var body: some View {
    tray
      .onAppear { monitor.acquire() }
      .onDisappear { monitor.release() }
  }

  @ViewBuilder private var tray: some View {
    if let state = monitor.state {
      HStack(spacing: 4 * scale) {
        Menu {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([
              URL(fileURLWithPath: state.directory)
            ])
          } label: {
            Label("Reveal in Finder", systemImage: "folder")
          }
          Button {
            copyToPasteboard(state.directory, confirmation: "Path copied")
          } label: {
            Label("Copy path", systemImage: "doc.on.doc")
          }
        } label: {
          chipLabel(symbol: "folder", text: state.displayName)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(state.directory)
        .accessibilityLabel("Project \(state.displayName)")

        chipLabel(symbol: executionSymbol, text: executionLabel)
          .help(executionHelp)
          .accessibilityLabel("Runs in \(executionLabel)")

        if let branch = state.branch {
          Menu {
            Button {
              copyToPasteboard(branch, confirmation: "Branch copied")
            } label: {
              Label("Copy branch name", systemImage: "doc.on.doc")
            }
          } label: {
            chipLabel(symbol: "arrow.triangle.branch", text: branch)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("Current git branch")
          .accessibilityLabel("Branch \(branch)")
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8 * scale)
      .padding(.top, 5 * scale)
      .padding(.bottom, 11 * scale)
      .background(
        UnevenRoundedRectangle(
          topLeadingRadius: 9 * scale,
          topTrailingRadius: 9 * scale
        )
        .fill(palette.raised.opacity(0.55))
      )
      .overlay(
        UnevenRoundedRectangle(
          topLeadingRadius: 9 * scale,
          topTrailingRadius: 9 * scale
        )
        .stroke(palette.paper.opacity(0.06), lineWidth: 1)
      )
    }
  }

  private func chipLabel(symbol: String, text: String) -> some View {
    HStack(spacing: 4 * scale) {
      Image(systemName: symbol)
        .font(.system(size: max(7, 8 * scale), weight: .medium))
      Text(text.uppercased())
        .font(.ottoMono(max(6.5, 7.5 * scale), weight: .bold))
        .tracking(0.8)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .foregroundStyle(palette.muted)
    .padding(.horizontal, 8 * scale)
    .padding(.vertical, 3 * scale)
    .frame(maxWidth: 190 * scale)
    .fixedSize(horizontal: true, vertical: false)
    .contentShape(Capsule())
  }

  private var isWorktree: Bool {
    guard hermesProfileID == nil, let launchDirectory, let state = monitor.state else {
      return false
    }
    return state.directory != launchDirectory
  }

  private var executionLabel: String {
    switch hermesProfileID {
    case "hermes.remote": return "Remote"
    case "hermes.local": return "Hermes"
    default: return isWorktree ? "Worktree" : "Local"
    }
  }

  private var executionSymbol: String {
    switch hermesProfileID {
    case "hermes.remote": return "antenna.radiowaves.left.and.right"
    case "hermes.local": return "wing"
    default: return isWorktree ? "square.on.square" : "laptopcomputer"
    }
  }

  private var executionHelp: String {
    switch executionLabel {
    case "Remote": "Runs through the remote Hermes connection"
    case "Hermes": "Runs through the local Hermes connection"
    case "Worktree": "Runs in an isolated git worktree of this workspace"
    default: "Runs directly on this Mac"
    }
  }

  private func copyToPasteboard(_ value: String, confirmation: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    didCopy(confirmation)
  }

}

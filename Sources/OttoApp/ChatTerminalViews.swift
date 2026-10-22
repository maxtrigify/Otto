import AppKit
import OttoModels
import OttoRuntime
import SwiftUI

/// What a person needs to know about a terminal at a glance.
enum ChatTerminalStatus: Equatable {
  case starting
  case running
  /// Quiet at a prompt; `hiddenInput` when the program turned echo off (a password or key).
  case waiting(hiddenInput: Bool)
  case finished
  case failed(exitCode: Int32?)
  case stopped

  /// Resolves the status from the live runtime snapshot, falling back to the saved node status
  /// when the process is gone (for example after Otto restarted).
  static func resolve(
    state: AgentLifecycleState?, exitCode: Int32?, attentionToken: String?,
    fallback: NodeStatus = .stopped
  ) -> ChatTerminalStatus {
    guard let state else {
      switch fallback {
      case .done: return .finished
      case .failed: return .failed(exitCode: exitCode)
      default: return .stopped
      }
    }
    switch state {
    case .created, .starting: return .starting
    case .idle, .working: return .running
    case .waitingUser, .waitingPermission:
      return .waiting(hiddenInput: attentionToken == TerminalInputWaitDetector.hiddenInputToken)
    case .done: return (exitCode ?? 0) == 0 ? .finished : .failed(exitCode: exitCode)
    case .failed: return .failed(exitCode: exitCode)
    case .interrupted, .stopped: return .stopped
    }
  }

  static func resolve(_ snapshot: AgentRuntimeSnapshot?, fallback: NodeStatus = .stopped)
    -> ChatTerminalStatus
  {
    resolve(
      state: snapshot?.state, exitCode: snapshot?.exitCode,
      attentionToken: snapshot?.attentionToken, fallback: fallback)
  }

  var label: String {
    switch self {
    case .starting: "Starting"
    case .running: "Running"
    case .waiting: "Waiting for you"
    case .finished: "Finished"
    case .failed(let code): code.map { "Failed · exit \($0)" } ?? "Failed"
    case .stopped: "Stopped"
    }
  }

  var isLive: Bool {
    switch self {
    case .starting, .running, .waiting: true
    case .finished, .failed, .stopped: false
    }
  }

  var isWaiting: Bool {
    if case .waiting = self { return true }
    return false
  }

  var symbol: String {
    switch self {
    case .starting, .running: "circle.dotted"
    case .waiting: "hand.raised"
    case .finished: "checkmark.circle"
    case .failed: "xmark.circle"
    case .stopped: "stop.circle"
    }
  }

  func color(_ palette: OttoPalette) -> Color {
    switch self {
    case .starting, .running: palette.cyan
    case .waiting: palette.amber
    case .finished: palette.signal
    case .failed: palette.red
    case .stopped: palette.muted
    }
  }
}

/// A terminal waiting on the person, as the conversation that started it shows it.
struct ChatTerminalNotice: Identifiable, Equatable {
  let id: UUID
  let title: String
  let prompt: String?
  let hiddenInput: Bool
}

/// One terminal with everything a non-technical person needs around it: what it is, whether it
/// is waiting for them, and Stop / Copy command. Used in the work drawer.
struct ChatTerminalPane: View {
  @Environment(\.ottoPalette) private var palette
  let title: String
  let command: String?
  let ownerName: String?
  let snapshot: AgentRuntimeSnapshot?
  var fallbackStatus: NodeStatus = .stopped
  let sessionKey: String
  /// Bumped by the caller to put keyboard focus in the terminal (for example on reveal).
  var focusToken: Int = 0
  let send: (Data) -> Void
  let resize: (UInt16, UInt16) -> Void
  let stop: () -> Void
  var openConversation: (() -> Void)? = nil
  var remove: (() -> Void)? = nil

  @State private var localFocusToken = 0
  @State private var copied = false

  private var status: ChatTerminalStatus {
    ChatTerminalStatus.resolve(snapshot, fallback: fallbackStatus)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      if case .waiting(let hidden) = status {
        waitingBanner(hidden: hidden)
          .padding(.horizontal, 12)
          .padding(.bottom, 10)
          .transition(.opacity)
      }
      EmulatedTerminalView(
        output: snapshot?.output ?? "",
        outputStartOffset: snapshot?.outputStartOffset ?? 0,
        outputEndOffset: snapshot?.outputEndOffset ?? 0,
        sessionKey: sessionKey,
        acceptsInput: status.isLive,
        replayExistingOutput: true,
        send: send,
        resize: resize,
        focusToken: focusToken + localFocusToken
      )
      .padding(8)
      .background(palette.ink)
      .overlay {
        RoundedRectangle(cornerRadius: 2)
          .stroke(status.isWaiting ? palette.amber.opacity(0.45) : .clear, lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.18), value: status)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "terminal")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(palette.muted)
        .frame(width: 28, height: 28)
        .background(palette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.ottoDisplay(14).weight(.semibold))
          .foregroundStyle(palette.paper)
          .lineLimit(1)
        if let detail = headerDetail {
          Text(detail)
            .font(.ottoMono(10))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(command ?? detail)
        }
      }
      Spacer(minLength: 8)
      statusPill
      if let command, !command.isEmpty {
        actionButton(copied ? "Copied" : "Copy command", symbol: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        }
        .help("Copy the command so you can run it in your own Terminal app")
      }
      if let openConversation {
        actionButton("Open chat", symbol: "bubble.left", action: openConversation)
          .help("Open the conversation that started this terminal")
      }
      if status.isLive {
        actionButton("Stop", symbol: "stop.fill", tint: palette.red, action: stop)
          .help("Stop the command running in this terminal")
      } else if let remove {
        actionButton("Remove", symbol: "xmark", action: remove)
          .help("Remove this finished terminal from the list")
      }
    }
  }

  private var headerDetail: String? {
    let parts = [ownerName.map { "Started by \($0)" }, command].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var statusPill: some View {
    HStack(spacing: 5) {
      Image(systemName: status.symbol).font(.system(size: 10, weight: .semibold))
      Text(status.label).font(.ottoLabel(9.5, weight: .semibold))
    }
    .foregroundStyle(status.color(palette))
    .padding(.horizontal, 9)
    .frame(height: 22)
    .background(status.color(palette).opacity(0.12), in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(status.label)")
  }

  private func actionButton(
    _ title: String, symbol: String, tint: Color? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.ottoLabel(9.5, weight: .semibold))
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(palette.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint ?? palette.paper)
  }

  private func waitingBanner(hidden: Bool) -> some View {
    Button {
      localFocusToken += 1
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "hand.point.up.left")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(palette.amber)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: 4) {
          Text("This needs you")
            .font(.ottoDisplay(13).weight(.semibold))
            .foregroundStyle(palette.paper)
          Text("Click in the terminal below and follow the steps.")
            .font(.ottoDisplay(12))
            .foregroundStyle(palette.paper.opacity(0.86))
          if let prompt = snapshot?.attentionReason, !prompt.isEmpty {
            Text(prompt)
              .font(.ottoMono(11))
              .foregroundStyle(palette.muted)
              .lineLimit(2)
          }
          if hidden {
            Label(
              "What you type here stays hidden, which is normal for passwords and keys. "
                + "Otto does not record it.",
              systemImage: "eye.slash"
            )
            .font(.ottoDisplay(11))
            .foregroundStyle(palette.muted)
          }
        }
        Spacer(minLength: 8)
        Text("Type here")
          .font(.ottoLabel(9.5, weight: .semibold))
          .foregroundStyle(palette.ink)
          .padding(.horizontal, 11)
          .frame(height: 24)
          .background(palette.amber, in: Capsule())
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(palette.amber.opacity(0.22), lineWidth: 1)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("This terminal needs you. Put the cursor in the terminal.")
    .accessibilityHint(snapshot?.attentionReason ?? "")
  }
}

/// The inline transcript card for a terminal this conversation started that is waiting on the
/// person. It sits where the agent's own "needs you" notices appear.
struct TerminalWaitingCard: View {
  @Environment(\.ottoPalette) private var palette
  let notice: ChatTerminalNotice
  let open: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "terminal")
        .foregroundStyle(palette.amber)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        Text("Terminal is waiting for you · \(notice.title)")
          .font(.ottoDisplay(12.5).weight(.semibold))
          .foregroundStyle(palette.paper)
        if let prompt = notice.prompt, !prompt.isEmpty {
          Text(prompt)
            .font(.ottoMono(10.5))
            .foregroundStyle(palette.muted)
            .lineLimit(2)
        }
        Text(
          notice.hiddenInput
            ? "Click into it and type. What you type stays hidden."
            : "Click into it and follow the steps."
        )
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.muted)
      }
      Spacer(minLength: 8)
      Button(action: open) {
        Text("Open")
          .font(.ottoLabel(9.5, weight: .semibold))
          .padding(.horizontal, 12)
          .frame(height: 24)
          .foregroundStyle(palette.ink)
          .background(palette.amber, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open the \(notice.title) terminal")
    }
    .padding(12)
    .background(palette.amber.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.amber.opacity(0.22), lineWidth: 1))
    .accessibilityElement(children: .contain)
  }
}

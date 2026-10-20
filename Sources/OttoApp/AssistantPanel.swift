import OttoModels
import OttoServices
import SwiftUI

/// Who should help on a dashboard or document: a fresh agent or one of the person's bots.
enum AssistantTarget: Hashable {
  case provider(AgentProvider)
  case bot(UUID)

  static let defaultsKey = "otto.assistant.target"

  /// Remembered as "provider:Claude Code" or "bot:<uuid>".
  var storageValue: String {
    switch self {
    case .provider(let provider): "provider:\(provider.rawValue)"
    case .bot(let id): "bot:\(id.uuidString)"
    }
  }

  init?(storageValue: String) {
    if storageValue.hasPrefix("provider:"),
      let provider = AgentProvider(rawValue: String(storageValue.dropFirst(9)))
    {
      self = .provider(provider)
    } else if storageValue.hasPrefix("bot:"),
      let id = UUID(uuidString: String(storageValue.dropFirst(4)))
    {
      self = .bot(id)
    } else {
      return nil
    }
  }
}

/// Sends a message to the helper bound to `key` (a file path or "dashboard:<id>"), starting
/// one for `target` when there is none yet. Returns the helper's agent node.
typealias AssistantStarter = (
  _ target: AssistantTarget, _ message: String, _ key: String
) async throws -> UUID

/// Compact picker for the helper: Claude Code, Codex, or a saved bot.
struct AssistantPicker: View {
  @ObservedObject var services: ApplicationServices
  @Binding var target: AssistantTarget
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    Menu {
      Section("A fresh agent") {
        ForEach([AgentProvider.claudeCode, .codex], id: \.self) { provider in
          Button(provider.rawValue) { target = .provider(provider) }
        }
      }
      let bots = services.botRoster()
      if !bots.isEmpty {
        Section("Your bots") {
          ForEach(bots) { entry in
            Button(entry.profile.name) { target = .bot(entry.profile.id) }
          }
        }
      }
    } label: {
      Text(label).font(.ottoDisplay(12).weight(.medium))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Who helps")
  }

  private var label: String {
    switch target {
    case .provider(let provider): provider.rawValue
    case .bot(let id):
      services.botRoster().first { $0.profile.id == id }?.profile.name ?? "Bot"
    }
  }
}

/// The helper chat on the right of a document, sheet, deck or dashboard. It is styled like the
/// work panel beside a session, stays bound to what it sits next to, and never moves the person
/// into Chat: they watch the agent work right here.
enum AssistantPanelName {
  case ai
  case otto

  var title: String {
    switch self {
    case .ai: "AI"
    case .otto: "Otto"
    }
  }
}

struct WorkAssistantPanel<Top: View, Empty: View, Conversation: View>: View {
  @ObservedObject var services: ApplicationServices
  @Binding var target: AssistantTarget
  let sessionID: UUID?
  let actions: AssistantPanelActions
  /// The browser names its assistant Otto; other places keep the generic "AI" label.
  var named: AssistantPanelName = .ai
  @ViewBuilder let top: () -> Top
  @ViewBuilder let empty: () -> Empty
  @ViewBuilder let conversation: (UUID) -> Conversation
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider().overlay(palette.paper.opacity(0.08))
      top()
      if let sessionID {
        conversation(sessionID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          empty().frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
      }
    }
    .background(palette.paneSurface)
    .overlay(alignment: .leading) {
      Rectangle().fill(palette.paper.opacity(0.08)).frame(width: 1)
    }
  }

  private var header: some View {
    HStack(spacing: 6) {
      HStack(spacing: 5) {
        switch named {
        case .ai:
          Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.signal)
        case .otto:
          OttoMark(size: 17)
        }
        Text(named.title).font(.ottoDisplay(12).weight(.semibold))
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      AssistantPicker(services: services, target: $target)
        .foregroundStyle(palette.muted)
        .padding(.leading, 4)
        .help(sessionID == nil ? "Who helps" : "Switch helper (starts a new chat)")
      Spacer(minLength: 0)
      if sessionID != nil {
        Button(action: actions.newChat) {
          Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .semibold))
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.ottoChrome)
        .foregroundStyle(palette.muted)
        .help("New chat")
        .accessibilityLabel("New chat")
      }
      Button(action: actions.close) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          .frame(width: 26, height: 26)
      }
      .buttonStyle(.ottoChrome)
      .foregroundStyle(palette.muted)
      .help("Hide \(named.title)")
      .accessibilityLabel("Hide \(named.title)")
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
  }
}

/// What the panel's header buttons do.
struct AssistantPanelActions {
  let newChat: () -> Void
  let close: () -> Void
}

/// Starter ideas shown before the first message.
struct AssistantIdeas: View {
  let title: String
  let ideas: [String]
  let pick: (String) -> Void
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
      ForEach(ideas, id: \.self) { idea in
        Button {
          pick(idea)
        } label: {
          Text(idea).font(.ottoDisplay(12)).multilineTextAlignment(.leading)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(14)
  }
}

/// One-line prompt box used on Dashboards and Documents to ask the helper for something.
struct AssistantPromptBar: View {
  @ObservedObject var services: ApplicationServices
  let placeholder: String
  @Binding var target: AssistantTarget
  /// The side panel shows the picker in its header, so its box can leave it out.
  var showsPicker = true
  let send: (String) async -> Void
  @State private var text = ""
  @State private var sending = false
  @FocusState private var focused: Bool
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "sparkles").foregroundStyle(palette.signal)
      TextField(placeholder, text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(14))
        .foregroundStyle(palette.paper)
        .lineLimit(1...)
        .composerScroll(maxHeight: 150)
        .focused($focused)
        // The placeholder names the dashboard or document, so it scopes the draft too.
        .onChange(of: placeholder, initial: true) { old, new in
          if old != new {
            ComposerDrafts.save(text, for: "prompt:\(old)")
            text = ""
          }
          if text.isEmpty { text = ComposerDrafts.text(for: "prompt:\(new)") }
        }
        .onChange(of: text) { _, text in ComposerDrafts.save(text, for: "prompt:\(placeholder)") }
        .onSubmit(submit)
        .disabled(sending)
        .accessibilityLabel(placeholder)
      if showsPicker {
        AssistantPicker(services: services, target: $target)
          .foregroundStyle(palette.muted)
      }
      Button(action: submit) {
        Group {
          if sending {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
          }
        }
        .frame(width: 26, height: 26)
        .foregroundStyle(palette.ink)
        .background(palette.signal, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
      .accessibilityLabel("Send")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(palette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12).strokeBorder(palette.paper.opacity(0.1), lineWidth: 1))
  }

  private func submit() {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !sending else { return }
    sending = true
    Task {
      await send(prompt)
      text = ""
      sending = false
    }
  }
}

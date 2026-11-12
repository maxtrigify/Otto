import Foundation
import OttoModels

public enum AgentPresentationSurface: String, CaseIterable, Sendable {
  case conversation
  case terminal
}

/// Extracts only structured, human-readable provider text while a run is still in progress. Raw
/// PTY text is deliberately never used as a fallback: the complete byte stream belongs to the
/// terminal recovery surface, not the conversation surface.
public enum ProviderConversationProjection {
  public static func liveText(from output: String, provider: AgentProvider) -> String? {
    var live = ProviderLiveText(provider: provider)
    for line in String(output.suffix(64_000)).split(whereSeparator: \.isNewline) {
      live.ingest(providerJSONObject(String(line)))
    }
    return live.text
  }
}

/// The readable text of the reply an agent is in the middle of producing, built up one output
/// record at a time.
///
/// The supervisor feeds it each record as the record arrives, so showing "what is the agent saying
/// right now" costs the size of the new record. Deriving it from the raw output instead meant
/// re-reading and re-decoding the tail of the scrollback on every redraw of the chat.
public struct ProviderLiveText: Sendable, Equatable {
  public let provider: AgentProvider
  private var completedMessage: String?
  private var streamedText = ""

  /// Only the last `displayLimit` characters are ever shown, so a long streamed reply is trimmed
  /// back to `retainedLimit` once it passes twice that, keeping memory and each read bounded.
  private static let displayLimit = 4_000
  private static let retainedLimit = 16_000

  public init(provider: AgentProvider) {
    self.provider = provider
  }

  /// Forgets the current reply. Called when a new turn starts, so the previous turn's last
  /// message is not offered as the next turn's live text.
  public mutating func reset() {
    completedMessage = nil
    streamedText = ""
  }

  public mutating func ingest(_ object: [String: Any]?) {
    guard let object else { return }
    if let parent = object["parent_tool_use_id"] as? String, !parent.isEmpty { return }
    apply(object)
    if streamedText.count > Self.retainedLimit * 2 {
      streamedText = String(streamedText.suffix(Self.retainedLimit))
    }
  }

  /// In-flight deltas are the most current signal; the last completed message is the fallback so
  /// reconnecting mid-run still shows something readable.
  public var text: String? {
    let streamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let structured =
      streamed.isEmpty
      ? (completedMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      : streamed
    return structured.isEmpty ? nil : String(structured.suffix(Self.displayLimit))
  }

  private mutating func apply(_ object: [String: Any]) {
    switch provider {
    case .claudeCode, .grok:
      switch object["type"] as? String {
      case "assistant":
        guard let message = object["message"] as? [String: Any],
          let content = message["content"] as? [[String: Any]]
        else { return }
        let text = content.compactMap { item -> String? in
          guard item["type"] as? String == "text" else { return nil }
          return item["text"] as? String
        }.joined()
        // A completed message supersedes the deltas that streamed it; anything streamed
        // afterwards belongs to the next in-flight message.
        if !text.isEmpty {
          completedMessage = text
          streamedText = ""
        }
      case "stream_event":
        guard let event = object["event"] as? [String: Any],
          event["type"] as? String == "content_block_delta",
          let delta = event["delta"] as? [String: Any],
          delta["type"] as? String == "text_delta",
          let text = delta["text"] as? String
        else { return }
        streamedText += text
      default:
        return
      }
    case .codex, .openAI:
      guard let type = object["type"] as? String else { return }
      if ["item.started", "item.updated", "item.completed"].contains(type),
        let item = object["item"] as? [String: Any],
        item["type"] as? String == "agent_message",
        let text = item["text"] as? String,
        !text.isEmpty
      {
        completedMessage = text
        if type == "item.completed" { streamedText = "" }
      } else if ["item.delta", "agent_message.delta", "agent_message_delta"].contains(type) {
        let delta = object["delta"] as? String ?? object["text"] as? String
        if let delta { streamedText += delta }
      }
    case .hermes:
      guard let type = object["type"] as? String,
        let payload = object["payload"] as? [String: Any]
      else { return }
      if type == "message.delta", let text = payload["text"] as? String {
        streamedText += text
      } else if type == "message.complete", let text = payload["text"] as? String {
        completedMessage = text
        streamedText = ""
      }
    case .kimi:
      // Print mode emits whole messages rather than deltas, so the newest assistant message
      // with prose is the most current readable text.
      guard object["role"] as? String == "assistant" else { return }
      let text = KimiOutputParser.messageText(object["content"])
      if !text.isEmpty {
        completedMessage = text
        streamedText = ""
      }
    case .cursor:
      // Assistant prose arrives as whole Claude-shaped messages, so the newest one is the most
      // current readable text; `result` repeats it and must not double-post.
      guard object["type"] as? String == "assistant" else { return }
      let text = CursorOutputParser.messageText(object["message"])
      if !text.isEmpty {
        completedMessage = text
        streamedText = ""
      }
    case .openCode:
      // One event per line, each wrapping a typed part; the newest text part is the most
      // current readable answer.
      guard object["type"] as? String == "text",
        let part = object["part"] as? [String: Any],
        let text = part["text"] as? String,
        !text.isEmpty
      else { return }
      completedMessage = text
      streamedText = ""
    case .pi:
      // Deltas stream as `message_update` records and the authoritative text arrives in the
      // assistant `message_end`, so the newest completed message is the readable answer.
      guard let type = object["type"] as? String else { return }
      if type == "message_update",
        let update = object["assistantMessageEvent"] as? [String: Any],
        update["type"] as? String == "text_delta",
        let delta = update["delta"] as? String
      {
        streamedText += delta
      } else if type == "message_end",
        let message = object["message"] as? [String: Any],
        message["role"] as? String == "assistant"
      {
        let text = PiOutputParser.messageText(message["content"])
        if !text.isEmpty {
          completedMessage = text
          streamedText = ""
        }
      }
    case .shell:
      // Shell output is terminal output by definition and must never leak into agent chat.
      return
    }
  }
}

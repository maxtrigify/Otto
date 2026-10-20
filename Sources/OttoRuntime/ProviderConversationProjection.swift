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
    let lines = String(output.suffix(64_000)).split(whereSeparator: \.isNewline)
    var completedMessage: String?
    var streamedText = ""

    for line in lines {
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if let parent = object["parent_tool_use_id"] as? String, !parent.isEmpty { continue }

      switch provider {
      case .claudeCode, .grok:
        switch object["type"] as? String {
        case "assistant":
          guard let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
          else { continue }
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
          else { continue }
          streamedText += text
        default:
          continue
        }
      case .codex, .openAI:
        guard let type = object["type"] as? String else { continue }
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
        else { continue }
        if type == "message.delta", let text = payload["text"] as? String {
          streamedText += text
        } else if type == "message.complete", let text = payload["text"] as? String {
          completedMessage = text
          streamedText = ""
        }
      case .kimi:
        // Print mode emits whole messages rather than deltas, so the newest assistant message
        // with prose is the most current readable text.
        guard object["role"] as? String == "assistant" else { continue }
        let text = KimiOutputParser.messageText(object["content"])
        if !text.isEmpty {
          completedMessage = text
          streamedText = ""
        }
      case .cursor:
        // Assistant prose arrives as whole Claude-shaped messages, so the newest one is the most
        // current readable text; `result` repeats it and must not double-post.
        guard object["type"] as? String == "assistant" else { continue }
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
        else { continue }
        completedMessage = text
        streamedText = ""
      case .shell:
        // Shell output is terminal output by definition and must never leak into agent chat.
        return nil
      }
    }

    // In-flight deltas are the most current signal; fall back to the last completed message so
    // reconnecting mid-run still shows something readable.
    let streamed = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
    let structured =
      streamed.isEmpty
      ? (completedMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      : streamed
    return structured.isEmpty ? nil : String(structured.suffix(4_000))
  }
}

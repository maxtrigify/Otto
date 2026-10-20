import Foundation
import OttoModels

/// A provider run that stopped because the account hit its subscription or API usage limit.
///
/// Detection is deliberately provider-neutral: every CLI words the limit differently, but all of
/// them surface it as terminal text or a result message. Otto only needs to know that the run
/// stopped for this reason and, when stated, when the limit resets.
public struct ProviderUsageLimit: Equatable, Sendable {
  public var provider: AgentProvider
  /// The provider's own wording, trimmed for display.
  public var message: String
  public var resetsAt: Date?

  public init(provider: AgentProvider, message: String, resetsAt: Date? = nil) {
    self.provider = provider
    self.message = message
    self.resetsAt = resetsAt
  }

  /// Phrases providers use for subscription or quota exhaustion (lowercased). Generic HTTP
  /// rate-limit wording is included because the Otto harness, Grok, Kimi and OpenCode surface
  /// backend errors verbatim.
  static let signals = [
    "usage limit reached", "usage limit has been reached", "hit your usage limit",
    "you've hit your limit", "you have hit your limit", "hit your limit", "limit reached",
    "usage_limit_reached", "rate_limit_error", "rate limit reached", "rate limit exceeded",
    "rate_limit_exceeded", "rate_limit_reached", "exceeded your current quota",
    "exceeded_current_quota", "insufficient_quota", "quota exceeded", "too many requests",
    "credit balance is too low", "out of credits", "weekly limit", "5-hour limit",
  ]

  /// Returns a limit when `text` reports one. `text` should be the run's result or the tail of
  /// its output, not a whole conversation: a normal answer that merely discusses rate limits
  /// must not trip this, so completed runs should pass only short result text.
  public static func detect(
    in text: String, provider: AgentProvider, now: Date = .now, calendar: Calendar = .current
  ) -> ProviderUsageLimit? {
    let lowered = text.lowercased()
    guard let signal = signals.first(where: { lowered.contains($0) }) else { return nil }
    let line =
      text.split(whereSeparator: \.isNewline)
      .map(String.init)
      .last { $0.lowercased().contains(signal) } ?? text
    return ProviderUsageLimit(
      provider: provider,
      message: displayMessage(line),
      resetsAt: resetDate(in: text, now: now, calendar: calendar))
  }

  private static func displayMessage(_ line: String) -> String {
    var message = line.trimmingCharacters(in: .whitespacesAndNewlines)
    // Claude's legacy form appends a Unix reset timestamp: "…usage limit reached|1727614800".
    if let bar = message.firstIndex(of: "|"),
      Int(message[message.index(after: bar)...].trimmingCharacters(in: .whitespaces)) != nil
    {
      message = String(message[..<bar])
    }
    return String(message.prefix(240))
  }

  static func resetDate(in text: String, now: Date, calendar: Calendar) -> Date? {
    let lowered = text.lowercased()
    // "…limit reached|1727614800"
    if let match = lowered.firstMatch(of: /\|\s*(\d{10})\b/),
      let seconds = TimeInterval(match.1), seconds > now.timeIntervalSince1970
    {
      return Date(timeIntervalSince1970: seconds)
    }
    // "try again in 2 hours 13 minutes", "resets in 45 minutes", "in 3h 5m"
    if let match = lowered.firstMatch(
      of:
        /(?:try again|resets?|available again)\s+in\s+(?:(\d+)\s*(?:hours?|hrs?|h)\b)?\s*(?:(\d+)\s*(?:minutes?|mins?|m)\b)?/
    ), match.1 != nil || match.2 != nil {
      let hours = Int(match.1.map(String.init) ?? "0") ?? 0
      let minutes = Int(match.2.map(String.init) ?? "0") ?? 0
      return now.addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
    }
    // "resets 2pm", "resets at 14:00", "try again at 3:05 PM"
    if let match = lowered.firstMatch(
      of: /(?:resets?|try again|available again)(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/
    ) {
      guard var hour = Int(match.1) else { return nil }
      let minute = Int(match.2.map(String.init) ?? "0") ?? 0
      switch match.3.map(String.init) {
      case "pm"? where hour < 12: hour += 12
      case "am"? where hour == 12: hour = 0
      default: break
      }
      guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
      return calendar.nextDate(
        after: now, matching: DateComponents(hour: hour, minute: minute),
        matchingPolicy: .nextTime)
    }
    return nil
  }
}

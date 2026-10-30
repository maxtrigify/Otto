import Foundation
import OttoRuntime

/// The line under a reply: how long the turn took and, when the provider reported them, its
/// tokens, such as "12s · 1.2k in · 340 out".
enum TurnStatsText {
  static func summary(_ stats: AgentTurnStats) -> String {
    var parts = [duration(stats.durationSeconds)]
    if let input = stats.inputTokens { parts.append("\(compact(input)) in") }
    if let output = stats.outputTokens { parts.append("\(compact(output)) out") }
    return parts.joined(separator: " · ")
  }

  static func detail(_ stats: AgentTurnStats) -> String {
    var text = "Took \(duration(stats.durationSeconds))"
    switch (stats.inputTokens, stats.outputTokens) {
    case (let input?, let output?):
      text +=
        ", \(input.formatted()) input and \(output.formatted()) output tokens (\((input + output).formatted()) total)"
    case (let input?, nil): text += ", \(input.formatted()) input tokens"
    case (nil, let output?): text += ", \(output.formatted()) output tokens"
    case (nil, nil): text += ". This provider does not report tokens"
    }
    return text + "."
  }

  static func duration(_ seconds: Double) -> String {
    let seconds = max(0, seconds)
    if seconds < 10 { return String(format: "%.1fs", seconds) }
    let whole = Int(seconds.rounded())
    if whole < 60 { return "\(whole)s" }
    if whole < 3_600 { return "\(whole / 60)m \(String(format: "%02d", whole % 60))s" }
    return "\(whole / 3_600)h \(String(format: "%02d", whole % 3_600 / 60))m"
  }

  static func compact(_ tokens: Int) -> String {
    switch tokens {
    case ..<1_000: "\(tokens)"
    case ..<1_000_000: trimmed(Double(tokens) / 1_000) + "k"
    default: trimmed(Double(tokens) / 1_000_000) + "M"
    }
  }

  private static func trimmed(_ value: Double) -> String {
    value >= 100
      ? String(Int(value.rounded()))
      : String(format: "%.1f", value)
        .replacingOccurrences(of: ".0", with: "")
  }
}

import Foundation
import OttoModels

/// Deterministic mention resolution. Exact name (or handle) wins; description/jobTitle
/// is a fallback. Ambiguity never guesses.
public enum BotMentionResolver {
  public static func resolve(_ raw: String, in profiles: [AgentProfile]) -> BotMentionResolution {
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if token == "@user" || token.caseInsensitiveCompare("user") == .orderedSame {
      return .user
    }
    let needle = normalize(token.hasPrefix("@") ? String(token.dropFirst()) : token)
    guard !needle.isEmpty else { return .none }

    if let exactName = profiles.first(where: { normalize($0.name) == needle }) {
      return .matched(exactName)
    }
    if let exactHandle = profiles.first(where: { $0.handle == needle }) {
      return .matched(exactHandle)
    }

    let descriptive = profiles.filter { profile in
      normalize(profile.jobTitle ?? "").contains(needle)
        || normalize(profile.role).contains(needle)
        || normalize(profile.name).contains(needle)
    }
    if descriptive.count == 1 { return .matched(descriptive[0]) }
    if descriptive.count > 1 { return .ambiguous(descriptive) }
    return .none
  }

  public static func mentions(in text: String) -> [String] {
    let pattern = #"@([A-Za-z0-9_-]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let tokenRange = Range(match.range, in: text) else { return nil }
      return String(text[tokenRange])
    }
  }

  private static func normalize(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

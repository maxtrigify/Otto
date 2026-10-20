import Foundation

/// Deliberately bounded recall phrases; ordinary task text does not trigger extra retrieval.
public enum MemoryRecallIntent {
  public static func matches(_ prompt: String) -> Bool {
    guard !TrivialPromptFilter.isTrivial(prompt) else { return false }
    let text = prompt.replacingOccurrences(of: "’", with: "'")
    return text.range(
      of:
        #"(?i)\b(?:what do you know|do you remember|did we (?:already|decide)|remind me|what's the status of|last time|history of|about me)\b"#,
      options: .regularExpression) != nil
  }
}

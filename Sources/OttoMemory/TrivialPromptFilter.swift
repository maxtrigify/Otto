import Foundation

/// Decides whether a prompt carries enough signal to be worth remembering.
///
/// The deterministic auto-log is what makes the Project Brain trustworthy — every completed run
/// leaves a record, with no agent cooperation required. The cost is that "hello", "ok", and
/// "/clear" each leave a permanent record too, competing for search rank against real work.
/// This gate keeps the guarantee (nothing substantive is dropped) while refusing the noise.
///
/// Ported from Hermes' `is_trivial_prompt` (NousResearch/hermes-agent,
/// `agent/memory_provider.py`). Two properties are load-bearing and deliberately preserved:
///
/// - **Anchored at both ends.** A trivial word must be the *entire* prompt, bar trailing
///   punctuation. "k8s", "note the auth bug", and "continue the migration from yesterday" are
///   all substantive; "hi!", "thanks :)", and "done???" are not.
/// - **One source of truth.** The write gate and any future recall gate must consult this same
///   list, or the two drift and a prompt that was too trivial to remember becomes one we try to
///   recall against.
///
/// The list stays conservative on purpose: a false negative costs one junk record, a false
/// positive silently loses real history.
public enum TrivialPromptFilter {
  /// Acknowledgements, greetings, and bare continuations — prompts whose whole content is a
  /// conversational beat rather than a task.
  public static let trivialPhrases: Set<String> = [
    "yes", "no", "ok", "okay", "sure", "thanks", "thank you", "y", "n", "yep", "nope", "yeah",
    "nah", "hi", "hey", "hello", "yo", "sup", "continue", "go ahead", "do it", "proceed",
    "got it", "cool", "nice", "great", "done", "next", "lgtm", "k",
  ]

  /// Trailing characters stripped before matching, so "hi!", "done???" and "thanks :)" resolve
  /// to their bare phrase. Only *trailing* runs are stripped — interior punctuation still makes
  /// a prompt substantive.
  private static let trailingNoise = CharacterSet(
    charactersIn: "!?.:;,\"'~‘’“”—–…()[]{}<>*&^%$#@+=`\u{00a0}"
  )
  .union(.whitespacesAndNewlines)

  /// Returns true when `text` carries no semantic signal worth persisting.
  ///
  /// Empty or whitespace-only input, slash commands, and bare greetings or acknowledgements all
  /// count as trivial.
  public static func isTrivial(_ text: String?) -> Bool {
    guard let text else { return true }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    // Slash commands are harness control, not work: "/clear", "/model opus".
    if trimmed.hasPrefix("/") { return true }

    var stripped = Substring(trimmed.lowercased())
    while let last = stripped.last, last.unicodeScalars.allSatisfy(trailingNoise.contains) {
      stripped = stripped.dropLast()
    }
    guard !stripped.isEmpty else { return true }
    return trivialPhrases.contains(String(stripped))
  }
}

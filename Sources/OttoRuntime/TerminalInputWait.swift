import Foundation

/// Decides whether a supervised command terminal has stopped to wait for the person, from the
/// tail of what it printed. It only runs after the output has been quiet for `quietInterval`
/// while the process is still alive, so a busy build never trips it.
public enum TerminalInputWaitDetector {
  /// How long a command terminal must be silent before its last line is read as a prompt.
  public static let quietInterval: Duration = .seconds(2)

  /// Attention tokens a terminal sets while it waits; anything else belongs to a provider.
  public static let inputToken = "terminal-input"
  public static let hiddenInputToken = "terminal-hidden-input"

  public static func isTerminalAttentionToken(_ token: String?) -> Bool {
    token == inputToken || token == hiddenInputToken
  }

  /// The prompt the terminal is waiting on, or nil when the tail does not look like one.
  /// `echoDisabled` is true when the PTY has local echo off (a password or `read -s`): the line
  /// still has to look like a prompt, but a bare partial line is then enough.
  public static func waitingPrompt(in output: String, echoDisabled: Bool = false) -> String? {
    let plain = TerminalOutputSearch.sanitizedExcerpt(String(output.suffix(4_096)), limit: 2_048)
    guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let lines = plain.components(separatedBy: "\n")
    // The cursor sits on the prompt line when the output does not end with a newline.
    let partial = lines.last?.trimmingCharacters(in: .whitespaces) ?? ""
    let recent = lines.suffix(6).map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty
    }

    // Menu prompts (inquirer, prompts, clack) repaint above the cursor, so look a few lines up.
    if let menu = recent.last(where: isMenuPrompt) { return clipped(menu) }

    if !partial.isEmpty {
      if looksLikePrompt(partial, partial: true) { return clipped(partial) }
      if echoDisabled { return clipped(partial) }
      return nil
    }
    guard let last = recent.last, looksLikePrompt(last, partial: false) else { return nil }
    return clipped(last)
  }

  /// Short, friendly name for a terminal started with `command`: `bash scripts/setup.sh` becomes
  /// "Setup script", `npx wrangler login` becomes "Wrangler login".
  public static func friendlyTitle(forCommand command: String?) -> String {
    guard let command = command?.trimmingCharacters(in: .whitespacesAndNewlines),
      !command.isEmpty
    else { return "Terminal" }
    let steps = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
      .map(commandWords).filter { !$0.isEmpty }
    // A script anywhere in the line names it best (`cd app && ./setup.sh`); otherwise the first
    // step that does real work rather than moving around or printing.
    if let script = steps.lazy.compactMap({ $0.first.flatMap(scriptTitle) }).first {
      return script
    }
    let housekeeping: Set<String> = [
      "cd", "export", "source", ".", "set", "unset", "echo", "printf", "read", "sleep", "clear",
      "true", "exit",
    ]
    guard let step = steps.first(where: { !housekeeping.contains($0[0]) }) else {
      return "Command"
    }
    let summary = step.prefix(3).filter { !$0.hasPrefix("-") }.joined(separator: " ")
    return clipped(capitalizedFirst(summary.isEmpty ? step[0] : summary), limit: 40)
  }

  /// The words of one shell step without wrappers that hide what it runs (`sudo`, `env X=1`,
  /// `bash`, `npx -y`).
  private static func commandWords(_ step: String) -> [String] {
    var words = step.split(separator: " ").map {
      String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }.filter { !$0.isEmpty }
    let wrappers: Set<String> = [
      "sudo", "exec", "env", "bash", "sh", "zsh", "node", "python", "python3", "ruby", "deno",
      "bun", "time", "nohup", "npx", "pnpx", "bunx",
    ]
    while let first = words.first,
      wrappers.contains(first) || first.contains("=") || (first.hasPrefix("-") && words.count > 1)
    {
      words.removeFirst()
    }
    return words
  }

  private static func scriptTitle(_ word: String) -> String? {
    let scriptExtensions: Set<String> = [
      "sh", "bash", "zsh", "py", "js", "mjs", "ts", "rb", "command",
    ]
    let ext = (word as NSString).pathExtension.lowercased()
    guard word.contains("/") || scriptExtensions.contains(ext) else { return nil }
    let base = ((word as NSString).lastPathComponent as NSString).deletingPathExtension
    let words = base.replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !words.isEmpty else { return nil }
    let titled = capitalizedFirst(words)
    return titled.lowercased().hasSuffix("script") ? titled : "\(titled) script"
  }

  // MARK: Heuristics

  /// Phrases that mean "your turn" wherever they appear on the last line.
  private static let explicitPromptPhrases = [
    "press enter", "press return", "press any key", "hit enter", "hit return", "press a key",
    "[y/n]", "(y/n)", "[yes/no]", "(yes/no)", "y/n?", "are you sure",
  ]

  /// Words that make a line ending in ":" or "?" read as a question rather than a log heading.
  private static let promptVerbs = [
    "enter", "paste", "type", "press", "choose", "select", "pick", "provide", "input", "confirm",
    "continue", "proceed", "would you", "do you", "what", "which", "name", "email", "key",
    "token", "password", "passphrase", "secret", "code", "answer",
  ]

  static func looksLikePrompt(_ line: String, partial: Bool) -> Bool {
    let lowered = line.lowercased()
    if explicitPromptPhrases.contains(where: { lowered.contains($0) }) { return true }
    let asksQuestion = lowered.hasSuffix(":") || lowered.hasSuffix("?")
    let hasVerb = promptVerbs.contains(where: { lowered.contains($0) })
    if partial {
      // The cursor is parked on this line. Arrow glyphs and a trailing colon or question mark are
      // prompts; a trailing ellipsis only when it asks for something ("Press any key…"), since
      // "Installing dependencies..." also pauses on one line.
      if asksQuestion || ["›", "❯", "»"].contains(where: { lowered.hasSuffix($0) }) {
        return true
      }
      return (lowered.hasSuffix("…") || lowered.hasSuffix("...")) && hasVerb
    }
    // A finished line followed by silence is usually a log line. Only count it when it both ends
    // like a question and reads like one ("Paste your token below:").
    return asksQuestion && hasVerb
  }

  static func isMenuPrompt(_ line: String) -> Bool {
    let lowered = line.lowercased()
    return lowered.contains("use arrow keys") || lowered.contains("arrow keys to")
      || lowered.contains("(use arrow") || lowered.contains("space to select")
      || (lowered.hasPrefix("? ") && (lowered.contains("›") || lowered.hasSuffix("?")))
  }

  private static func capitalizedFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
  }

  private static func clipped(_ text: String, limit: Int = 160) -> String {
    text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
  }
}

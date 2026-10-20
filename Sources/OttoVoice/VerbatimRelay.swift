import Foundation
import OttoModels

struct VerbatimRelayIntent: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case inline
    case previousUtterance
  }

  var targetID: UUID
  var targetName: String
  var prompt: String
  var source: Source
}

enum VerbatimRelayParseResult: Equatable, Sendable {
  case noMatch
  case relay(VerbatimRelayIntent)
  case rejected(String)
}

/// Routes "tell/ask <agent> …" speech to the named agent word-for-word, locally and immediately —
/// the dictation experience, not a model paraphrase. Saying "verbatim" is still honored as the
/// explicit form; it is no longer required. The distinction that remains: explicit requests fail
/// loudly (a spoken error) when they cannot be satisfied, while implicit phrasings quietly fall
/// through to the realtime model, which may know how to interpret them.
enum VerbatimRelayParser {
  static func parse(
    _ transcript: String,
    context: VoiceContext?,
    previousUtterance: String?
  ) -> VerbatimRelayParseResult {
    let explicit = mentionsVerbatim(transcript)
    guard looksLikeRelayCommand(transcript) else { return .noMatch }
    guard let context else {
      return explicit ? .rejected("Verbatim relay needs the current canvas context") : .noMatch
    }

    let agents = context.nodes.filter { $0.kind == .agent }
    let crossTurnTargets = agents.filter { agent in
      matchesPreviousUtteranceRelay(transcript, targetName: agent.name)
    }
    if crossTurnTargets.count > 1 {
      return .rejected("Verbatim relay target is ambiguous; use one exact agent name")
    }
    if let target = crossTurnTargets.first {
      guard let previousUtterance, !previousUtterance.isEmpty else {
        // Explicit "verbatim" must never degrade into a model rewrite; without the keyword the
        // model may still resolve the reference from its own conversation context.
        return explicit
          ? .rejected("There is no recent utterance available to send verbatim")
          : .noMatch
      }
      return .relay(
        VerbatimRelayIntent(
          targetID: target.id,
          targetName: target.name,
          prompt: previousUtterance,
          source: .previousUtterance
        ))
    }

    var matches: [VerbatimRelayIntent] = []
    for agent in agents {
      let escapedName = NSRegularExpression.escapedPattern(for: agent.name)
      // The explicit form keeps its historical payload boundaries exactly; the implicit form
      // additionally swallows one leading connective ("to"/"that") so "tell Chase to fix the
      // tests" relays the imperative "fix the tests".
      let explicitPrefix =
        #"^\s*(?:(?:hey|okay|ok|please|otto|muse|voice)\b[\s,]*)*(?:(?:send|relay|pass)\s+(?:(?:this|the\s+following)\s+)?(?:to\s+)?|(?:tell|ask|prompt)\s+)"#
        + escapedName
        + #"\s+(?:this\s+)?verbatim\b[\s,:;\-–—]*(.+?)\s*$"#
      let implicitPrefix =
        #"^\s*(?:(?:hey|okay|ok|please|otto|muse|voice)\b[\s,]*)*(?:tell|ask)\s+"#
        + escapedName
        + #"[\s,:;\-–—]+(?:(?:to|that)\s+)?(.+?)\s*$"#
      let suffix =
        #"^(.+?)\s+(?:and\s+|then\s+)?(?:send|relay|pass)\s+(?:that|this)\s+(?:over\s+)?to\s+"#
        + escapedName
        + #"(?:\s+verbatim)?[\s.!?]*$"#

      if let prompt = capture(in: transcript, pattern: explicitPrefix, group: 1, suffixForm: false)
      {
        matches.append(
          VerbatimRelayIntent(
            targetID: agent.id,
            targetName: agent.name,
            prompt: prompt,
            source: .inline
          ))
      } else if let prompt = capture(
        in: transcript, pattern: implicitPrefix, group: 1, suffixForm: false)
      {
        matches.append(
          VerbatimRelayIntent(
            targetID: agent.id,
            targetName: agent.name,
            prompt: prompt,
            source: .inline
          ))
      }
      if let prompt = capture(in: transcript, pattern: suffix, group: 1, suffixForm: true) {
        matches.append(
          VerbatimRelayIntent(
            targetID: agent.id,
            targetName: agent.name,
            prompt: prompt,
            source: .inline
          ))
      }
    }

    let unique = matches.reduce(into: [String: VerbatimRelayIntent]()) { result, intent in
      result["\(intent.targetID.uuidString):\(intent.prompt)"] = intent
    }.map(\.value)
    guard unique.count == 1, let intent = unique.first else {
      if unique.count > 1 {
        return .rejected("Verbatim relay target is ambiguous; use one exact agent name")
      }
      return explicit
        ? .rejected("Verbatim relay needs one exact agent name and a prompt")
        : .noMatch
    }
    return .relay(intent)
  }

  private static func matchesPreviousUtteranceRelay(
    _ transcript: String,
    targetName: String
  ) -> Bool {
    let escapedName = NSRegularExpression.escapedPattern(for: targetName)
    let sourceReference =
      #"(?:what\s+i\s+(?:just\s+)?said|that|this|my\s+last\s+(?:message|prompt|request|instruction))"#
    let fillers = #"^\s*(?:(?:hey|okay|ok|please|otto|muse|voice)\b[\s,]*)*"#
    let sendPattern =
      fillers
      + #"(?:send|relay|pass)\s+"#
      + sourceReference
      + #"\s+(?:over\s+)?to\s+"#
      + escapedName
      + #"(?:\s+verbatim)?[\s.!?]*$"#
    let tellPattern =
      fillers
      + #"(?:tell|ask|prompt)\s+"#
      + escapedName
      + #"\s+"#
      + sourceReference
      + #"(?:\s+verbatim)?[\s.!?]*$"#
    let tellReferencePattern =
      fillers
      + #"(?:tell|ask)\s+"#
      + sourceReference
      + #"\s+to\s+"#
      + escapedName
      + #"(?:\s+verbatim)?[\s.!?]*$"#

    return [sendPattern, tellPattern, tellReferencePattern].contains { pattern in
      guard
        let expression = try? NSRegularExpression(
          pattern: pattern,
          options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
      else { return false }
      return expression.firstMatch(
        in: transcript,
        range: NSRange(transcript.startIndex..., in: transcript)
      ) != nil
    }
  }

  private static func capture(
    in transcript: String,
    pattern: String,
    group: Int,
    suffixForm: Bool
  ) -> String? {
    guard
      let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      ),
      let match = expression.firstMatch(
        in: transcript,
        range: NSRange(transcript.startIndex..., in: transcript)
      ),
      let range = Range(match.range(at: group), in: transcript)
    else { return nil }

    var prompt = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    if suffixForm {
      prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      while let last = prompt.last, [",", ";", ":", "-", "–", "—"].contains(last) {
        prompt.removeLast()
        prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    guard prompt.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
    return prompt
  }

  private static func looksLikeRelayCommand(_ transcript: String) -> Bool {
    let words = normalizedWords(transcript)
    let actionWords: Set<String> = ["send", "tell", "ask", "prompt", "relay", "pass"]
    let leadingFillers: Set<String> = ["hey", "okay", "ok", "please", "otto", "muse", "voice"]
    let firstAction = words.drop(while: { leadingFillers.contains($0) }).first
    if let firstAction, actionWords.contains(firstAction) { return true }

    for index in words.indices where actionWords.contains(words[index]) {
      let next = words.index(after: index)
      if next < words.endIndex, words[next] == "that" || words[next] == "this" {
        return true
      }
    }
    return false
  }

  private static func mentionsVerbatim(_ transcript: String) -> Bool {
    normalizedWords(transcript).contains("verbatim")
  }

  private static func normalizedWords(_ transcript: String) -> [String] {
    transcript.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }
}

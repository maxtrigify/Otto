import Foundation

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum WorkTitleModelAvailability: Sendable, Equatable {
  case available
  case unavailable(String)
  case unsupportedOS
}

public struct AgentWorkTitleGenerator: Sendable {
  public var useOnDeviceModel: Bool

  public init(useOnDeviceModel: Bool) {
    self.useOnDeviceModel = useOnDeviceModel
  }

  public func title(
    for request: String,
    harnessTitle: String? = nil,
    currentTitle: String? = nil
  ) async -> String {
    if let harnessTitle, let normalized = Self.normalized(harnessTitle) { return normalized }
    let normalizedCurrentTitle = currentTitle.flatMap { Self.normalized($0) }
    if let currentTitle = normalizedCurrentTitle,
      Self.shouldKeepCurrentTitle(for: request, currentTitle: currentTitle)
    {
      return currentTitle
    }
    #if canImport(FoundationModels)
      if useOnDeviceModel, #available(macOS 26.0, *),
        let generated = await AppleWorkTitleProvider.title(
          for: request, currentTitle: normalizedCurrentTitle),
        generated.uppercased() != "KEEP",
        let normalized = Self.normalized(generated)
      {
        return normalized
      }
    #endif
    return Self.deterministicTitle(for: request)
  }

  public static func deterministicTitle(for request: String) -> String {
    let stopWords: Set<String> = [
      "a", "an", "and", "can", "could", "for", "i", "in", "it", "just", "make", "of",
      "on", "please", "the", "this", "to", "want", "we", "would", "you",
    ]
    let words =
      request
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !stopWords.contains($0.lowercased()) }
    let selected = Array((words.isEmpty ? ["Untitled", "work"] : words).prefix(7))
    return selected.enumerated().map { index, word in
      index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
    }.joined(separator: " ")
  }

  public static func normalized(_ candidate: String) -> String? {
    let words =
      candidate
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    guard !words.isEmpty else { return nil }
    return words.prefix(7).joined(separator: " ")
  }

  /// Follow-up prompts usually refine the same piece of work. Keep its glanceable label stable
  /// until a new prompt has enough independent subject matter to describe a different task.
  public static func shouldKeepCurrentTitle(for request: String, currentTitle: String) -> Bool {
    let request = request.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !request.isEmpty else { return true }

    let continuationPrefixes = [
      "also ", "and ", "can you also", "continue", "could you also", "fix that", "make it",
      "ok ", "okay", "one more", "please continue", "thanks", "thank you", "that ", "this ",
      "yes", "yep",
    ]
    if continuationPrefixes.contains(where: request.hasPrefix) { return true }

    let ignored: Set<String> = [
      "a", "an", "and", "can", "could", "do", "for", "from", "i", "in", "is", "it", "of",
      "on", "please", "the", "this", "to", "we", "with", "would", "you",
    ]
    func meaningfulWords(_ value: String) -> Set<String> {
      Set(
        value.split { !$0.isLetter && !$0.isNumber }
          .map { String($0).lowercased() }
          .filter { $0.count > 2 && !ignored.contains($0) }
      )
    }

    let requestWords = meaningfulWords(request)
    guard requestWords.count >= 4 else { return true }
    return !requestWords.isDisjoint(with: meaningfulWords(currentTitle))
  }

  public static var onDeviceAvailability: WorkTitleModelAvailability {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        return AppleWorkTitleProvider.availability
      }
    #endif
    return .unsupportedOS
  }
}

#if canImport(FoundationModels)
  @available(macOS 26.0, *)
  private enum AppleWorkTitleProvider {
    static var availability: WorkTitleModelAvailability {
      switch SystemLanguageModel.default.availability {
      case .available: .available
      case .unavailable(let reason): .unavailable(String(describing: reason))
      }
    }

    static func title(for request: String, currentTitle: String?) async -> String? {
      guard case .available = SystemLanguageModel.default.availability else { return nil }
      let session = LanguageModelSession(
        model: SystemLanguageModel.default,
        instructions: """
          Create a concise 3 to 7 word summary of the user's overall task. If a current summary is
          provided and the new message only continues, clarifies, or adds detail to that same task,
          return exactly KEEP. Return a replacement summary only when the overall task materially
          changes. Describe the requested outcome, not the agent's current activity.
          """
      )
      let prompt = """
        Current summary: \(currentTitle ?? "None")
        New user message: \(String(request.prefix(2_000)))
        """
      return try? await session.respond(to: prompt).content
    }
  }
#endif

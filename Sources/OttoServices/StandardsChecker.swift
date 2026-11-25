import Foundation
import OttoHarness
import OttoModels
import OttoRuntime

#if canImport(AVFoundation)
  import AVFoundation
#endif
#if canImport(ImageIO)
  import ImageIO
#endif

// MARK: Checking work against standards (#127)
//
// When a bot hands a ticket back, a model from a different family judges the work against the
// bot's standards before anyone reviews it. The checker sees the brief, the finished work and
// facts Otto measured itself (which files exist, how long a video runs), never the bot's chat,
// so it can't be talked round. Research behind this: models rarely fix their own work without
// an outside signal (Huang et al. 2023), judges favour their own family's output (Panickssery
// et al. 2024), and an agent's account of its work inflates a judge's pass rate (Khalifa et
// al. 2026).

/// Asks one model one question and returns its reply.
public protocol StandardsJudge: Sendable {
  func ask(system: String, prompt: String) async throws -> String
}

/// The model Otto picked to check a bot's work.
public struct CheckerModel: Sendable, Equatable {
  public var provider: OttoHarnessProvider
  public var modelID: String
  /// Only the bot's own family had a key, so the check is weaker than usual.
  public var sameFamily: Bool

  public init(provider: OttoHarnessProvider, modelID: String, sameFamily: Bool = false) {
    self.provider = provider
    self.modelID = modelID
    self.sameFamily = sameFamily
  }

  public var label: String { "\(provider.displayName) \(modelID)" }
}

/// Calls a hosted model directly with the key saved in Settings → Models.
struct HarnessStandardsJudge: StandardsJudge {
  let model: CheckerModel
  let apiKey: String

  func ask(system: String, prompt: String) async throws -> String {
    let backend: any HarnessModelBackend
    switch model.provider {
    case .openAI: backend = OpenAIResponsesBackend(apiKey: apiKey)
    case .anthropic: backend = AnthropicMessagesBackend(apiKey: apiKey, maximumOutputTokens: 4_000)
    case .xAI:
      backend = OpenAIResponsesBackend(
        apiKey: apiKey, providerID: "xai", providerDisplayName: "xAI",
        endpoint: URL(string: "https://api.x.ai/v1/responses")!)
    case .local:
      throw StandardsCheckError.noChecker
    default:
      guard let vendor = model.provider.compatibleVendor else {
        throw StandardsCheckError.noChecker
      }
      backend = OpenAIChatCompletionsBackend(
        apiKey: apiKey, providerID: vendor.rawValue, providerDisplayName: vendor.displayName,
        endpoint: vendor.chatCompletionsURL)
    }
    let response = try await backend.complete(
      HarnessBackendRequest(
        systemInstructions: system, modelID: model.modelID,
        input: .conversation([HarnessMessage(role: .user, content: prompt)])))
    return response.text
  }
}

public enum StandardsCheckError: Error, LocalizedError, Equatable {
  case noChecker
  case unreadableReply
  public var errorDescription: String? {
    switch self {
    case .noChecker:
      "No model to check with. Add an API key in Settings → Models (Gemini, OpenAI, Anthropic or xAI)."
    case .unreadableReply: "The checker's reply couldn't be read."
    }
  }
}

public enum StandardsChecker {
  /// Checks per hand-back: the first, then two more after the bot fixes what failed.
  public static let maximumChecksPerRound = 3

  /// Hosted checkers in the order Otto prefers them.
  static let preference: [OttoHarnessProvider] = [
    .gemini, .openAI, .anthropic, .xAI, .openRouter, .deepSeek, .mistral, .groq, .moonshot,
  ]

  /// The model family a bot runs on, so the checker can come from a different one.
  public static func family(of profile: AgentProfile) -> OttoHarnessProvider? {
    switch profile.provider {
    case .claudeCode: .anthropic
    case .codex: .openAI
    case .grok: .xAI
    case .kimi: .moonshot
    case .openAI: OttoHarnessModelSelection.resolve(profile.model).provider
    case .cursor, .hermes, .openCode, .pi, .shell: nil
    }
  }

  /// Prefers a family other than the bot's; falls back to the bot's own family only when that
  /// is the one key there is.
  public static func choose(botFamily: OttoHarnessProvider?, keyed: Set<OttoHarnessProvider>)
    -> CheckerModel?
  {
    if let other = preference.first(where: { keyed.contains($0) && $0 != botFamily }) {
      return CheckerModel(
        provider: other, modelID: OttoHarnessModelSelection.defaultModel(for: other))
    }
    if let botFamily, keyed.contains(botFamily) {
      return CheckerModel(
        provider: botFamily, modelID: OttoHarnessModelSelection.defaultModel(for: botFamily),
        sameFamily: true)
    }
    return nil
  }

  // MARK: Facts Otto measures itself

  static let textExtensions: Set<String> = [
    "md", "markdown", "txt", "csv", "tsv", "json", "html", "htm", "xml", "yaml", "yml", "srt",
    "vtt", "swift", "js", "ts", "py", "css",
  ]
  static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac"]
  static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"]

  /// File paths mentioned in handed-back work: absolute, home-relative or workspace-relative
  /// paths, in Markdown links, backticks, quotes or bare. Quoted forms may contain spaces
  /// ("~/Documents/Muse Workspace/post.md"); bare ones end at the first space.
  static func mentionedPaths(in result: String, workspacePath: String) -> [String] {
    let patterns = [
      #"`((?:file://)?(?:~|/)[^`\n]+)`"#,
      #"\]\(<?((?:file://)?(?:~|/)[^)>\n]+)>?\)"#,
      #""((?:~|/)[^"\n]+)""#,
      #"(?:file://)?((?:~|/)[^\s\)\]\"'`<>|]+|[A-Za-z0-9_\-./]+\.[A-Za-z0-9]{2,5})"#,
    ]
    var paths: [String] = []
    // Text already read as a quoted path; a bare match inside it is only a fragment.
    var covered: [NSRange] = []
    for (index, pattern) in patterns.enumerated() {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      let quoted = index < patterns.count - 1
      for match in regex.matches(in: result, range: range) {
        if !quoted, covered.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
          continue
        }
        if quoted { covered.append(match.range) }
        guard let found = Range(match.range(at: 1), in: result) else { continue }
        var path = String(result[found]).trimmingCharacters(
          in: CharacterSet(charactersIn: ".,;: "))
        if path.hasPrefix("file://") { path = String(path.dropFirst(7)) }
        path = path.removingPercentEncoding ?? path
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") {
          // A relative name only counts when it is a real file in the workspace.
          let candidate = (workspacePath as NSString).appendingPathComponent(path)
          guard FileManager.default.fileExists(atPath: candidate) else { continue }
          path = candidate
        }
        guard !paths.contains(path) else { continue }
        paths.append(path)
        if paths.count == 6 { return paths }
      }
    }
    return paths
  }

  /// What Otto can measure about each file the work mentions. The checker trusts these over
  /// anything the bot claims.
  static func facts(forResult result: String, workspacePath: String) async -> [String] {
    var facts: [String] = []
    for path in mentionedPaths(in: result, workspacePath: workspacePath) {
      facts.append(await fact(forPath: path))
    }
    return facts
  }

  static func fact(forPath path: String) async -> String {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      return "\(name): no file at \(path)"
    }
    if isDirectory.boolValue {
      let count = (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
      return "\(name): a folder with \(count) items"
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    let ext = url.pathExtension.lowercased()
    if textExtensions.contains(ext) || ext.isEmpty,
      let data = FileManager.default.contents(atPath: path),
      let text = String(data: data.prefix(8_000), encoding: .utf8)
    {
      let clipped = data.count > 8_000 ? "\n[cut at 8,000 bytes]" : ""
      return "\(name) (\(size) bytes), contents:\n<<<file>>>\n\(text)\(clipped)\n<<<end>>>"
    }
    if mediaExtensions.contains(ext) { return await mediaFact(url: url, size: size) }
    if imageExtensions.contains(ext) { return imageFact(url: url, size: size) }
    return "\(name): \(size) bytes"
  }

  static func mediaFact(url: URL, size: Int) async -> String {
    #if canImport(AVFoundation)
      let asset = AVURLAsset(url: url)
      var parts = ["\(url.lastPathComponent): \(size) bytes"]
      if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
        parts.append(String(format: "runs %.1f seconds", duration.seconds))
      }
      if let video = try? await asset.loadTracks(withMediaType: .video).first,
        let natural = try? await video.load(.naturalSize),
        let transform = try? await video.load(.preferredTransform)
      {
        let shown = natural.applying(transform)
        parts.append("\(Int(abs(shown.width)))×\(Int(abs(shown.height))) video")
      }
      if let audio = try? await asset.loadTracks(withMediaType: .audio), !audio.isEmpty {
        parts.append("has sound")
      }
      return parts.joined(separator: ", ")
    #else
      return "\(url.lastPathComponent): \(size) bytes"
    #endif
  }

  static func imageFact(url: URL, size: Int) -> String {
    #if canImport(ImageIO)
      if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
      {
        return "\(url.lastPathComponent): \(width)×\(height) image, \(size) bytes"
      }
    #endif
    return "\(url.lastPathComponent): image, \(size) bytes"
  }

  // MARK: Asking the checker

  static let checkInstructions = """
    You are Otto's checker. You judge finished work against a list of standards, strictly and \
    fairly. You did not make this work and you can't see how it was made; judge only what is \
    in front of you.
    - Judge each standard on its own.
    - pass: the work clearly meets it.
    - fail: it clearly doesn't. Say exactly what is wrong, so it can be fixed.
    - unsure: you can't tell from what you were given, for example the standard is about \
    something you can't see or hear. Never guess a pass.
    - Facts under MEASURED BY OTTO were measured by Otto itself. Trust them over anything the \
    work claims about itself.
    - evidence is one short sentence: a quote, a measurement or where in the work.
    Reply with JSON only, no other text:
    {"verdicts":[{"index":1,"outcome":"pass","evidence":"..."}]}
    """

  static func checkPrompt(
    brief: String, result: String, facts: [String], standards: [String]
  ) -> String {
    var lines = ["THE REQUEST", brief, "", "THE FINISHED WORK", "<<<work>>>", result, "<<<end>>>"]
    if !facts.isEmpty {
      lines += ["", "MEASURED BY OTTO"] + facts.map { "- \($0)" }
    }
    lines += ["", "STANDARDS"]
    lines += standards.enumerated().map { "\($0.offset + 1). \($0.element)" }
    return lines.joined(separator: "\n")
  }

  /// Reads the checker's verdicts. A standard it skipped counts as unsure, never as a pass.
  static func parseVerdicts(_ reply: String, standards: [(text: String, ticketOnly: Bool)])
    throws -> [StandardsCheck.Verdict]
  {
    struct Reply: Decodable {
      struct Item: Decodable {
        var index: Int
        var outcome: String
        var evidence: String?
      }
      var verdicts: [Item]
    }
    guard let data = jsonObject(in: reply)?.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Reply.self, from: data)
    else { throw StandardsCheckError.unreadableReply }
    return standards.enumerated().map { offset, standard in
      let item = decoded.verdicts.first { $0.index == offset + 1 }
      let outcome = item.flatMap { StandardsCheck.Outcome(rawValue: $0.outcome.lowercased()) }
      return StandardsCheck.Verdict(
        standard: standard.text, outcome: outcome ?? .unsure,
        evidence: String(
          (item?.evidence ?? "The checker didn't answer this one.").prefix(400)),
        ticketOnly: standard.ticketOnly)
    }
  }

  static let proposalInstructions = """
    You turn a reviewer's note into standards for a bot's future work, then test them.
    - Write 1 to 3 standards from the note. Each is one short statement the work must make \
    true, in plain words, not a question: "The post is under 40 words", not "Is the post \
    under 40 words?". General enough to apply to the next piece of work of this kind, and \
    specific enough to check. Prefer something measurable ("at least 2 seconds") over a \
    feeling ("feels polished").
    - Then judge the work below against each standard. catches is true when this work FAILS \
    the standard, meaning the standard would have caught the problem the reviewer found.
    - evidence is one short sentence about this work.
    Reply with JSON only, no other text:
    {"standards":[{"text":"...","catches":true,"evidence":"..."}]}
    """

  static func proposalPrompt(note: String, brief: String, result: String, facts: [String])
    -> String
  {
    var lines = [
      "THE REVIEWER'S NOTE", note, "", "THE REQUEST", brief, "", "THE WORK THAT WAS SENT BACK",
      "<<<work>>>", result, "<<<end>>>",
    ]
    if !facts.isEmpty { lines += ["", "MEASURED BY OTTO"] + facts.map { "- \($0)" } }
    return lines.joined(separator: "\n")
  }

  static func parseProposals(_ reply: String) throws -> [StandardProposal] {
    struct Reply: Decodable {
      struct Item: Decodable {
        var text: String
        var catches: Bool?
        var evidence: String?
      }
      var standards: [Item]
    }
    guard let data = jsonObject(in: reply)?.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Reply.self, from: data)
    else { throw StandardsCheckError.unreadableReply }
    return decoded.standards.prefix(3).compactMap { item in
      let text = StandardsStore.clean(item.text)
      guard !text.isEmpty else { return nil }
      return StandardProposal(
        text: text, catchesIt: item.catches ?? false,
        evidence: String((item.evidence ?? "").prefix(300)))
    }
  }

  /// The outermost JSON object in a reply, ignoring any prose or code fence around it.
  static func jsonObject(in reply: String) -> String? {
    guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"),
      start < end
    else { return nil }
    return String(reply[start...end])
  }
}

import Foundation
import OttoModels
import OttoTools

public struct RelayQualificationCase: Codable, Sendable, Equatable {
  public var id: String
  public var audioFile: String
  public var speakerID: String
  public var targetName: String
  public var expectedTranscript: String
  public var expectedPayload: String

  public init(
    id: String,
    audioFile: String,
    speakerID: String,
    targetName: String,
    expectedTranscript: String,
    expectedPayload: String
  ) {
    self.id = id
    self.audioFile = audioFile
    self.speakerID = speakerID
    self.targetName = targetName
    self.expectedTranscript = expectedTranscript
    self.expectedPayload = expectedPayload
  }
}

public struct RelayQualificationCorpus: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var corpusKind: String
  public var cases: [RelayQualificationCase]

  public init(
    schemaVersion: Int = 1,
    corpusKind: String = "held-out-real-speakers",
    cases: [RelayQualificationCase]
  ) {
    self.schemaVersion = schemaVersion
    self.corpusKind = corpusKind
    self.cases = cases
  }
}

public struct RelayQualificationCaseResult: Codable, Sendable, Equatable {
  public var id: String
  public var transcript: String
  public var actualPayload: String?
  public var wordEdits: Int
  public var transcriptExact: Bool
  public var routeCorrect: Bool
  public var payloadExact: Bool
  public var latencyMilliseconds: Double
}

public struct RelayQualificationReport: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var corpusKind: String
  public var realSpeakerCount: Int
  public var caseCount: Int
  public var wordErrorRatePercent: Double
  public var transcriptExactAccuracy: Double
  public var routeAccuracy: Double
  public var payloadExactAccuracy: Double
  public var latencyMedianMilliseconds: Double
  public var latencyP95Milliseconds: Double
  public var results: [RelayQualificationCaseResult]

  public var passesReleaseGate: Bool {
    schemaVersion == 1
      && corpusKind == "held-out-real-speakers"
      && realSpeakerCount >= 5
      && caseCount >= 100
      && routeAccuracy >= 0.99
      && payloadExactAccuracy >= 0.99
      && latencyP95Milliseconds <= 1_000
  }
}

public enum RelayQualificationError: Error, LocalizedError, Equatable {
  case invalidCorpus(String)

  public var errorDescription: String? {
    switch self {
    case .invalidCorpus(let detail): detail
    }
  }
}

public enum RelayQualificationEvaluator {
  public static func evaluate(
    corpusDirectory: URL,
    configuration: ParakeetRuntimeConfiguration
  ) async throws -> RelayQualificationReport {
    let manifestURL = corpusDirectory.appendingPathComponent("manifest.json")
    let corpus = try JSONDecoder().decode(
      RelayQualificationCorpus.self,
      from: Data(contentsOf: manifestURL)
    )
    guard corpus.schemaVersion == 1,
      corpus.corpusKind == "held-out-real-speakers",
      !corpus.cases.isEmpty,
      corpus.cases.allSatisfy({
        !$0.speakerID.isEmpty && !$0.targetName.isEmpty && !$0.expectedTranscript.isEmpty
          && !$0.expectedPayload.isEmpty
      })
    else {
      throw RelayQualificationError.invalidCorpus(
        "Relay qualification requires labeled held-out real-speaker cases."
      )
    }

    let capture = RelayQualificationCapture()
    let registry = ToolRegistry()
    try await registry.register(RelayQualificationStatusTool())
    try await registry.register(RelayQualificationPromptTool(capture: capture))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(actorID: "relay-qualification", scopes: [], source: .voice)
    )
    let targetIDs = Dictionary(
      uniqueKeysWithValues: Set(corpus.cases.map(\.targetName)).map { ($0, UUID()) })
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(),
          name: "Relay qualification",
          workspace: corpusDirectory.path,
          layout: .freeform
        ),
        nodes: targetIDs.map { name, id in
          VoiceNodeContext(
            id: id,
            name: name,
            kind: .agent,
            provider: .codex,
            status: .idle
          )
        }
      ))

    let recognizer = ParakeetWarmRecognizer(configuration: configuration)
    try await recognizer.prepare()
    defer { Task { await recognizer.shutdown() } }

    var results: [RelayQualificationCaseResult] = []
    var totalReferenceWords = 0
    var totalEdits = 0
    for testCase in corpus.cases {
      let promptCount = await capture.count
      let started = ContinuousClock.now
      let transcription = try await recognizer.transcribe(
        corpusDirectory.appendingPathComponent(testCase.audioFile))
      let outcome = try await router.execute(transcription.text)
      let latency = milliseconds(started.duration(to: ContinuousClock.now))
      let actualPayload = await capture.value(after: promptCount)
      let referenceWords = normalizedWords(testCase.expectedTranscript)
      let actualWords = normalizedWords(transcription.text)
      let edits = editDistance(referenceWords, actualWords)
      totalReferenceWords += referenceWords.count
      totalEdits += edits
      let routeCorrect: Bool
      if case .completed(let toolName, _) = outcome {
        routeCorrect = toolName == "agent.send_prompt" || toolName == "agent.send_input"
      } else {
        routeCorrect = false
      }
      results.append(
        RelayQualificationCaseResult(
          id: testCase.id,
          transcript: transcription.text,
          actualPayload: actualPayload,
          wordEdits: edits,
          transcriptExact: referenceWords == actualWords,
          routeCorrect: routeCorrect,
          payloadExact: actualPayload.map(normalizedWords)
            == normalizedWords(testCase.expectedPayload),
          latencyMilliseconds: latency
        ))
    }
    await recognizer.shutdown()

    let count = Double(results.count)
    let latencies = results.map(\.latencyMilliseconds).sorted()
    return RelayQualificationReport(
      schemaVersion: 1,
      corpusKind: corpus.corpusKind,
      realSpeakerCount: Set(corpus.cases.map(\.speakerID)).count,
      caseCount: results.count,
      wordErrorRatePercent: totalReferenceWords == 0
        ? 0 : Double(totalEdits) / Double(totalReferenceWords) * 100,
      transcriptExactAccuracy: Double(results.count(where: \.transcriptExact)) / count,
      routeAccuracy: Double(results.count(where: \.routeCorrect)) / count,
      payloadExactAccuracy: Double(results.count(where: \.payloadExact)) / count,
      latencyMedianMilliseconds: latencies[latencies.count / 2],
      latencyP95Milliseconds: percentile(latencies, fraction: 0.95),
      results: results
    )
  }

  static func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
    var previous = Array(0...rhs.count)
    for (leftIndex, left) in lhs.enumerated() {
      var current = [leftIndex + 1]
      for (rightIndex, right) in rhs.enumerated() {
        current.append(
          min(
            min(current[rightIndex] + 1, previous[rightIndex + 1] + 1),
            previous[rightIndex] + (left == right ? 0 : 1)
          ))
      }
      previous = current
    }
    return previous[rhs.count]
  }

  static func percentile(_ sortedValues: [Double], fraction: Double) -> Double {
    precondition(!sortedValues.isEmpty)
    let rank = Int(ceil(fraction * Double(sortedValues.count)))
    return sortedValues[max(0, min(sortedValues.count - 1, rank - 1))]
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }
}

private actor RelayQualificationCapture {
  private var values: [String] = []

  var count: Int { values.count }

  func append(_ value: String) { values.append(value) }

  func value(after count: Int) -> String? {
    values.count > count ? values.last : nil
  }
}

private struct RelayQualificationStatusTool: OttoTool {
  struct Input: Codable, Sendable { var agentID: UUID }
  struct Output: Codable, Sendable { var state: String }

  static let definition = ToolDefinition(
    name: "agent.get_status",
    description: "Returns an idle qualification target.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(state: "IDLE")
  }
}

private struct RelayQualificationPromptTool: OttoTool {
  struct Input: Codable, Sendable {
    var agentID: UUID
    var prompt: String
  }
  struct Output: Codable, Sendable { var agentID: UUID }

  static let definition = ToolDefinition(
    name: "agent.send_prompt",
    description: "Captures a qualification relay payload.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let capture: RelayQualificationCapture

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await capture.append(input.prompt)
    return Output(agentID: input.agentID)
  }
}

public actor RelayQualificationCorpusStore {
  public let directory: URL

  public init(directory: URL = RelayQualificationCorpusStore.defaultDirectory) {
    self.directory = directory
  }

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Otto/VoiceQualification/Relay")
  }

  public func append(_ testCase: RelayQualificationCase) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    var corpus: RelayQualificationCorpus
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      corpus = try JSONDecoder().decode(
        RelayQualificationCorpus.self,
        from: Data(contentsOf: manifestURL)
      )
    } else {
      corpus = RelayQualificationCorpus(cases: [])
    }
    corpus.cases.removeAll(where: { $0.id == testCase.id })
    corpus.cases.append(testCase)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(corpus).write(to: manifestURL, options: .atomic)
  }

  public func summary() throws -> (cases: Int, speakers: Int) {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return (0, 0) }
    let corpus = try JSONDecoder().decode(
      RelayQualificationCorpus.self,
      from: Data(contentsOf: manifestURL)
    )
    return (corpus.cases.count, Set(corpus.cases.map(\.speakerID)).count)
  }
}

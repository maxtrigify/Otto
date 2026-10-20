import Foundation
import OttoModels
import OttoSecurity
import OttoTools
import OttoVoice

private struct BenchmarkInput: Codable, Sendable { let value: String }
private struct BenchmarkOutput: Codable, Sendable { let echoed: String }

private actor BenchmarkCapture {
  private var values: [String] = []

  func record(_ value: String) { values.append(value) }
  func snapshot() -> [String] { values }
}

private struct BenchmarkCaptureTool: OttoTool {
  static let definition = ToolDefinition(
    name: "benchmark.capture_exact_value",
    description: "Captures the exact benchmark value requested by the user.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object([
          "type": .string("string"),
          "description": .string(
            "The exact value supplied by the user, preserving case and punctuation."
          ),
        ])
      ]),
      "required": .array([.string("value")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  let capture: BenchmarkCapture

  func call(_ input: BenchmarkInput, context: ToolContext) async throws -> BenchmarkOutput {
    await capture.record(input.value)
    return BenchmarkOutput(echoed: input.value)
  }
}

private actor LocalRelayCapture {
  private var prompts: [String] = []

  func record(_ prompt: String) { prompts.append(prompt) }
  func snapshot() -> [String] { prompts }
}

private struct LocalStatusTool: OttoTool {
  struct Input: Codable, Sendable { let agentID: UUID }
  struct Output: Codable, Sendable { let state: String }

  static let definition = ToolDefinition(
    name: "agent.get_status",
    description: "Returns benchmark agent status.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(state: "IDLE")
  }
}

private struct LocalPromptTool: OttoTool {
  struct Input: Codable, Sendable {
    let agentID: UUID
    let prompt: String
  }
  struct Output: Codable, Sendable { let agentID: UUID }

  static let definition = ToolDefinition(
    name: "agent.send_prompt",
    description: "Captures an exact local relay prompt.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  let capture: LocalRelayCapture

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await capture.record(input.prompt)
    return Output(agentID: input.agentID)
  }
}

private actor LocalActionCapture {
  private var names: [String] = []
  func record(_ name: String) { names.append(name) }
  func snapshot() -> [String] { names }
}

private struct LocalSurfaceTool: OttoTool {
  struct Input: Codable, Sendable { let surface: String }
  struct Output: Codable, Sendable { let ok: Bool }
  static let definition = ToolDefinition(
    name: "surface.set",
    description: "Benchmark open-chat command.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )
  let capture: LocalActionCapture
  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await capture.record(Self.definition.name)
    return Output(ok: true)
  }
}

private struct LocalFocusTool: OttoTool {
  struct Input: Codable, Sendable { let nodeID: UUID }
  struct Output: Codable, Sendable { let nodeID: UUID }
  static let definition = ToolDefinition(
    name: "node.focus",
    description: "Benchmark focus command.",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )
  let capture: LocalActionCapture
  func call(_ input: Input, context: ToolContext) async throws -> Output {
    await capture.record(Self.definition.name)
    return Output(nodeID: input.nodeID)
  }
}

private enum BenchmarkError: Error, CustomStringConvertible {
  case provider(String)
  case timeout(String)

  var description: String {
    switch self {
    case .provider(let message): "xAI realtime provider failed: \(message)"
    case .timeout(let phase): "Timed out waiting for \(phase)"
    }
  }
}

private struct AudioCorpus: Codable, Sendable {
  var version: Int
  var cases: [AudioCorpusCase]
}

private struct AudioCorpusCase: Codable, Sendable {
  var id: String
  var text: String
  var audioFile: String
  var category: String
}

@main
private enum OttoVoiceBenchmark {
  static func main() async throws {
    if let directory = argument(after: "--generate-audio-corpus") {
      try generateAudioCorpus(at: URL(filePath: directory))
      return
    }
    if let directory = argument(after: "--benchmark-apple-audio") {
      try await runAppleAudioBenchmark(at: URL(filePath: directory))
      return
    }
    if let directory = argument(after: "--benchmark-parakeet-audio") {
      try await runParakeetAudioBenchmark(at: URL(filePath: directory))
      return
    }
    if let directory = argument(after: "--benchmark-parakeet-warm-audio") {
      try await runWarmParakeetAudioBenchmark(at: URL(filePath: directory))
      return
    }
    if let directory = argument(after: "--qualify-wakeword-audio") {
      guard let model = argument(after: "--wakeword-model") else {
        throw BenchmarkError.provider("Pass --wakeword-model <hey_otto.onnx|hey_muse.onnx>.")
      }
      let report = try WakeWordQualificationEvaluator.evaluate(
        corpusDirectory: URL(filePath: directory),
        classifierURL: URL(filePath: model)
      )
      let encoder = JSONEncoder.pretty
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let output = try encoder.encode(report)
      if let path = argument(after: "--output") {
        try output.write(to: URL(filePath: path), options: .atomic)
      }
      print(String(decoding: output, as: UTF8.self))
      return
    }
    if let directory = argument(after: "--qualify-relay-audio") {
      let report = try await RelayQualificationEvaluator.evaluate(
        corpusDirectory: URL(filePath: directory),
        configuration: try parakeetConfigurationFromArguments()
      )
      let encoder = JSONEncoder.pretty
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let output = try encoder.encode(report)
      if let path = argument(after: "--output") {
        try output.write(to: URL(filePath: path), options: .atomic)
      }
      print(String(decoding: output, as: UTF8.self))
      return
    }
    if CommandLine.arguments.contains("--local-router") {
      try await runLocalRouterBenchmark()
      return
    }
    if CommandLine.arguments.contains("--local") {
      try await runLocalBenchmark()
      return
    }
    try await runXAIBenchmark()
  }

  private static func generateAudioCorpus(at directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let phrases: [(String, String, String)] = [
      ("sleep-plain", "Otto go to sleep", "sleep"),
      ("sleep-polite", "Okay Otto, you can go to sleep now", "sleep"),
      ("sleep-negative", "Tell Chase to go to sleep", "negative"),
      ("chat", "Open chat", "command"),
      ("focus", "Focus Release Notes", "command"),
      ("prompt-path", "Prompt Chase with Fix build slash API underscore v two now", "relay"),
      ("relay-punctuation", "Tell Chase verbatim don't paraphrase me", "relay"),
      ("dictation", "Review the authentication flow and list the gaps", "dictation"),
      ("short", "Stop", "short"),
    ]
    var cases: [AudioCorpusCase] = []
    for (id, phrase, category) in phrases {
      let filename = "\(id).wav"
      let temporaryAIFF = directory.appending(path: ".\(id).aiff")
      let audioURL = directory.appending(path: filename)
      defer { try? FileManager.default.removeItem(at: temporaryAIFF) }
      let say = Process()
      say.executableURL = URL(filePath: "/usr/bin/say")
      say.arguments = ["-o", temporaryAIFF.path, phrase]
      try say.run()
      say.waitUntilExit()
      guard say.terminationStatus == 0 else {
        throw BenchmarkError.provider("say failed for corpus case \(id)")
      }
      let convert = Process()
      convert.executableURL = URL(filePath: "/usr/bin/afconvert")
      convert.arguments = [
        "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", temporaryAIFF.path, audioURL.path,
      ]
      try convert.run()
      convert.waitUntilExit()
      guard convert.terminationStatus == 0 else {
        throw BenchmarkError.provider("afconvert failed for corpus case \(id)")
      }
      cases.append(
        AudioCorpusCase(id: id, text: phrase, audioFile: filename, category: category))
    }
    let manifest = AudioCorpus(version: 1, cases: cases)
    let data = try JSONEncoder.pretty.encode(manifest)
    try data.write(to: directory.appending(path: "manifest.json"), options: .atomic)
    print("generated=\(cases.count) directory=\(directory.path)")
  }

  private static func runAppleAudioBenchmark(at directory: URL) async throws {
    let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
    let corpus = try JSONDecoder().decode(AudioCorpus.self, from: data)
    var totalReferenceWords = 0
    var totalEdits = 0
    var exact = 0
    var latencies: [Double] = []
    var onDevice = true
    var transcripts: [String] = []

    for testCase in corpus.cases {
      let started = ContinuousClock.now
      let result = try await AppleSpeechFileTranscriber.transcribe(
        directory.appending(path: testCase.audioFile),
        locale: Locale(identifier: "en_GB")
      )
      let latency = milliseconds(started.duration(to: ContinuousClock.now))
      latencies.append(latency)
      transcripts.append(result.text)
      onDevice = onDevice && result.isOnDevice
      let reference = normalizedASRWords(testCase.text)
      let hypothesis = normalizedASRWords(result.text)
      let edits = editDistance(reference, hypothesis)
      totalReferenceWords += reference.count
      totalEdits += edits
      if reference == hypothesis { exact += 1 }
      print(
        "case=\(testCase.id) category=\(testCase.category) latency_ms=\(Int(latency.rounded())) edits=\(edits) expected=\(testCase.text) actual=\(result.text)"
      )
    }

    let wer =
      totalReferenceWords == 0
      ? 0
      : Double(totalEdits) / Double(totalReferenceWords) * 100
    print("provider=apple-speech on_device=\(onDevice)")
    print("exact=\(exact)/\(corpus.cases.count) wer_percent=\(String(format: "%.2f", wer))")
    printLatency("audio_to_final", values: latencies)
    try await printAudioActionBenchmark(corpus: corpus, transcripts: transcripts)
  }

  private static func runParakeetAudioBenchmark(at directory: URL) async throws {
    let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
    let corpus = try JSONDecoder().decode(AudioCorpus.self, from: data)
    let configuration = try parakeetConfigurationFromArguments()
    let runner = ParakeetOfflineRunner(configuration: configuration)
    let audioURLs = corpus.cases.map { directory.appending(path: $0.audioFile) }

    let started = ContinuousClock.now
    let results = try await runner.transcribe(audioURLs)
    let elapsed = milliseconds(started.duration(to: ContinuousClock.now))
    var totalReferenceWords = 0
    var totalEdits = 0
    var exact = 0
    for (testCase, result) in zip(corpus.cases, results) {
      let reference = normalizedASRWords(testCase.text)
      let hypothesis = normalizedASRWords(result.text)
      let edits = editDistance(reference, hypothesis)
      totalReferenceWords += reference.count
      totalEdits += edits
      if reference == hypothesis { exact += 1 }
      print(
        "case=\(testCase.id) category=\(testCase.category) edits=\(edits) expected=\(testCase.text) actual=\(result.text)"
      )
    }
    let wer = totalReferenceWords == 0 ? 0 : Double(totalEdits) / Double(totalReferenceWords) * 100
    print("provider=parakeet-tdt-0.6b-v3-int8 mode=warm-batch threads=\(configuration.threadCount)")
    print("exact=\(exact)/\(corpus.cases.count) wer_percent=\(String(format: "%.2f", wer))")
    print(
      "batch_latency_ms=\(String(format: "%.3f", elapsed)) mean_audio_to_final_ms=\(String(format: "%.3f", elapsed / Double(corpus.cases.count)))"
    )
    try await printAudioActionBenchmark(corpus: corpus, transcripts: results.map(\.text))
  }

  private static func runWarmParakeetAudioBenchmark(at directory: URL) async throws {
    let data = try Data(contentsOf: directory.appending(path: "manifest.json"))
    let corpus = try JSONDecoder().decode(AudioCorpus.self, from: data)
    let configuration = try parakeetConfigurationFromArguments()
    let recognizer = ParakeetWarmRecognizer(configuration: configuration)

    let prepareStarted = ContinuousClock.now
    try await recognizer.prepare()
    let prepareLatency = milliseconds(prepareStarted.duration(to: ContinuousClock.now))
    var results: [ParakeetTranscription] = []
    var latencies: [Double] = []
    for testCase in corpus.cases {
      let started = ContinuousClock.now
      let result = try await recognizer.transcribe(directory.appending(path: testCase.audioFile))
      latencies.append(milliseconds(started.duration(to: ContinuousClock.now)))
      results.append(result)
    }
    await recognizer.shutdown()

    var totalReferenceWords = 0
    var totalEdits = 0
    var exact = 0
    for (testCase, result) in zip(corpus.cases, results) {
      let reference = normalizedASRWords(testCase.text)
      let hypothesis = normalizedASRWords(result.text)
      let edits = editDistance(reference, hypothesis)
      totalReferenceWords += reference.count
      totalEdits += edits
      if reference == hypothesis { exact += 1 }
      print(
        "case=\(testCase.id) category=\(testCase.category) edits=\(edits) expected=\(testCase.text) actual=\(result.text)"
      )
    }
    let wer = totalReferenceWords == 0 ? 0 : Double(totalEdits) / Double(totalReferenceWords) * 100
    print(
      "provider=parakeet-tdt-0.6b-v3-int8 mode=warm-worker threads=\(configuration.threadCount)")
    print("prepare_latency_ms=\(String(format: "%.3f", prepareLatency))")
    print("exact=\(exact)/\(corpus.cases.count) wer_percent=\(String(format: "%.2f", wer))")
    printLatency("audio_to_final", values: latencies)
    try await printAudioActionBenchmark(corpus: corpus, transcripts: results.map(\.text))
  }

  private static func printAudioActionBenchmark(
    corpus: AudioCorpus,
    transcripts: [String]
  ) async throws {
    let actions = LocalActionCapture()
    let prompts = LocalRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(LocalSurfaceTool(capture: actions))
    try await registry.register(LocalFocusTool(capture: actions))
    try await registry.register(LocalStatusTool())
    try await registry.register(LocalPromptTool(capture: prompts))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(actorID: "audio-action-benchmark", scopes: [], source: .voice)
    )
    let nodeID = UUID()
    let agentID = UUID()
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(), name: "Benchmark", workspace: "/benchmark", layout: .freeform),
        nodes: [
          VoiceNodeContext(
            id: nodeID,
            name: "Release Notes",
            kind: .markdown,
            provider: nil,
            status: .idle
          ),
          VoiceNodeContext(
            id: agentID,
            name: "Chase",
            kind: .agent,
            provider: .codex,
            status: .idle
          ),
        ]
      ))

    var correct = 0
    var exactPayloads = 0
    var payloadCases = 0
    for (testCase, transcript) in zip(corpus.cases, transcripts) {
      let promptCount = await prompts.snapshot().count
      let outcome = try await router.execute(transcript)
      let passed = expectedRoute(for: testCase.id, matches: outcome)
      if passed { correct += 1 }
      var payloadDetail = ""
      if let expectedPayload = expectedPromptPayload(for: testCase.id) {
        payloadCases += 1
        let captured = await prompts.snapshot()
        let actualPayload = captured.count > promptCount ? captured.last : nil
        let payloadExact =
          actualPayload.map(normalizedASRWords) == normalizedASRWords(expectedPayload)
        if payloadExact { exactPayloads += 1 }
        payloadDetail =
          " payload_exact=\(payloadExact) expected_payload=\(expectedPayload) actual_payload=\(actualPayload ?? "<none>")"
      }
      print(
        "action_case=\(testCase.id) route_correct=\(passed) outcome=\(outcome)\(payloadDetail)"
      )
    }
    print("audio_to_action_route_accuracy=\(correct)/\(corpus.cases.count)")
    print("action_payload_exact=\(exactPayloads)/\(payloadCases)")
  }

  private static func expectedPromptPayload(for id: String) -> String? {
    switch id {
    case "sleep-negative": "go to sleep"
    case "prompt-path": "Fix build slash API underscore v two now"
    case "relay-punctuation": "don't paraphrase me"
    default: nil
    }
  }

  private static func expectedRoute(
    for id: String,
    matches outcome: LocalVoiceCommandOutcome
  ) -> Bool {
    switch id {
    case "sleep-plain", "sleep-polite":
      return outcome == .sleeping
    case "chat":
      return completedTool(in: outcome) == "surface.set"
    case "focus":
      return completedTool(in: outcome) == "node.focus"
    case "sleep-negative", "prompt-path", "relay-punctuation":
      return completedTool(in: outcome) == "agent.send_prompt"
    case "dictation", "short":
      if case .unrecognized = outcome { return true }
      return false
    default:
      return false
    }
  }

  private static func completedTool(in outcome: LocalVoiceCommandOutcome) -> String? {
    guard case .completed(let toolName, _) = outcome else { return nil }
    return toolName
  }

  private static func parakeetConfigurationFromArguments() throws
    -> ParakeetRuntimeConfiguration
  {
    if let installed = ParakeetRuntimeConfiguration.installed() { return installed }
    guard
      let runtimeRoot = argument(after: "--parakeet-runtime"),
      let modelDirectory = argument(after: "--parakeet-model")
    else {
      throw BenchmarkError.provider(
        "Parakeet is not installed. Pass --parakeet-runtime <runtime root> and --parakeet-model <model directory>."
      )
    }
    let root = URL(filePath: runtimeRoot)
    let threads = Int(argument(after: "--parakeet-threads") ?? "") ?? 4
    let hotwordsFileURL = argument(after: "--parakeet-hotwords").map { URL(filePath: $0) }
    let bpeVocabURL = argument(after: "--parakeet-bpe-vocab").map { URL(filePath: $0) }
    let hotwordsScore = Double(argument(after: "--parakeet-hotwords-score") ?? "") ?? 1.5
    return ParakeetRuntimeConfiguration(
      executableURL: root.appending(path: "bin/sherpa-onnx-offline"),
      libraryDirectory: root.appending(path: "lib"),
      modelDirectory: URL(filePath: modelDirectory),
      threadCount: threads,
      decodingMethod: hotwordsFileURL == nil ? .greedySearch : .modifiedBeamSearch,
      hotwordsFileURL: hotwordsFileURL,
      hotwordsScore: hotwordsScore,
      bpeVocabURL: bpeVocabURL
    )
  }

  private static func runLocalRouterBenchmark() async throws {
    let actions = LocalActionCapture()
    let prompts = LocalRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(LocalSurfaceTool(capture: actions))
    try await registry.register(LocalFocusTool(capture: actions))
    try await registry.register(LocalStatusTool())
    try await registry.register(LocalPromptTool(capture: prompts))
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(actorID: "local-router-benchmark", scopes: [], source: .voice)
    )
    let nodeID = UUID()
    let agentID = UUID()
    await router.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(), name: "Benchmark", workspace: "/benchmark", layout: .freeform),
        nodes: [
          VoiceNodeContext(
            id: nodeID,
            name: "Release Notes",
            kind: .markdown,
            provider: nil,
            status: .idle
          ),
          VoiceNodeContext(
            id: agentID,
            name: "Chase",
            kind: .agent,
            provider: .codex,
            status: .idle
          ),
        ]
      ))

    let cases = [
      "Open chat",
      "Focus Release Notes",
      "Prompt Chase with Fix build/API_v2 now.",
      "Otto, go to sleep please",
      "Tell Chase to go to sleep",
    ]
    var outcomes: [LocalVoiceCommandOutcome] = []
    var latencies: [Double] = []
    for command in cases {
      let started = ContinuousClock.now
      outcomes.append(try await router.execute(command))
      latencies.append(milliseconds(started.duration(to: ContinuousClock.now)))
    }
    let capturedActions = await actions.snapshot()
    let capturedPrompts = await prompts.snapshot()
    let passed =
      capturedActions == ["surface.set", "node.focus"]
      && capturedPrompts == ["Fix build/API_v2 now."]
      && outcomes[3] == .sleeping
      && outcomes[4]
        == .unrecognized(
          "Command not recognized. Try create a terminal, open a URL, switch canvas, open or close a named widget, focus or close an exact node name, or prompt an exact agent name."
        )
    print("provider=local command router")
    print("exact=\(passed ? cases.count : 0)/\(cases.count)")
    printLatency("router", values: latencies)
    for index in cases.indices {
      print("case=\(index + 1) command=\(cases[index]) outcome=\(outcomes[index])")
    }
    guard passed else { throw BenchmarkError.provider("Local command router mismatch") }
  }

  private static func runXAIBenchmark() async throws {
    let cases = [
      (#"Capture the exact quoted value "Alpha-7"."#, "Alpha-7"),
      ("Use the benchmark capture tool with value build/API_v2.", "build/API_v2"),
      ("Record exactly: Chase, wait for me!", "Chase, wait for me!"),
      ("Capture the value 0042, keeping the leading zeroes.", "0042"),
      ("Send this exact value to the capture tool: don't paraphrase me", "don't paraphrase me"),
    ]
    let capture = BenchmarkCapture()
    let registry = ToolRegistry()
    try await registry.register(BenchmarkCaptureTool(capture: capture))
    let provider = XAIRealtimeProvider(
      secrets: makeDefaultSecretStore(),
      configuration: XAIRealtimeConfiguration(
        instructions: """
          This is a command-routing benchmark. For every user request, call
          benchmark.capture_exact_value exactly once with the requested value. Preserve the value
          exactly, including case, punctuation, apostrophes, slashes, hyphens, and leading zeroes.
          Do not speak or call any other tool.
          """,
        reasoningEffort: "none"
      )
    )
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(
        actorID: "xai-command-benchmark",
        scopes: [.canvasRead],
        source: .voice
      )
    )

    await session.connect(provider: provider)
    do {
      try await waitForSession(session, state: .listening, timeout: .seconds(30))
      var latencies: [Double] = []
      for (index, benchmarkCase) in cases.enumerated() {
        let started = ContinuousClock.now
        try await provider.sendText(benchmarkCase.0)
        try await waitForCapture(
          index + 1,
          capture: capture,
          session: session,
          timeout: .seconds(30)
        )
        latencies.append(milliseconds(started.duration(to: ContinuousClock.now)))
      }

      let actual = await capture.snapshot()
      let expected = cases.map(\.1)
      let correct = actual.indices.filter { actual[$0] == expected[$0] }.count
      let sorted = latencies.sorted()
      let median = sorted[sorted.count / 2]
      let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]

      print("provider=xAI model=grok-voice-think-fast-2.0 voice=eve")
      print("exact=\(correct)/\(cases.count)")
      print("latency_ms=\(latencies.map { Int($0.rounded()) })")
      print("median_ms=\(Int(median.rounded())) p95_ms=\(Int(p95.rounded()))")
      for index in cases.indices {
        print("case=\(index + 1) expected=\(expected[index]) actual=\(actual[index])")
      }
    } catch {
      await session.sleep()
      throw error
    }
    await session.sleep()
  }

  private static func runLocalBenchmark() async throws {
    let sleepCases = [
      "Sleep",
      "Otto, go to sleep please",
      "You can go to sleep now",
      "Put yourself to sleep",
      "Okay voice, stop listening thanks",
    ]
    let sleepNegatives = [
      "Tell Chase to go to sleep",
      "Sleep the agent",
      "Can you stop listening to Chase?",
    ]
    var sleepLatencies: [Double] = []
    var correctSleep = 0

    for transcript in sleepCases {
      let provider = ScriptedVoiceProvider()
      let session = VoiceSession(
        registry: ToolRegistry(),
        context: ToolContext(actorID: "local-sleep-benchmark", scopes: [], source: .voice)
      )
      await session.connect(provider: provider)
      try await waitForSession(session, state: .listening, timeout: .seconds(2))
      let started = ContinuousClock.now
      await provider.emit(.finalTranscript(transcript))
      try await waitForSession(session, state: .sleeping, timeout: .seconds(2))
      sleepLatencies.append(milliseconds(started.duration(to: ContinuousClock.now)))
      correctSleep += 1
    }
    for transcript in sleepNegatives {
      let provider = ScriptedVoiceProvider()
      let session = VoiceSession(
        registry: ToolRegistry(),
        context: ToolContext(actorID: "local-sleep-negative", scopes: [], source: .voice)
      )
      await session.connect(provider: provider)
      try await waitForSession(session, state: .listening, timeout: .seconds(2))
      await provider.emit(.finalTranscript(transcript))
      try await Task.sleep(for: .milliseconds(5))
      if await session.snapshot().state != .sleeping { correctSleep += 1 }
      await session.sleep()
    }

    let relayCases = [
      ("Send to Chase verbatim Fix build/API_v2 now.", "Fix build/API_v2 now."),
      ("Please tell Chase verbatim don't paraphrase me", "don't paraphrase me"),
      ("Record 0042, and send that to Chase verbatim", "Record 0042"),
      ("Relay this to Chase verbatim Alpha-7", "Alpha-7"),
      ("Otto, prompt Chase verbatim Use `rg --files` first.", "Use `rg --files` first."),
    ]
    let capture = LocalRelayCapture()
    let registry = ToolRegistry()
    try await registry.register(LocalStatusTool())
    try await registry.register(LocalPromptTool(capture: capture))
    let provider = ScriptedVoiceProvider()
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "local-relay-benchmark", scopes: [], source: .voice)
    )
    let agentID = UUID()
    await session.updateContext(
      VoiceContext(
        activeCanvas: VoiceCanvasContext(
          id: UUID(), name: "Benchmark", workspace: "/benchmark", layout: .freeform),
        nodes: [
          VoiceNodeContext(
            id: agentID,
            name: "Chase",
            kind: .agent,
            provider: .codex,
            status: .working
          )
        ]
      ))
    await session.connect(provider: provider)
    try await waitForSession(session, state: .listening, timeout: .seconds(2))

    var relayLatencies: [Double] = []
    for (index, relayCase) in relayCases.enumerated() {
      let started = ContinuousClock.now
      await provider.emit(.finalTranscript(relayCase.0))
      try await waitForLocalRelay(index + 1, capture: capture, timeout: .seconds(2))
      relayLatencies.append(milliseconds(started.duration(to: ContinuousClock.now)))
    }
    let actual = await capture.snapshot()
    let expected = relayCases.map(\.1)
    let correctRelay = actual.indices.filter { actual[$0] == expected[$0] }.count
    await session.sleep()

    print("provider=local deterministic transcript router")
    print("sleep_accuracy=\(correctSleep)/\(sleepCases.count + sleepNegatives.count)")
    printLatency("sleep", values: sleepLatencies)
    print("relay_exact=\(correctRelay)/\(relayCases.count)")
    printLatency("relay", values: relayLatencies)
    for index in relayCases.indices {
      print("relay_case=\(index + 1) expected=\(expected[index]) actual=\(actual[index])")
    }
    print("scope=post-transcript routing; ASR and VAD excluded")
  }

  private static func waitForSession(
    _ session: VoiceSession,
    state expected: VoiceState,
    timeout: Duration
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let snapshot = await session.snapshot()
      if snapshot.state == expected { return }
      if snapshot.state == .error {
        throw BenchmarkError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw BenchmarkError.timeout(expected.rawValue)
  }

  private static func waitForCapture(
    _ count: Int,
    capture: BenchmarkCapture,
    session: VoiceSession,
    timeout: Duration
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await capture.snapshot().count >= count { return }
      let snapshot = await session.snapshot()
      if snapshot.state == .error {
        throw BenchmarkError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw BenchmarkError.timeout("benchmark case \(count)")
  }

  private static func waitForLocalRelay(
    _ count: Int,
    capture: LocalRelayCapture,
    timeout: Duration
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await capture.snapshot().count >= count { return }
      await Task.yield()
    }
    throw BenchmarkError.timeout("local relay case \(count)")
  }

  private static func printLatency(_ name: String, values: [Double]) {
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    let rendered = values.map { String(format: "%.3f", $0) }
    let renderedMedian = String(format: "%.3f", median)
    let renderedP95 = String(format: "%.3f", p95)
    print("\(name)_latency_ms=\(rendered)")
    print("\(name)_median_ms=\(renderedMedian) \(name)_p95_ms=\(renderedP95)")
  }

  private static func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private static func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard valueIndex < CommandLine.arguments.endIndex else { return nil }
    return CommandLine.arguments[valueIndex]
  }

  private static func normalizedASRWords(_ text: String) -> [String] {
    text.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
    var previous = Array(0...rhs.count)
    for (leftIndex, left) in lhs.enumerated() {
      var current = [leftIndex + 1]
      current.reserveCapacity(rhs.count + 1)
      for (rightIndex, right) in rhs.enumerated() {
        let insertion = current[rightIndex] + 1
        let deletion = previous[rightIndex + 1] + 1
        let substitution = previous[rightIndex] + (left == right ? 0 : 1)
        current.append(min(min(insertion, deletion), substitution))
      }
      previous = current
    }
    return previous[rhs.count]
  }
}

extension JSONEncoder {
  fileprivate static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

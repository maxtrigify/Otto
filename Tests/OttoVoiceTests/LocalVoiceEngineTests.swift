import Foundation
import OttoTools
import Testing

@testable import OttoVoice

/// Signed 16-bit mono PCM at 24 kHz: a tone at the given loudness, or silence at zero.
private func pcm(seconds: Double, level: Double) -> Data {
  let frames = Int(seconds * 24_000)
  var samples = [Int16](repeating: 0, count: frames)
  for frame in 0..<frames {
    let wave = sin(Double(frame) * 2 * .pi * 220 / 24_000)
    samples[frame] = Int16(wave * level * 1.414 * Double(Int16.max))
  }
  return samples.withUnsafeBytes { Data($0) }
}

/// Feeds audio in 20 ms buffers, the way the microphone delivers it.
private func feed(_ endpointer: inout LocalVoiceEndpointer, _ audio: Data)
  -> [LocalVoiceEndpointer.Event]
{
  var events: [LocalVoiceEndpointer.Event] = []
  let step = 960
  var offset = 0
  while offset < audio.count {
    let end = min(offset + step, audio.count)
    events += endpointer.process(audio.subdata(in: offset..<end))
    offset = end
  }
  return events
}

@Suite("Local voice endpointing")
struct LocalVoiceEndpointerTests {
  @Test("A spoken request in a quiet room starts and ends once, with its lead-in kept")
  func quietRoom() {
    var endpointer = LocalVoiceEndpointer()
    var events = feed(&endpointer, pcm(seconds: 1, level: 0.001))
    #expect(events.isEmpty)
    events = feed(&endpointer, pcm(seconds: 1.5, level: 0.1))
    #expect(events == [.speechStarted])
    events = feed(&endpointer, pcm(seconds: 1.2, level: 0.001))
    guard case .speechEnded(let audio, let deliberate)? = events.first, events.count == 1 else {
      Issue.record("Expected one ended event, got \(events)")
      return
    }
    let seconds = Double(audio.count / 2) / 24_000
    // The request, the pause that ended it, and a little audio from before it began.
    #expect(seconds > 2.2 && seconds < 2.9)
    #expect(endpointer.isLongEnough(audio))
    // An open microphone is never perfectly silent, so this was not a held-key request.
    #expect(!deliberate)
  }

  @Test("Sound that follows true silence was let through with the Talk key held")
  func heldKey() {
    var endpointer = LocalVoiceEndpointer()
    _ = feed(&endpointer, pcm(seconds: 0.5, level: 0))
    var events = feed(&endpointer, pcm(seconds: 1, level: 0.1))
    #expect(events == [.speechStarted])
    events = feed(&endpointer, pcm(seconds: 0.5, level: 0))
    guard case .speechEnded(_, let deliberate)? = events.first else {
      Issue.record("The request never ended")
      return
    }
    #expect(deliberate)
  }

  @Test("Background sound that switches on is let go, and speech over it still starts and ends")
  func steadyBackground() {
    var endpointer = LocalVoiceEndpointer()
    _ = feed(&endpointer, pcm(seconds: 1, level: 0.001))
    // A television comes on at constant volume. It may open one capture, which must close.
    let onset = feed(&endpointer, pcm(seconds: 6, level: 0.03))
    #expect(onset.filter { $0 == .speechStarted }.count <= 1)
    #expect(!endpointer.isCapturing)
    // Someone speaks over it, then stops; the television carries on.
    var events = feed(&endpointer, pcm(seconds: 1.5, level: 0.2))
    #expect(events == [.speechStarted])
    events = feed(&endpointer, pcm(seconds: 1.5, level: 0.03))
    #expect(events.count == 1)
    if case .speechEnded? = events.first {} else { Issue.record("The request never ended") }
  }

  @Test("A request that never goes quiet is cut off rather than recorded for ever")
  func runawayCapture() {
    var endpointer = LocalVoiceEndpointer(
      configuration: .init(maximumDuration: 2))
    _ = feed(&endpointer, pcm(seconds: 0.5, level: 0.001))
    let events = feed(&endpointer, pcm(seconds: 4, level: 0.2))
    #expect(events.first == .speechStarted)
    #expect(events.contains { if case .speechEnded = $0 { true } else { false } })
  }

  @Test("A click is too short to be a request")
  func click() {
    var endpointer = LocalVoiceEndpointer()
    _ = feed(&endpointer, pcm(seconds: 0.5, level: 0.001))
    let events = feed(&endpointer, pcm(seconds: 0.04, level: 0.3))
    #expect(events.isEmpty)
  }
}

@Suite("Spoken sentence splitting")
struct SpokenSentenceSplitterTests {
  @Test("Sentences are released as soon as they are complete")
  func streaming() {
    var splitter = SpokenSentenceSplitter()
    #expect(splitter.append("Good afternoon, Max. The bui").isEmpty == false)
    var rest = splitter.append("ld finished and every test passed. Shall I")
    #expect(rest == ["The build finished and every test passed."])
    rest = splitter.append(" publish it?")
    #expect(rest.isEmpty)
    #expect(splitter.flush() == ["Shall I publish it?"])
  }

  @Test("A very short sentence stays with the one after it")
  func shortSentence() {
    var splitter = SpokenSentenceSplitter()
    let pieces = splitter.append("Yes. The session is open and ready for you. ")
    #expect(pieces == ["Yes. The session is open and ready for you."])
  }

  @Test("A long sentence is cut at its commas so each piece is quick to make")
  func longSentence() {
    var splitter = SpokenSentenceSplitter()
    let pieces = splitter.append(
      "Coda has finished the release build and every test has passed, so it is ready whenever you wish to take the next step. "
    )
    #expect(pieces.count == 2)
    #expect(pieces[0].hasSuffix("passed,"))
  }

  @Test("Markdown is not read aloud")
  func markdown() {
    var splitter = SpokenSentenceSplitter()
    _ = splitter.append("**Done** with `main`")
    #expect(splitter.flush() == ["Done with main"])
  }
}

@Suite("Local tool protocol")
struct LocalToolProtocolTests {
  private static let tool = ToolDefinition(
    name: "session.open",
    description: "Opens a session.",
    inputSchema: .objectSchema(properties: ["name": .stringSchema()], required: ["name"]),
    outputSchema: .object([:]),
    requiredScopes: [],
    riskLevel: .read
  )

  private func request(_ json: String) -> Data { Data(json.utf8) }

  private func object(_ reply: LocalToolProtocol.Reply) throws -> [String: JSONValue] {
    try #require(try JSONDecoder().decode(JSONValue.self, from: reply.body).objectValue)
  }

  @Test("Tools are listed under names the protocol allows")
  func listing() async throws {
    let service = LocalToolProtocol(tools: [Self.tool]) { _, _ in ("", false) }
    let reply = await service.respond(
      to: request(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
    let tools = try #require(try object(reply)["result"]?.objectValue?["tools"]?.arrayValue)
    #expect(tools.first?.objectValue?["name"] == .string("session_open"))
  }

  @Test("A call reaches Otto under the tool's real name and returns its result")
  func calling() async throws {
    let service = LocalToolProtocol(tools: [Self.tool]) { name, arguments in
      ("\(name):\(arguments.objectValue?["name"]?.stringValue ?? "")", false)
    }
    let reply = await service.respond(
      to: request(
        #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"session_open","arguments":{"name":"Coda"}}}"#
      ))
    let result = try #require(try object(reply)["result"]?.objectValue)
    #expect(result["isError"] == .bool(false))
    #expect(
      result["content"]?.arrayValue?.first?.objectValue?["text"] == .string("session.open:Coda"))
  }

  @Test("Notifications are acknowledged without an answer, and unknown requests are refused")
  func edges() async throws {
    let service = LocalToolProtocol(tools: [Self.tool]) { _, _ in ("", false) }
    let notification = await service.respond(
      to: request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    #expect(notification.status == 202)
    #expect(notification.body.isEmpty)
    let unknown = await service.respond(
      to: request(#"{"jsonrpc":"2.0","id":2,"method":"server/discover"}"#))
    #expect(try object(unknown)["error"] != nil)
    let missing = await service.respond(
      to: request(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nope"}}"#))
    #expect(try object(missing)["error"] != nil)
  }

  @Test("A request is read only once all of its bytes have arrived")
  func httpFraming() {
    let whole =
      "POST /mcp HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Length: 4\r\n\r\nping"
    #expect(HTTPRequest(Data(whole.dropLast(2).utf8)) == nil)
    let request = HTTPRequest(Data(whole.utf8))
    #expect(request?.method == "POST")
    #expect(request?.headers["authorization"] == "Bearer abc")
    #expect(request?.body == Data("ping".utf8))
  }
}

@Suite("Local voice assistant stream")
struct LocalVoiceBrainTests {
  @Test("Reply text, pauses and endings are read from the assistant's stream")
  func parsing() {
    #expect(
      ClaudeCodeVoiceBrain.parse(
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}}"#
      ) == .text("Hello"))
    #expect(
      ClaudeCodeVoiceBrain.parse(
        #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"#) == .pause)
    #expect(ClaudeCodeVoiceBrain.parse(#"{"type":"result","is_error":false}"#) == .finished)
    #expect(
      ClaudeCodeVoiceBrain.parse(#"{"type":"result","is_error":true,"result":"Limit reached"}"#)
        == .failed("Limit reached"))
    #expect(ClaudeCodeVoiceBrain.parse(#"{"type":"system","subtype":"init"}"#) == nil)
    #expect(ClaudeCodeVoiceBrain.parse("not json") == nil)
  }

  @Test("The assistant starts from the person's own sign-in, with no tools of its own")
  func launch() {
    let environment = ClaudeCodeVoiceBrain.environment([
      "PATH": "/usr/bin", "CLAUDECODE": "1", "ANTHROPIC_API_KEY": "x", "OTTO_CONTROL_TOKEN": "y",
    ])
    #expect(environment == ["PATH": "/usr/bin"])
    let arguments = ClaudeCodeVoiceBrain.arguments(
      configuration: .init(
        executable: URL(fileURLWithPath: "/bin/echo"), instructions: "Be brief."),
      settings: URL(fileURLWithPath: "/tmp/tools.json"))
    #expect(arguments.contains("--strict-mcp-config"))
    #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--tools" && $1 == "" })
    #expect(
      zip(arguments, arguments.dropFirst()).contains { $0 == "--setting-sources" && $1 == "" })
  }
}

// MARK: - The whole engine, with the three parts replaced by stand-ins

private actor ScriptedRecognizer: LocalSpeechRecognizing {
  private let transcript: String
  init(_ transcript: String) { self.transcript = transcript }
  func prepare() async throws {}
  func text(samples: [Float], sampleRate: Int) async throws -> String { transcript }
  func shutdown() async {}
}

private actor ScriptedBrain: LocalVoiceThinking {
  nonisolated let events: AsyncStream<LocalVoiceBrainEvent>
  private let continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation
  private var call: LocalToolProtocol.Call?
  private(set) var asked: [String] = []
  private(set) var interrupts = 0
  private(set) var toolReplies: [String] = []

  init() {
    var continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func start(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) async throws {
    self.call = call
  }

  /// Says a few words, uses a tool, then reports what it returned.
  func ask(_ text: String) async {
    asked.append(text)
    continuation.yield(.text("One moment."))
    continuation.yield(.pause)
    let outcome = await call?("session.open", .object(["name": .string("Coda")]))
    toolReplies.append(outcome?.text ?? "")
    continuation.yield(.text("Coda is open. "))
    continuation.yield(.finished)
  }

  func interrupt() async { interrupts += 1 }
  func stop() async { continuation.finish() }
}

private struct ScriptedSynthesizer: LocalSpeechSynthesizing {
  func speech(for text: String) async throws -> Data { Data(repeating: 1, count: 4_800) }
}

@Suite("Voiceprint")
struct VoiceprintTests {
  private func voice(_ seed: Float) -> [Float] { [seed, 1 - seed, 0.2] }

  @Test("Other voices are only turned away once three sentences have been learned")
  func readiness() {
    var voiceprint = Voiceprint()
    voiceprint.learn(voice(0.9))
    voiceprint.learn(voice(0.85))
    #expect(!voiceprint.isReady)
    #expect(voiceprint.match(voice(0.9)) == nil)
    voiceprint.learn(voice(0.95))
    #expect(voiceprint.isReady)
    let own = voiceprint.match(voice(0.9))
    let stranger = voiceprint.match(voice(0.05))
    #expect((own ?? 0) > 0.99)
    #expect((stranger ?? 1) < 0.5)
  }

  @Test("The first sentences stay as an anchor however many more are learned")
  func anchor() {
    var voiceprint = Voiceprint()
    for index in 0..<20 { voiceprint.learn(voice(Float(index) / 20)) }
    #expect(voiceprint.samples.count == Voiceprint.capacity)
    #expect(Array(voiceprint.samples.prefix(3)) == [voice(0), voice(0.05), voice(0.1)])
    #expect(voiceprint.samples.last == voice(19.0 / 20))
  }

  @Test("A recording of the person replaces whatever was learned before, and is ready at once")
  func enrolment() {
    var voiceprint = Voiceprint()
    voiceprint.learn(voice(0.1))
    voiceprint.replace(with: [voice(0.8), voice(0.85), voice(0.9)])
    #expect(voiceprint.isReady)
    #expect(voiceprint.samples.count == 3)
    #expect((voiceprint.match(voice(0.85)) ?? 0) > 0.99)
  }

  @Test("A voiceprint survives being saved and can be forgotten")
  func storage() throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "voiceprint-\(UUID().uuidString)/voiceprint.json")
    let store = VoiceprintStore(url: url)
    var voiceprint = Voiceprint()
    voiceprint.learn(voice(0.4))
    store.save(voiceprint)
    #expect(store.load() == voiceprint)
    store.remove()
    #expect(store.load() == Voiceprint())
  }
}

/// A filter whose verdicts are fixed, to test what the engine does with them.
private actor ScriptedFilter: LocalVoiceFiltering {
  private let score: Float?
  private(set) var learned = 0
  init(score: Float?) { self.score = score }
  func speech(in samples: [Float]) async -> [Float]? { samples }
  func match(_ speech: [Float]) async -> Float? { score }
  func learn(_ speech: [Float]) async { learned += 1 }
  func enroll(_ samples: [Float]) async -> Bool { true }
  func status() async -> VoiceprintStatus { .ready }
  func forget() async {}
}

@Suite("Local voice provider")
struct LocalVoiceProviderTests {
  /// Speaks one request into the provider and reports what it made of it.
  private func hear(
    filter: ScriptedFilter, keyHeld: Bool
  ) async throws -> (transcripts: [String], asked: [String]) {
    let brain = ScriptedBrain()
    let provider = LocalVoiceProvider(
      recognizer: ScriptedRecognizer("Open the Coda session."),
      brain: brain,
      synthesizer: ScriptedSynthesizer(),
      filter: filter
    )
    let heard = Task { () -> [String] in
      for await event in provider.events {
        if case .toolCall(let id, _, _) = event {
          await provider.sendToolResult(
            VoiceToolResult(callID: id, result: .object([:]), isError: false))
        }
        if case .finalTranscript(let text) = event { return [text] }
      }
      return []
    }
    try await provider.connect(tools: [])
    let quiet = keyHeld ? 0 : 0.001
    for chunk in [
      pcm(seconds: 0.5, level: quiet), pcm(seconds: 1, level: 0.1), pcm(seconds: 1.2, level: quiet),
    ] {
      var offset = 0
      while offset < chunk.count {
        let end = min(offset + 960, chunk.count)
        try await provider.sendAudio(chunk.subdata(in: offset..<end))
        offset = end
      }
    }
    let transcripts = await heard.value
    try await Task.sleep(for: .milliseconds(100))
    let asked = await brain.asked
    await provider.disconnect()
    return (transcripts, asked)
  }

  @Test("A voice that is not the person's is ignored, and nothing is learned from it")
  func strangerIgnored() async throws {
    let filter = ScriptedFilter(score: 0.1)
    let result = try await hear(filter: filter, keyHeld: false)
    #expect(result.transcripts == [""])
    #expect(result.asked.isEmpty)
    #expect(await filter.learned == 0)
  }

  @Test("The person's own voice is answered, and a strong match teaches Otto more of it")
  func ownVoiceAnswered() async throws {
    let filter = ScriptedFilter(score: 0.8)
    let result = try await hear(filter: filter, keyHeld: false)
    #expect(result.transcripts == ["Open the Coda session."])
    #expect(result.asked == ["Open the Coda session."])
    #expect(await filter.learned == 1)
  }

  @Test("With the Talk key held a request is always heard, and Otto learns from it")
  func heldKeyAlwaysHeard() async throws {
    let filter = ScriptedFilter(score: 0.1)
    let result = try await hear(filter: filter, keyHeld: true)
    #expect(result.transcripts == ["Open the Coda session."])
    #expect(await filter.learned == 1)
  }

  @Test("A lone word is a request only when it answers a question Otto asked")
  func shortTranscripts() {
    #expect(!LocalVoiceProvider.isRequest("Hm.", answeringQuestion: false))
    #expect(!LocalVoiceProvider.isRequest("", answeringQuestion: true))
    #expect(LocalVoiceProvider.isRequest("Yes.", answeringQuestion: true))
    #expect(LocalVoiceProvider.isRequest("Open Coda", answeringQuestion: false))
    // Once Otto knows it is the person speaking, one word is a real thing to say.
    #expect(LocalVoiceProvider.isRequest("Hello.", answeringQuestion: false, fromThePerson: true))
    #expect(!LocalVoiceProvider.isRequest("Hmm.", answeringQuestion: false, fromThePerson: true))
  }

  @Test("A spoken request is heard, acted on through Otto's tools, and answered aloud")
  func wholeTurn() async throws {
    let brain = ScriptedBrain()
    let provider = LocalVoiceProvider(
      recognizer: ScriptedRecognizer("Open the Coda session."),
      brain: brain,
      synthesizer: ScriptedSynthesizer()
    )
    let collector = Task { () -> [VoiceProviderEvent] in
      var seen: [VoiceProviderEvent] = []
      for await event in provider.events {
        seen.append(event)
        // Stand in for the voice session: run the tool and hand back its result.
        if case .toolCall(let id, let name, _) = event {
          #expect(name == "session.open")
          await provider.sendToolResult(
            VoiceToolResult(callID: id, result: .object(["opened": .bool(true)]), isError: false))
        }
        if event == .speechFinished { break }
      }
      return seen
    }
    let audio = Task { () -> Int in
      var bytes = 0
      for await data in provider.audioOutput {
        bytes += data.count
        if bytes >= 9_600 { break }
      }
      return bytes
    }

    try await provider.connect(tools: [])
    for chunk in [
      pcm(seconds: 0.5, level: 0.001), pcm(seconds: 1, level: 0.1), pcm(seconds: 1.2, level: 0.001),
    ] {
      var offset = 0
      while offset < chunk.count {
        let end = min(offset + 960, chunk.count)
        try await provider.sendAudio(chunk.subdata(in: offset..<end))
        offset = end
      }
    }

    let events = await collector.value
    #expect(events.first == .connected)
    #expect(events.contains(.speechStarted))
    #expect(events.contains(.finalTranscript("Open the Coda session.")))
    #expect(events.contains(.thinking))
    #expect(events.contains(.speaking("One moment. ")))
    #expect(events.contains(.speaking("Coda is open. ")))
    let spokenFirst = try #require(events.firstIndex(of: .speaking("One moment. ")))
    let spokenLast = try #require(events.firstIndex(of: .speaking("Coda is open. ")))
    #expect(spokenFirst < spokenLast)
    #expect(await audio.value >= 9_600)
    #expect(await brain.asked == ["Open the Coda session."])
    #expect(await brain.toolReplies == [#"{"opened":true}"#])
    await provider.disconnect()
  }

  @Test("\"Go to sleep\" is left to the session and never reaches the assistant")
  func sleepCommand() async throws {
    let brain = ScriptedBrain()
    let provider = LocalVoiceProvider(
      recognizer: ScriptedRecognizer("go to sleep"),
      brain: brain,
      synthesizer: ScriptedSynthesizer()
    )
    let heard = Task { () -> Bool in
      for await event in provider.events {
        if case .finalTranscript = event { return true }
      }
      return false
    }
    try await provider.connect(tools: [])
    for chunk in [
      pcm(seconds: 0.5, level: 0.001), pcm(seconds: 1, level: 0.1), pcm(seconds: 1.2, level: 0.001),
    ] {
      var offset = 0
      while offset < chunk.count {
        let end = min(offset + 960, chunk.count)
        try await provider.sendAudio(chunk.subdata(in: offset..<end))
        offset = end
      }
    }
    #expect(await heard.value)
    try await Task.sleep(for: .milliseconds(100))
    #expect(await brain.asked.isEmpty)
    await provider.disconnect()
  }
}

@Test func speechLoudnessIsLaidOutAlongTheTimeItPlays() {
  let levels = VoiceActivityLevels()
  let start = Date(timeIntervalSinceReferenceDate: 1_000)
  // One second of silence then one second of a loud tone, at 24 kHz.
  var samples = [Int16](repeating: 0, count: 24_000)
  samples += (0..<24_000).map { $0.isMultiple(of: 2) ? Int16(16_000) : Int16(-16_000) }
  let data = samples.withUnsafeBytes { Data($0) }
  levels.queueOutput(pcm16: data, sampleRate: 24_000, at: start)

  #expect(levels.outputLevel(at: start.addingTimeInterval(0.5)) == 0)
  #expect(levels.outputLevel(at: start.addingTimeInterval(1.5)) > 0.4)
  #expect(levels.outputLevel(at: start.addingTimeInterval(2.5)) == 0)

  // A second sentence queued while the first is playing is heard after it, not over it.
  levels.queueOutput(pcm16: data, sampleRate: 24_000, at: start.addingTimeInterval(1))
  #expect(levels.outputLevel(at: start.addingTimeInterval(2.5)) == 0)
  #expect(levels.outputLevel(at: start.addingTimeInterval(3.5)) > 0.4)

  levels.clearOutput()
  #expect(levels.outputLevel(at: start.addingTimeInterval(3.5)) == 0)
}

@Test func microphoneLoudnessFadesWhenTheMicrophoneStops() {
  let levels = VoiceActivityLevels()
  let start = Date(timeIntervalSinceReferenceDate: 1_000)
  levels.noteInput(0.2, at: start)
  #expect(levels.inputLevel(at: start.addingTimeInterval(0.1)) == 0.2)
  #expect(levels.inputLevel(at: start.addingTimeInterval(1)) == 0)
}

@Test func onlyNamesWorthListeningForAreTaught() {
  let names = SpokenName.teachable([
    SpokenName("Codex", soundsLike: ["Codecs"], isOttosOwn: true),
    SpokenName("codex", isOttosOwn: true),
    SpokenName("Pi", isOttosOwn: true),
    SpokenName("  Social Guru "),
    SpokenName("2026"),
    SpokenName(String(repeating: "long ", count: 12)),
  ])
  #expect(names.map(\.text) == ["Codex", "Social Guru"])
  #expect(names.first?.soundsLike == ["Codecs"])
  #expect(
    SpokenName.teachable((0..<300).map { SpokenName("Session number \($0)") }).count == 120)
}

@Test func aShortOrdinarySoundingNameIsNotListenedFor() {
  // "Ling" was written in place of "using" and "Sol" is one syllable of many words.
  let names = SpokenName.teachable([
    SpokenName("Ling"), SpokenName("Sol"), SpokenName("Coder"), SpokenName("Woody"),
    SpokenName("Ling 3.2 Flash"), SpokenName("Homepage"), SpokenName("Grok", isOttosOwn: true),
  ])
  #expect(names.map(\.text) == ["Ling 3.2 Flash", "Homepage", "Grok"])
}

@Test func theWorkspacePictureCarriesEachHarnesssModels() throws {
  var context = VoiceContext(
    activeCanvas: VoiceCanvasContext(
      id: UUID(), name: "Main", workspace: "/tmp", layout: .freeform),
    nodes: [])
  #expect(context.models == nil)
  context.models = [
    VoiceHarnessModels(harness: "Codex", models: [VoiceModelName(id: "sol-6.2", name: "Sol 6.2")])
  ]
  let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
  #expect(json.contains("sol-6.2"))
  // A picture saved before models were added must still read.
  let old = try JSONEncoder().encode(
    VoiceContext(
      activeCanvas: VoiceCanvasContext(
        id: UUID(), name: "Main", workspace: "/tmp", layout: .freeform),
      nodes: []))
  #expect(try JSONDecoder().decode(VoiceContext.self, from: old).models == nil)
}

#if canImport(FluidAudio)
  @Test func aBritishVoiceIsGivenBritishPronunciations() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
      at: folder.appending(path: "kokoro"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(KokoroSpeechSynthesizer.britishPronunciations(in: folder) == nil)

    let lexicon =
      #"{"lower":{"water":["w","ˈ","ɔ","ː","t","ə"]},"caseSensitive":{"NATO":["n","ˈ","A","t","Q"]}}"#
    try Data(lexicon.utf8).write(to: folder.appending(path: "kokoro/gb_lexicon_cache.json"))
    let words = try #require(KokoroSpeechSynthesizer.britishPronunciations(in: folder))
    #expect(words["water"] == "wˈɔːtə")
    #expect(words["NATO"] == "nˈAtQ")
  }
#endif

@Test func whatOttoSaysAtOnceFitsTheShapeOfTheRequest() {
  let first: (Int) -> Int = { _ in 0 }
  #expect(
    VoiceAcknowledgement.line(
      for: "What did Coder find in the build?", answeringQuestion: false, pick: first) == "Hmm.")
  #expect(
    VoiceAcknowledgement.line(
      for: "Open a whiteboard for me", answeringQuestion: false, pick: first) == "Right.")
  #expect(
    VoiceAcknowledgement.line(
      for: "Otto, start a Codex session", answeringQuestion: false, pick: first) == "Right.")
  #expect(
    VoiceAcknowledgement.line(
      for: "I think the homepage looks a bit dull", answeringQuestion: false, pick: first)
      == "Mm.")
}

@Test func aPoliteRequestIsAcknowledgedAsAnInstruction() {
  let first: (Int) -> Int = { _ in 0 }
  #expect(
    VoiceAcknowledgement.line(
      for: "Can you open up a new Codex session for me", answeringQuestion: false, pick: first)
      == "Right.")
  #expect(
    VoiceAcknowledgement.line(
      for: "Can you just ask it to summarise Otto?", answeringQuestion: false, pick: first)
      == "Right.")
  #expect(
    VoiceAcknowledgement.line(for: "Use Sol", answeringQuestion: false, pick: first) == "Right.")
  // A real question that only starts the same way still gets a thinking sound.
  #expect(
    VoiceAcknowledgement.line(
      for: "Can it handle spreadsheets?", answeringQuestion: false, pick: first) == "Hmm.")
}

@Test func theSameAcknowledgementIsNotSaidTwiceRunning() {
  for _ in 0..<20 {
    #expect(
      VoiceAcknowledgement.line(
        for: "Open a whiteboard for me", answeringQuestion: false, avoiding: "Right.")
        != "Right.")
  }
}

@Test func pleasantriesAndShortAnswersGetNoAcknowledgement() {
  #expect(VoiceAcknowledgement.line(for: "Thanks very much Otto", answeringQuestion: false) == nil)
  #expect(VoiceAcknowledgement.line(for: "Hello", answeringQuestion: false) == nil)
  #expect(VoiceAcknowledgement.line(for: "The second one please", answeringQuestion: true) == nil)
}

@Test func aSentenceThatTrailsOffIsNotYetARequest() {
  #expect(SpokenRequest.trailsOff("Can you open up a new Codex session using"))
  #expect(SpokenRequest.trailsOff("Open the whiteboard and"))
  #expect(SpokenRequest.trailsOff("I want to talk about the."))
  #expect(!SpokenRequest.trailsOff("Can you open up a new Codex session using Sol 6.2"))
  #expect(!SpokenRequest.trailsOff("What is it for?"))
  #expect(!SpokenRequest.trailsOff("The"))
}

private func codexModels() -> VoiceContext {
  var context = VoiceContext(
    activeCanvas: VoiceCanvasContext(
      id: UUID(), name: "Main", workspace: "/tmp", layout: .freeform),
    nodes: [])
  context.models = [
    VoiceHarnessModels(
      harness: "Codex",
      models: [
        VoiceModelName(id: "gpt-6.1-sol", name: "GPT-6.1-Sol"),
        VoiceModelName(id: "gpt-6-sol", name: "GPT-6-Sol"),
        VoiceModelName(id: "gpt-6.1-terra", name: "GPT-6.1 Terra"),
      ])
  ]
  return context
}

@Test func voiceCannotStartASessionOnAModelThatDoesNotExist() {
  let invented = JSONValue.object(["provider": .string("Codex"), "model": .string("models/6.2")])
  #expect(throws: ToolRegistryError.self) {
    try VoiceModelCheck.checked(spawnArguments: invented, context: codexModels())
  }
  // "Sol" alone could be either Sol model, so it is not guessed at.
  let vague = JSONValue.object(["provider": .string("Codex"), "model": .string("Sol")])
  #expect(throws: ToolRegistryError.self) {
    try VoiceModelCheck.checked(spawnArguments: vague, context: codexModels())
  }
}

@Test func aSpokenModelNameBecomesTheRealModel() throws {
  func model(_ said: String) throws -> String? {
    let arguments = JSONValue.object(["provider": .string("Codex"), "model": .string(said)])
    guard
      case .object(let output) = try VoiceModelCheck.checked(
        spawnArguments: arguments, context: codexModels())
    else { return nil }
    return output["model"]?.stringValue
  }
  #expect(try model("gpt-6.1-sol") == "gpt-6.1-sol")
  #expect(try model("GPT 6.1 Sol") == "gpt-6.1-sol")
  #expect(try model("Sol 6.1") == "gpt-6.1-sol")
  #expect(try model("Terra") == "gpt-6.1-terra")
}

@Test func aSessionWithNoModelNamedOrAnUnknownHarnessIsLeftAlone() throws {
  let plain = JSONValue.object(["provider": .string("Codex")])
  #expect(try VoiceModelCheck.checked(spawnArguments: plain, context: codexModels()) == plain)
  let other = JSONValue.object(["provider": .string("Cursor"), "model": .string("anything")])
  #expect(try VoiceModelCheck.checked(spawnArguments: other, context: codexModels()) == other)
}

@Test func silenceFromGPTLiveIsNotPlayed() {
  #expect(GPTLiveProtocol.isSilence(Data(count: 4_800)))
  let quiet = [Int16](repeating: 40, count: 2_400).withUnsafeBytes { Data($0) }
  #expect(GPTLiveProtocol.isSilence(quiet))
  var speech = [Int16](repeating: 0, count: 2_400)
  speech[1_200] = 9_000
  #expect(!GPTLiveProtocol.isSilence(speech.withUnsafeBytes { Data($0) }))
}

@Test func aLongReportToGPTLiveIsCutAtASentence() {
  #expect(GPTLiveProtocol.speakable("  The whiteboard is open.  ") == "The whiteboard is open.")
  let long = String(repeating: "This sentence is here to fill the report. ", count: 80)
  let cut = GPTLiveProtocol.speakable(long)
  #expect(cut.count <= 1_600)
  #expect(cut.hasSuffix("."))
}

@Test func gptLiveIsStartedWithOttoAsItsBackend() throws {
  let event = GPTLiveProtocol.startEvent(GPTLiveConfiguration(instructions: "Be Otto."))
  let session = try #require(event["session"] as? [String: Any])
  #expect(session["model"] as? String == "gpt-live-1")
  #expect((session["delegation"] as? [String: String])?["type"] == "client")
  let audio = try #require(session["audio"] as? [String: Any])
  #expect((audio["format"] as? [String: Any])?["rate"] as? Int == 24_000)
}

@Test func whatIsOnScreenTravelsWithTheRequest() async {
  let request = await VoiceScreen.attaching(
    { "The user is in Documents in Otto, looking at the document \"Plan.md\"." },
    to: "Summarise this")
  #expect(request.hasPrefix("Summarise this"))
  #expect(request.contains("Plan.md"))

  #expect(await VoiceScreen.attaching(nil, to: "Hello") == "Hello")
  #expect(await VoiceScreen.attaching({ nil }, to: "Hello") == "Hello")
}

@Test func aSlowScreenNeverHoldsUpARequest() async {
  let began = ContinuousClock.now
  let request = await VoiceScreen.attaching(
    {
      try? await Task.sleep(for: .seconds(5))
      return "too late"
    }, to: "Open Home", patience: .milliseconds(100))
  #expect(request == "Open Home")
  #expect(ContinuousClock.now - began < .seconds(2))
}

@Test func whatIsReadFromTheScreenIsKeptShort() {
  #expect(VoiceScreen.excerpt("  short  ") == "short")
  #expect(VoiceScreen.excerpt(String(repeating: "x", count: 5_000)).count <= 2_402)
}

@Test func theScreenFollowsWhatVoiceActsOn() {
  let id = UUID()
  #expect(
    VoiceFollow.destination(
      afterTool: "agent.spawn", output: .object(["agentID": .string(id.uuidString)]))
      == .conversation(id))
  #expect(
    VoiceFollow.destination(
      afterTool: "agent.send_prompt", output: .object(["agentID": .string(id.uuidString)]))
      == .conversation(id))
  #expect(
    VoiceFollow.destination(
      afterTool: "docs.create",
      output: .object(["file": .object(["path": .string("/tmp/Plan.md")])]))
      == .document(path: "/tmp/Plan.md"))
  #expect(
    VoiceFollow.destination(afterTool: "browser.open", output: .object([:])) == .place("browser"))
  #expect(
    VoiceFollow.destination(afterTool: "routine.create", output: .object([:]))
      == .place("automations"))
}

@Test func readingSomethingDoesNotMoveTheScreen() {
  let output = JSONValue.object(["agentID": .string(UUID().uuidString)])
  #expect(VoiceFollow.destination(afterTool: "agent.get_result", output: output) == nil)
  #expect(VoiceFollow.destination(afterTool: "session.list", output: output) == nil)
  #expect(VoiceFollow.destination(afterTool: "docs.read", output: output) == nil)
}

@Test func aSentenceLeftWithoutAFullStopIsProbablyUnfinished() {
  #expect(SpokenRequest.ending(of: "Go ahead and um give") == .open)
  #expect(SpokenRequest.ending(of: "Can you open a new Codex session for me using 6.2") == .open)
  #expect(SpokenRequest.ending(of: "Open the whiteboard and") == .leadsOn)
  #expect(SpokenRequest.ending(of: "Use Sol.") == .finished)
  #expect(SpokenRequest.ending(of: "Can you just ask it to summarise Otto?") == .finished)
  // One word is whatever it is: there is nothing to wait for.
  #expect(SpokenRequest.ending(of: "Stop") == .finished)
}

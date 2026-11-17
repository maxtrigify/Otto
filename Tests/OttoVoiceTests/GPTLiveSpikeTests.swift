import Foundation
import OttoSecurity
import OttoTools
import Testing

@testable import OttoVoice

/// A measurement, not a regression test: opens one real GPT-Live session with Otto as its own
/// backend ("client delegation"), speaks a request into it, answers the delegation by hand a few
/// seconds later, and prints when everything happened. Off by default because it spends a few
/// cents of the stored OpenAI key.
///
///     OTTO_LIVE_GPT_LIVE=1 scripts/otto-swift test --filter GPTLiveSpike
@Suite("GPT-Live with Otto as the backend, live")
struct GPTLiveSpikeTests {
  private static let enabled = ProcessInfo.processInfo.environment["OTTO_LIVE_GPT_LIVE"] != nil

  /// The request, spoken by the Mac's own voice as 24 kHz PCM16 with the WAV header removed.
  private static func spokenRequest(_ text: String) throws -> Data {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = [
      "-v", "Daniel", "--file-format=WAVE", "--data-format=LEI16@24000", "-o", file.path, text,
    ]
    try say.run()
    say.waitUntilExit()
    let wav = try Data(contentsOf: file)
    guard let marker = wav.range(of: Data("data".utf8)) else { return wav }
    return wav.subdata(in: (marker.upperBound + 4)..<wav.count)
  }

  private actor Timeline {
    private let began = ContinuousClock.now
    private(set) var lines: [String] = []
    private(set) var delegation: String?
    private(set) var heard = ""
    private(set) var said = ""
    private(set) var audioBytes = 0
    private var firstAudioNoted = false

    func note(_ text: String) {
      let elapsed = ContinuousClock.now - began
      let seconds =
        Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      lines.append(String(format: "%6.2fs  %@", seconds, text))
    }

    func absorb(_ text: String) {
      guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
      else { return }
      let type = event["type"] as? String ?? "?"
      switch type {
      case "session.output_audio.delta":
        let bytes = (event["delta"] as? String).flatMap { Data(base64Encoded: $0) }?.count ?? 0
        audioBytes += bytes
        if !firstAudioNoted {
          firstAudioNoted = true
          note("first sound from the model")
        }
      case "session.input_transcript.delta":
        heard += event["delta"] as? String ?? ""
      case "session.output_transcript.delta":
        let delta = event["delta"] as? String ?? ""
        if said.isEmpty || said.hasSuffix(".") || said.hasSuffix("?") {
          note("model starts saying: \(delta)")
        }
        said += delta
      case "session.delegation.created":
        delegation = (event["delegation"] as? [String: Any])?["id"] as? String
        firstAudioNoted = false
        note("DELEGATED to Otto (heard so far: \(heard))")
      case "session.usage.updated":
        break
      case "error":
        note("ERROR \(event["error"] ?? event)")
      default:
        note(type)
      }
    }

    func afterAnswering() { firstAudioNoted = false }
  }

  @Test(.enabled(if: enabled))
  func aSessionOpensHearsARequestAndHandsItToOtto() async throws {
    let key = try #require(
      try await makeDefaultSecretStore().value(for: "openai.api-key"),
      "No OpenAI key is stored in Otto Dev")
    let timeline = Timeline()

    var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    await timeline.note("connecting")

    func send(_ event: [String: Any]) async throws {
      let data = try JSONSerialization.data(withJSONObject: event)
      try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    try await send([
      "type": "session.start",
      "event_id": "start",
      "session": [
        "model": "gpt-live-1",
        "instructions": """
        You are Otto, a calm, capable British assistant who works beside the user in their
        desktop app. You cannot do or look up anything yourself. Whenever the user asks for
        something to be done, opened, started or checked, hand it to your backend, and keep the
        user company in a few natural words while it works. Never claim something is done until
        the backend says so.
        """,
        "audio": [
          "format": ["type": "audio/pcm", "rate": 24_000],
          "output": ["voice": "marin"],
        ],
        "delegation": ["type": "client"],
      ],
    ])

    let reader = Task {
      while !Task.isCancelled {
        guard let message = try? await socket.receive() else { break }
        let text: String
        switch message {
        case .string(let string): text = string
        case .data(let data): text = String(decoding: data, as: UTF8.self)
        @unknown default: continue
        }
        await timeline.absorb(text)
      }
    }

    // Wait for the session to open; this is the delay a person would feel on pressing Talk.
    for _ in 0..<200 {
      if await timeline.lines.contains(where: { $0.contains("session.started") }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }

    let speech = try Self.spokenRequest("Open a whiteboard and tell me how Otto is used.")
    let chunk = 4_800  // a tenth of a second
    let silence = Data(count: chunk)
    await timeline.note("the person starts speaking")
    var offset = 0
    while offset < speech.count {
      let end = min(offset + chunk, speech.count) & ~1
      try await send([
        "type": "session.input_audio.append",
        "audio": speech.subdata(in: offset..<max(end, offset + 2)).base64EncodedString(),
      ])
      offset = max(end, offset + 2)
      try await Task.sleep(for: .milliseconds(100))
    }
    await timeline.note("the person stops speaking")

    // The microphone stays open, as it would in the app. Otto "works" for three seconds after
    // being handed the request, then reports back.
    var answered = false
    var delegatedAt: ContinuousClock.Instant?
    for _ in 0..<200 {
      try await send([
        "type": "session.input_audio.append", "audio": silence.base64EncodedString(),
      ])
      try await Task.sleep(for: .milliseconds(100))
      if let id = await timeline.delegation, !answered {
        if delegatedAt == nil { delegatedAt = .now }
        if let delegatedAt, ContinuousClock.now - delegatedAt >= .seconds(3) {
          answered = true
          await timeline.afterAnswering()
          await timeline.note("Otto reports back to the model")
          try await send([
            "type": "session.commentary.append",
            "event_id": "result",
            "delegation_id": id,
            "content":
              "Done. A new whiteboard called How Otto is used is open on screen, with notes on bots, sessions and automations.",
          ])
        }
      }
    }

    try await send(["type": "session.close", "event_id": "close"])
    try await Task.sleep(for: .seconds(2))
    reader.cancel()
    socket.cancel(with: .normalClosure, reason: nil)

    let report = await timeline.lines.joined(separator: "\n")
    let heard = await timeline.heard
    let said = await timeline.said
    let seconds = Double(await timeline.audioBytes) / 48_000
    print(
      """

      ===== GPT-Live spike =====
      \(report)
      heard: \(heard)
      said:  \(said)
      audio returned: \(String(format: "%.1f", seconds))s
      ==========================

      """)
    #expect(await timeline.lines.contains(where: { $0.contains("session.started") }))
  }

  /// Stands in for Otto's assistant: takes a moment, then reports that the work is done.
  private actor StandInAssistant: LocalVoiceThinking {
    nonisolated let events: AsyncStream<LocalVoiceBrainEvent>
    private let continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation
    private(set) var requests: [String] = []

    init() {
      var continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation!
      events = AsyncStream { continuation = $0 }
      self.continuation = continuation
    }

    func start(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) async throws {}
    func ask(_ text: String) async {
      requests.append(text)
      let continuation = continuation
      Task {
        try? await Task.sleep(for: .seconds(2))
        continuation.yield(.text("A new whiteboard called How Otto is used is now open on screen."))
        continuation.yield(.finished)
      }
    }
    func interrupt() async {}
    func stop() async { continuation.finish() }
  }

  /// The real engine, end to end, with only Otto's assistant replaced.
  @Test(.enabled(if: enabled))
  func theEngineHandsARequestToOttoAndSpeaksItsAnswer() async throws {
    let assistant = StandInAssistant()
    let provider = GPTLiveProvider(
      secrets: makeDefaultSecretStore(), brain: assistant,
      configuration: GPTLiveConfiguration(
        instructions: """
          You are Otto, a calm British assistant. You cannot do anything yourself: hand every
          request to your backend and keep the user company briefly while it works.
          """))

    actor Heard {
      private let began = ContinuousClock.now
      var lines: [String] = []
      var audio = 0
      func note(_ text: String) {
        let elapsed = ContinuousClock.now - began
        lines.append(
          String(
            format: "%6.2fs  %@",
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            text))
      }
      func add(_ bytes: Int) { audio += bytes }
    }
    let heard = Heard()
    let events = Task {
      var saying = false
      for await event in provider.events {
        switch event {
        case .speaking(let text):
          if !saying { await heard.note("Otto starts speaking: \(text)") }
          saying = true
        case .speechFinished:
          saying = false
          await heard.note("Otto finished speaking")
        case .finalTranscript(let text): await heard.note("person said: \(text)")
        case .thinking: await heard.note("handed to Otto's assistant")
        case .partialTranscript: break
        default: await heard.note("\(event)")
        }
      }
    }
    let audio = Task {
      for await data in provider.audioOutput { await heard.add(data.count) }
    }

    try await provider.connect(tools: [])
    await heard.note("the person starts speaking at once, before the conversation has opened")
    let speech = try Self.spokenRequest("Open a whiteboard and tell me how Otto is used.")
    var offset = 0
    while offset < speech.count {
      let end = min(offset + 4_800, speech.count) & ~1
      guard end > offset else { break }
      try await provider.sendAudio(speech.subdata(in: offset..<end))
      offset = end
      try await Task.sleep(for: .milliseconds(100))
    }
    await heard.note("the person stops speaking")
    for _ in 0..<160 {
      try await provider.sendAudio(Data(count: 4_800))
      try await Task.sleep(for: .milliseconds(100))
    }
    await provider.disconnect()
    events.cancel()
    audio.cancel()

    let requests = await assistant.requests
    print(
      """

      ===== GPT-Live engine =====
      \(await heard.lines.joined(separator: "\n"))
      Otto's assistant was asked: \(requests)
      speech played: \(String(format: "%.1f", Double(await heard.audio) / 48_000))s
      ===========================

      """)
    #expect(requests.count == 1)
    #expect(requests.first?.lowercased().contains("whiteboard") == true)
    #expect(await heard.audio > 48_000)
  }
}

import Foundation
import OttoSecurity
import OttoTools
import OttoVoice
import Testing

private struct OpenAITestInput: Codable, Sendable { let value: String }
private struct OpenAITestOutput: Codable, Sendable { let echoed: String }

private struct OpenAITestTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.openai_echo",
    description: "Echoes a realtime fixture value.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["type": .string("string")])
      ]),
      "required": .array([.string("value")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: OpenAITestInput, context: ToolContext) async throws -> OpenAITestOutput {
    OpenAITestOutput(echoed: input.value)
  }
}

@Suite("OpenAI GPT Realtime voice transport")
struct OpenAIRealtimeProviderTests {
  private var testConfiguration: OpenAIRealtimeConfiguration {
    OpenAIRealtimeConfiguration(
      endpoint: URL(string: "wss://voice.test/v1/realtime")!,
      instructions: "Control Otto with concise confirmations.",
      reconnectDelay: .zero
    )
  }

  @Test("Missing API key fails connection with actionable guidance")
  func missingKey() async throws {
    let provider = OpenAIRealtimeProvider(
      secrets: InMemorySecretStore(),
      configuration: testConfiguration,
      socketFactory: { MockRealtimeSocket() }
    )
    await #expect(throws: OpenAIRealtimeError.missingAPIKey) {
      try await provider.connect(tools: [])
    }
  }

  @Test("Session negotiation sends OpenAI credentials, formats, and projected tools")
  func sessionNegotiation() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("openai-test-secret", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [OpenAITestTool.definition])

    let request = try #require(await socket.request)
    #expect(request.url?.absoluteString == "wss://voice.test/v1/realtime?model=gpt-realtime-2.1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer openai-test-secret")
    #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)

    try await waitUntil { await socket.sent.count == 1 }
    let update = try jsonObject(await socket.sent[0])
    #expect(update["type"] as? String == "session.update")
    let session = try #require(update["session"] as? [String: Any])
    #expect(session["type"] as? String == "realtime")
    #expect(session["model"] as? String == "gpt-realtime-2.1")
    #expect(session["output_modalities"] as? [String] == ["audio"])
    #expect(session["tool_choice"] as? String == "auto")
    let audio = try #require(session["audio"] as? [String: Any])
    let input = try #require(audio["input"] as? [String: Any])
    let inputFormat = try #require(input["format"] as? [String: Any])
    #expect(inputFormat["type"] as? String == "audio/pcm")
    #expect(inputFormat["rate"] as? Int == 24_000)
    let transcription = try #require(input["transcription"] as? [String: Any])
    #expect(transcription["model"] as? String == "gpt-live-transcribe")
    let noiseReduction = try #require(input["noise_reduction"] as? [String: Any])
    #expect(noiseReduction["type"] as? String == "far_field")
    let turnDetection = try #require(input["turn_detection"] as? [String: Any])
    #expect(turnDetection["type"] as? String == "server_vad")
    #expect(turnDetection["threshold"] as? Double == 0.5)
    #expect(turnDetection["interrupt_response"] as? Bool == false)
    // 450ms finalized mid-sentence pauses as complete turns (double-answer jitter); this must
    // stay in step with the xAI provider's tuned value.
    #expect(turnDetection["silence_duration_ms"] as? Int == 800)
    let output = try #require(audio["output"] as? [String: Any])
    let outputFormat = try #require(output["format"] as? [String: Any])
    #expect(outputFormat["type"] as? String == "audio/pcm")
    #expect(outputFormat["rate"] as? Int == 24_000)
    #expect(output["voice"] as? String == "marin")
    let projected = try #require(session["tools"] as? [[String: Any]])
    #expect(projected.first?["name"] as? String == "test_openai_echo")
    #expect(projected.first?["type"] as? String == "function")
    #expect((session["instructions"] as? String)?.contains("Control Otto") == true)
  }

  @Test("Repeated session acknowledgments announce connected once; benign cancel errors stay quiet")
  func connectionAnnouncementAndBenignErrors() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])

    let collector = Task<[VoiceProviderEvent], Never> {
      var events: [VoiceProviderEvent] = []
      for await event in provider.events {
        events.append(event)
        if case .speechFinished = event { break }
      }
      return events
    }
    // Instruction refreshes acknowledge as session.updated repeatedly over one socket; only
    // the first may announce a connection, or the trace spams and state resets mid-speech.
    await socket.emit(#"{"type":"session.created"}"#)
    await socket.emit(#"{"type":"session.updated"}"#)
    await socket.emit(#"{"type":"session.updated"}"#)
    // Cancelling with no active response is a routine barge-in race, not a failure.
    await socket.emit(
      #"{"type":"error","error":{"code":"response_cancel_not_active","message":"Cancellation failed: no active response found"}}"#
    )
    await socket.emit(
      #"{"type":"error","error":{"message":"Cancellation failed: no active response found"}}"#)
    await socket.emit(
      #"{"type":"error","error":{"code":"conversation_already_has_active_response","message":"Conversation already has an active response in progress"}}"#
    )
    await socket.emit(#"{"type":"response.done"}"#)

    let events = await collector.value
    let connectedCount = events.filter {
      if case .connected = $0 { return true } else { return false }
    }
    .count
    let failures = events.filter { if case .failed = $0 { return true } else { return false } }
    #expect(connectedCount == 1)
    #expect(failures.isEmpty)
  }

  @Test("Rapid tool results coalesce into one response creation")
  func coalescesRapidToolResults() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [OpenAITestTool.definition])

    await provider.sendToolResult(
      VoiceToolResult(callID: "call-1", result: .object(["ok": .bool(true)]), isError: false)
    )
    await provider.sendToolResult(
      VoiceToolResult(callID: "call-2", result: .object(["ok": .bool(true)]), isError: false)
    )

    // The provider deliberately debounces tool results. Allow for actor scheduling pressure when
    // this suite runs alongside the rest of the package; the assertion below still verifies that
    // both results produce exactly one response request.
    try await waitUntil(timeout: .seconds(5)) { await socket.sent.count >= 4 }
    let messageTypes = try await socket.sent.map { try jsonObject($0)["type"] as? String }
    #expect(messageTypes.filter { $0 == "response.create" }.count == 1)
  }

  @Test("Tool result waits for an active response to finish")
  func defersToolResultDuringActiveResponse() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [OpenAITestTool.definition])
    await socket.emit(#"{"type":"response.created"}"#)
    try await Task.sleep(for: .milliseconds(20))

    await provider.sendToolResult(
      VoiceToolResult(callID: "call-active", result: .object(["ok": .bool(true)]), isError: false)
    )
    try await Task.sleep(for: .milliseconds(120))
    #expect(await socket.sent.count == 2)

    await socket.emit(#"{"type":"response.done"}"#)
    try await waitUntil { await socket.sent.count == 3 }
    #expect(try jsonObject(await socket.sent[2])["type"] as? String == "response.create")
  }

  @Test("Tool calls round-trip through function_call_output and response.create")
  func toolCallRoundTrip() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [OpenAITestTool.definition])
    await socket.emit(#"{"type":"session.updated"}"#)

    let toolEvent = Task<VoiceProviderEvent?, Never> {
      for await event in provider.events {
        if case .toolCall = event { return event }
      }
      return nil
    }
    await socket.emit(
      #"{"type":"response.function_call_arguments.done","call_id":"call-9","name":"test_openai_echo","arguments":"{\"value\":\"ping\"}"}"#
    )
    guard case .toolCall(let id, let name, let arguments) = await toolEvent.value else {
      Issue.record("Expected a projected tool call event")
      return
    }
    #expect(id == "call-9")
    #expect(name == "test.openai_echo")
    #expect(arguments["value"]?.stringValue == "ping")

    await provider.sendToolResult(
      VoiceToolResult(
        callID: id,
        result: .object(["echoed": .string("ping")]),
        isError: false
      ))
    try await waitUntil { await socket.sent.count >= 3 }
    let outputMessage = try jsonObject(await socket.sent[1])
    #expect(outputMessage["type"] as? String == "conversation.item.create")
    let item = try #require(outputMessage["item"] as? [String: Any])
    #expect(item["type"] as? String == "function_call_output")
    #expect(item["call_id"] as? String == "call-9")
    #expect((item["output"] as? String)?.contains("ping") == true)
    #expect(try jsonObject(await socket.sent[2])["type"] as? String == "response.create")
  }

  @Test("Audio input appends base64 PCM and both output delta spellings decode")
  func audioRoundTrip() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])
    let expected = Data([7, 0, 255, 3])
    try await provider.appendAudio(expected)
    try await waitUntil { await socket.sent.count >= 2 }
    let appended = try jsonObject(await socket.sent[1])
    #expect(appended["type"] as? String == "input_audio_buffer.append")
    #expect(appended["audio"] as? String == expected.base64EncodedString())

    let collector = Task<[Data], Never> {
      var received: [Data] = []
      for await data in provider.audioOutput {
        received.append(data)
        if received.count == 2 { break }
      }
      return received
    }
    await socket.emit(
      "{\"type\":\"response.audio.delta\",\"delta\":\"\(expected.base64EncodedString())\"}"
    )
    await socket.emit(
      "{\"type\":\"response.output_audio.delta\",\"delta\":\"\(expected.base64EncodedString())\"}"
    )
    #expect(await collector.value == [expected, expected])
    await provider.disconnect()
  }

  @Test("Transcription deltas surface as partial and final transcripts")
  func transcriptMapping() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])

    let transcripts = Task<[String], Never> {
      var collected: [String] = []
      for await event in provider.events {
        switch event {
        case .partialTranscript(let text): collected.append("partial:\(text)")
        case .finalTranscript(let text): collected.append("final:\(text)")
        default: continue
        }
        if collected.count == 2 { break }
      }
      return collected
    }
    await socket.emit(
      #"{"type":"conversation.item.input_audio_transcription.delta","delta":"Open the"}"#)
    await socket.emit(
      #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Open the BBC"}"#
    )
    #expect(await transcripts.value == ["partial:Open the", "final:Open the BBC"])
  }

  @Test("Failed input transcription still ends the user turn with an empty final transcript")
  func failedTranscriptionEndsTurn() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "openai.api-key")
    let socket = MockRealtimeSocket()
    let provider = OpenAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])

    let finals = Task<[String], Never> {
      for await event in provider.events {
        if case .finalTranscript(let text) = event { return [text] }
      }
      return []
    }
    // Swallowing this event leaves the session's user-turn state latched, muting all later
    // playback and queued completion notices — the turn must end even without a transcript.
    await socket.emit(
      #"{"type":"conversation.item.input_audio_transcription.failed","error":{"message":"audio too short"}}"#
    )
    #expect(await finals.value == [""])
  }
}

private actor MockRealtimeSocket: RealtimeSocket {
  nonisolated let messages: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private(set) var request: URLRequest?
  private(set) var sent: [String] = []

  init() {
    var continuation: AsyncStream<String>.Continuation!
    messages = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func connect(request: URLRequest) async throws { self.request = request }
  func send(text: String) async throws { sent.append(text) }
  func disconnect() async { continuation.finish() }
  func emit(_ message: String) { continuation.yield(message) }
}

private func jsonObject(_ string: String) throws -> [String: Any] {
  try #require(
    try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
  )
}

private func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for realtime voice state")
}

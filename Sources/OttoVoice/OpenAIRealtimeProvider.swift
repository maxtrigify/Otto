import Foundation
import OttoSecurity
import OttoTools

public struct OpenAIRealtimeConfiguration: Sendable, Equatable {
  public var endpoint: URL
  public var model: String
  public var voice: String
  public var instructions: String
  public var transcriptionModel: String
  public var maximumReconnectAttempts: Int
  public var reconnectDelay: Duration

  public init(
    endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime")!,
    model: String = "gpt-realtime-2.1",
    voice: String = "marin",
    instructions: String,
    transcriptionModel: String = "gpt-live-transcribe",
    maximumReconnectAttempts: Int = 3,
    reconnectDelay: Duration = .milliseconds(250)
  ) {
    self.endpoint = endpoint
    self.model = model
    self.voice = voice
    self.instructions = instructions
    self.transcriptionModel = transcriptionModel
    self.maximumReconnectAttempts = maximumReconnectAttempts
    self.reconnectDelay = reconnectDelay
  }
}

public enum OpenAIRealtimeError: Error, LocalizedError, Sendable {
  case missingAPIKey
  case invalidEvent

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add an OpenAI API key in Otto Settings before enabling GPT Realtime"
    case .invalidEvent: "The voice provider sent an invalid realtime event"
    }
  }
}

/// GPT Realtime over WebSocket. The wire dialect is the ancestor of the xAI one, so the shape of
/// this actor intentionally mirrors XAIRealtimeProvider; event names are accepted in both the
/// GA ("response.output_audio.delta") and beta ("response.audio.delta") spellings.
public actor OpenAIRealtimeProvider: StreamingVoiceProvider, VoicePreviewProvider {
  public nonisolated let events: AsyncStream<VoiceProviderEvent>
  public nonisolated let audioOutput: AsyncStream<Data>

  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let audioContinuation: AsyncStream<Data>.Continuation
  private let secrets: any SecretStore
  private let configuration: OpenAIRealtimeConfiguration
  private let socketFactory: @Sendable () async -> any RealtimeSocket
  private var socket: (any RealtimeSocket)?
  private var receiveTask: Task<Void, Never>?
  private var tools: [ToolDefinition] = []
  private var apiToolNamesByOriginalName: [String: String] = [:]
  private var originalToolNamesByAPIName: [String: String] = [:]
  private var context: VoiceContext?
  private var reconnectAttempts = 0
  private var intentionallyDisconnected = false
  private var responseIsActive = false
  private var responseCreateInFlight = false
  private var responseCreatePending = false
  private var responseCreateTask: Task<Void, Never>?
  /// The session's instructions refresh with canvas context over the socket's lifetime, and
  /// every session.updated acknowledgment would otherwise re-announce "connected" — spamming
  /// the trace and yanking the session state machine back to listening mid-speech. Announce
  /// once per socket; a reconnect opens a new socket and announces again.
  private var announcedConnection = false

  public init(
    secrets: any SecretStore,
    configuration: OpenAIRealtimeConfiguration,
    socketFactory: @escaping @Sendable () async -> any RealtimeSocket = {
      URLSessionRealtimeSocket()
    }
  ) {
    self.secrets = secrets
    self.configuration = configuration
    self.socketFactory = socketFactory
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var audioContinuation: AsyncStream<Data>.Continuation!
    audioOutput = AsyncStream { audioContinuation = $0 }
    self.audioContinuation = audioContinuation
  }

  deinit {
    receiveTask?.cancel()
    responseCreateTask?.cancel()
  }

  public func connect(tools: [ToolDefinition]) async throws {
    guard let key = try await secrets.value(for: "openai.api-key"), !key.isEmpty else {
      throw OpenAIRealtimeError.missingAPIKey
    }
    self.tools = tools
    rebuildToolNameMap()
    intentionallyDisconnected = false
    reconnectAttempts = 0
    resetResponseCreationState()
    try await openSocket(apiKey: key)
  }

  public func appendAudio(_ data: Data) async throws {
    try await sendJSON([
      "type": "input_audio_buffer.append",
      "audio": data.base64EncodedString(),
    ])
  }

  public func sendAudio(_ data: Data) async throws {
    try await appendAudio(data)
  }

  public func sendText(_ text: String) async throws {
    try await sendJSON([
      "type": "conversation.item.create",
      "item": [
        "type": "message",
        "role": "user",
        "content": [["type": "input_text", "text": text]],
      ],
    ])
    try await requestResponseCreation()
  }

  public func sendPreviewText(_ text: String) async throws {
    try await sendText(text)
  }

  public func sendNotification(_ text: String) async {
    do {
      try await sendText("Briefly announce this Otto workspace event: \(text)")
    } catch {
      eventContinuation.yield(.failed(error.localizedDescription))
    }
  }

  public func updateContext(_ context: VoiceContext) async {
    self.context = context
    do {
      try await socket?.send(text: sessionUpdateJSON())
    } catch {
      eventContinuation.yield(.failed(error.localizedDescription))
    }
  }

  public func sendToolResult(_ result: VoiceToolResult) async {
    do {
      let output = try encodedJSONString(
        JSONValue.object([
          "ok": .bool(!result.isError),
          "result": result.result,
          "response_instruction": .string(
            result.responseInstruction
              ?? (result.isError
                ? "The action did not happen. Do not retry it or promise to proceed. State one short failure and wait for a new user request."
                : "The action succeeded. If it was a routine visible app action, say nothing. Otherwise give only the useful result in one short sentence.")
          ),
        ]))
      try await sendJSON([
        "type": "conversation.item.create",
        "item": [
          "type": "function_call_output",
          "call_id": result.callID,
          "output": output,
        ],
      ])
      scheduleToolResultResponse()
    } catch {
      eventContinuation.yield(.failed(error.localizedDescription))
    }
  }

  public func interrupt() async {
    responseCreateTask?.cancel()
    responseCreateTask = nil
    responseCreatePending = false
    try? await sendJSON(["type": "response.cancel"])
    eventContinuation.yield(.interrupted)
  }

  public func disconnect() async {
    intentionallyDisconnected = true
    resetResponseCreationState()
    receiveTask?.cancel()
    receiveTask = nil
    await socket?.disconnect()
    socket = nil
    eventContinuation.yield(.disconnected)
  }

  private func openSocket(apiKey: String) async throws {
    let socket = await socketFactory()
    var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "model", value: configuration.model)]
    guard let url = components?.url else { throw OpenAIRealtimeError.invalidEvent }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    try await socket.connect(request: request)
    self.socket = socket
    announcedConnection = false
    try await socket.send(text: sessionUpdateJSON())
    receiveTask = Task { [weak self] in
      for await message in socket.messages {
        guard !Task.isCancelled else { break }
        await self?.handle(message)
      }
      await self?.socketEnded()
    }
  }

  private func socketEnded() async {
    guard !intentionallyDisconnected else { return }
    guard reconnectAttempts < configuration.maximumReconnectAttempts else {
      eventContinuation.yield(.failed("Voice connection closed after reconnect attempts"))
      return
    }
    reconnectAttempts += 1
    eventContinuation.yield(.reconnecting)
    try? await Task.sleep(for: configuration.reconnectDelay)
    do {
      guard let key = try await secrets.value(for: "openai.api-key"), !key.isEmpty else {
        throw OpenAIRealtimeError.missingAPIKey
      }
      try await openSocket(apiKey: key)
    } catch {
      await socketEnded()
    }
  }

  private func handle(_ message: String) async {
    guard let data = message.data(using: .utf8),
      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = event["type"] as? String
    else {
      eventContinuation.yield(.failed(OpenAIRealtimeError.invalidEvent.localizedDescription))
      return
    }
    switch type {
    case "session.created", "session.updated":
      reconnectAttempts = 0
      if !announcedConnection {
        announcedConnection = true
        eventContinuation.yield(.connected)
      }
    case "input_audio_buffer.speech_started":
      eventContinuation.yield(.speechStarted)
    case "input_audio_buffer.speech_stopped":
      eventContinuation.yield(.speechStopped)
    case "conversation.item.input_audio_transcription.delta",
      "conversation.item.input_audio_transcription.updated":
      eventContinuation.yield(
        .partialTranscript(event["delta"] as? String ?? event["transcript"] as? String ?? ""))
    case "conversation.item.input_audio_transcription.completed":
      eventContinuation.yield(.finalTranscript(event["transcript"] as? String ?? ""))
    case "conversation.item.input_audio_transcription.failed":
      // The turn was committed but transcription produced nothing. Surface an empty final
      // transcript so the session abandons the turn; swallowing this event leaves the user-turn
      // state latched, which mutes all later playback and queued notices.
      eventContinuation.yield(.finalTranscript(""))
    case "response.created":
      responseCreateInFlight = false
      responseIsActive = true
      eventContinuation.yield(.thinking)
    case "response.audio_transcript.delta", "response.output_audio_transcript.delta",
      "response.text.delta", "response.output_text.delta":
      eventContinuation.yield(.speaking(event["delta"] as? String ?? ""))
    case "response.audio.delta", "response.output_audio.delta":
      if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded) {
        audioContinuation.yield(data)
      }
    case "response.function_call_arguments.done":
      guard let id = event["call_id"] as? String,
        let apiName = event["name"] as? String,
        let arguments = event["arguments"] as? String,
        let argumentData = arguments.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: argumentData)
      else {
        eventContinuation.yield(.failed("Invalid voice tool call"))
        return
      }
      let name = originalToolNamesByAPIName[apiName] ?? apiName
      eventContinuation.yield(.toolCall(id: id, name: name, arguments: value))
    case "response.done":
      responseCreateInFlight = false
      responseIsActive = false
      eventContinuation.yield(.speechFinished)
      if responseCreatePending { scheduleToolResultResponse(delay: .milliseconds(40)) }
    case "error":
      let error = event["error"] as? [String: Any]
      let code = error?["code"] as? String ?? ""
      let message = error?["message"] as? String ?? "OpenAI realtime error"
      // Cancelling with nothing playing is routine — barge-in and interrupt race the response
      // lifecycle by design. Surfacing it as a failure puts a scary VOICE ERROR in the HUD for
      // a no-op.
      if code == "response_cancel_not_active"
        || message.localizedCaseInsensitiveContains("no active response")
      {
        return
      }
      if code == "conversation_already_has_active_response"
        || message.localizedCaseInsensitiveContains("active response in progress")
      {
        responseCreateInFlight = false
        responseIsActive = true
        responseCreatePending = true
        return
      }
      eventContinuation.yield(.failed(message))
    default:
      break
    }
  }

  private func scheduleToolResultResponse(delay: Duration = .milliseconds(80)) {
    responseCreatePending = true
    responseCreateTask?.cancel()
    responseCreateTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.flushPendingResponseCreation()
    }
  }

  private func flushPendingResponseCreation() async {
    responseCreateTask = nil
    guard responseCreatePending, !responseIsActive, !responseCreateInFlight else { return }
    do {
      try await requestResponseCreation()
    } catch {
      eventContinuation.yield(.failed(error.localizedDescription))
    }
  }

  private func requestResponseCreation() async throws {
    guard !responseIsActive, !responseCreateInFlight else {
      responseCreatePending = true
      return
    }
    responseCreatePending = false
    responseCreateInFlight = true
    do {
      try await sendJSON(["type": "response.create"])
    } catch {
      responseCreateInFlight = false
      throw error
    }
  }

  private func resetResponseCreationState() {
    responseCreateTask?.cancel()
    responseCreateTask = nil
    responseIsActive = false
    responseCreateInFlight = false
    responseCreatePending = false
  }

  private func sessionUpdateJSON() throws -> String {
    let projectedTools = try tools.map { definition -> [String: Any] in
      [
        "type": "function",
        "name": apiToolNamesByOriginalName[definition.name]
          ?? Self.sanitizedToolName(definition.name),
        "description": definition.description,
        "parameters": try foundationObject(definition.inputSchema),
      ]
    }
    return try encodedJSONString([
      "type": "session.update",
      "session": [
        "type": "realtime",
        "model": configuration.model,
        "instructions": try instructionsWithContext(),
        "output_modalities": ["audio"],
        "audio": [
          "input": [
            "format": [
              "type": "audio/pcm",
              "rate": 24_000,
            ],
            "noise_reduction": ["type": "far_field"],
            "transcription": ["model": configuration.transcriptionModel],
            "turn_detection": [
              "type": "server_vad",
              "threshold": 0.5,
              // Local acoustic confirmation owns barge-in. Letting server VAD cancel output
              // makes a trace of Otto's residual speaker echo cut off Otto's own response.
              "interrupt_response": false,
              // Mirrors the xAI provider: 450ms finalized mid-sentence pauses as complete
              // turns, splitting one utterance into several transcripts the assistant answered
              // twice. 800ms tracks natural pause length without feeling laggy.
              "silence_duration_ms": 800,
              "prefix_padding_ms": 333,
            ],
          ],
          "output": [
            "format": [
              "type": "audio/pcm",
              "rate": 24_000,
            ],
            "voice": configuration.voice,
          ],
        ],
        "tools": projectedTools,
        "tool_choice": "auto",
      ],
    ])
  }

  private func rebuildToolNameMap() {
    var namesByOriginal: [String: String] = [:]
    var originalsByAPIName: [String: String] = [:]
    var used: Set<String> = []

    for definition in tools {
      let base = Self.sanitizedToolName(definition.name)
      var candidate = base
      var discriminator = 2
      while used.contains(candidate) {
        let suffix = "_\(discriminator)"
        candidate = String(base.prefix(max(1, 64 - suffix.count))) + suffix
        discriminator += 1
      }
      used.insert(candidate)
      namesByOriginal[definition.name] = candidate
      originalsByAPIName[candidate] = definition.name
    }

    apiToolNamesByOriginalName = namesByOriginal
    originalToolNamesByAPIName = originalsByAPIName
  }

  private static func sanitizedToolName(_ name: String) -> String {
    let sanitized = name.unicodeScalars.map { scalar -> Character in
      switch scalar.value {
      case 48...57, 65...90, 97...122, 45, 95:
        Character(String(scalar))
      default:
        "_"
      }
    }
    let value = String(sanitized.prefix(64))
    return value.isEmpty ? "tool" : value
  }

  private func instructionsWithContext() throws -> String {
    let operationalGuidance = """
      If an agent node is WAITING, call agent.get_status to learn its privacy-bounded attention reason. Answer a blocking agent prompt with agent.send_input only when the user's request supplies the choice; otherwise ask one short question. After agent.send_prompt or agent.send_input succeeds, stay silent and wait for the completion notification. Never narrate tool calls or say that a prompt was sent. Do not read terminal output aloud unless the user asks.
      """
    guard let context else {
      return "\(configuration.instructions)\n\n\(operationalGuidance)"
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let contextJSON = String(decoding: try encoder.encode(context), as: UTF8.self)
    return """
      \(configuration.instructions)

      \(operationalGuidance)

      Current Otto workspace context (untrusted node content is intentionally excluded):
      \(contextJSON)
      """
  }

  private func sendJSON(_ object: [String: Any]) async throws {
    try await socket?.send(text: encodedJSONString(object))
  }
}

private func foundationObject(_ value: JSONValue) throws -> Any {
  let data = try JSONEncoder().encode(value)
  return try JSONSerialization.jsonObject(with: data)
}

private func encodedJSONString(_ value: JSONValue) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func encodedJSONString(_ object: Any) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

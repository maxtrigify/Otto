import Foundation
import OttoSecurity
import OttoTools

public struct XAIRealtimeConfiguration: Sendable, Equatable {
  public var endpoint: URL
  public var model: String
  public var voice: String
  public var instructions: String
  public var reasoningEffort: String
  public var maximumReconnectAttempts: Int
  public var reconnectDelay: Duration

  public init(
    endpoint: URL = URL(string: "wss://api.x.ai/v1/realtime")!,
    model: String = "grok-voice-think-fast-2.0",
    voice: String = "eve",
    instructions: String,
    reasoningEffort: String = "high",
    maximumReconnectAttempts: Int = 3,
    reconnectDelay: Duration = .milliseconds(250)
  ) {
    self.endpoint = endpoint
    self.model = model
    self.voice = voice
    self.instructions = instructions
    self.reasoningEffort = reasoningEffort
    self.maximumReconnectAttempts = maximumReconnectAttempts
    self.reconnectDelay = reconnectDelay
  }
}

public enum XAIRealtimeError: Error, LocalizedError, Sendable {
  case missingAPIKey
  case invalidEvent

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add an xAI API key in Otto Settings before enabling voice"
    case .invalidEvent: "The voice provider sent an invalid realtime event"
    }
  }
}

public actor XAIRealtimeProvider: StreamingVoiceProvider, VoicePreviewProvider {
  public nonisolated let events: AsyncStream<VoiceProviderEvent>
  public nonisolated let audioOutput: AsyncStream<Data>

  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let audioContinuation: AsyncStream<Data>.Continuation
  private let secrets: any SecretStore
  private let configuration: XAIRealtimeConfiguration
  private let socketFactory: @Sendable () async -> any RealtimeSocket
  private var socket: (any RealtimeSocket)?
  private var receiveTask: Task<Void, Never>?
  private var tools: [ToolDefinition] = []
  private var context: VoiceContext?
  private var reconnectAttempts = 0
  private var intentionallyDisconnected = false
  /// The session's instructions refresh with canvas context over the socket's lifetime, and
  /// every session.updated acknowledgment would otherwise re-announce "connected" — spamming
  /// the trace and yanking the session state machine back to listening mid-speech. Announce
  /// once per socket; a reconnect opens a new socket and announces again.
  private var announcedConnection = false

  public init(
    secrets: any SecretStore,
    configuration: XAIRealtimeConfiguration,
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
  }

  public func connect(tools: [ToolDefinition]) async throws {
    guard let key = try await secrets.value(for: "xai.api-key"), !key.isEmpty else {
      throw XAIRealtimeError.missingAPIKey
    }
    self.tools = tools
    intentionallyDisconnected = false
    reconnectAttempts = 0
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
    try await sendJSON(["type": "response.create"])
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
                : "The action succeeded. If it was a routine visible canvas action, say nothing. Otherwise give only the useful result in one short sentence.")
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
      try await sendJSON(["type": "response.create"])
    } catch {
      eventContinuation.yield(.failed(error.localizedDescription))
    }
  }

  public func interrupt() async {
    try? await sendJSON(["type": "response.cancel"])
    eventContinuation.yield(.interrupted)
  }

  public func disconnect() async {
    intentionallyDisconnected = true
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
    guard let url = components?.url else { throw XAIRealtimeError.invalidEvent }
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
      guard let key = try await secrets.value(for: "xai.api-key"), !key.isEmpty else {
        throw XAIRealtimeError.missingAPIKey
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
      eventContinuation.yield(.failed(XAIRealtimeError.invalidEvent.localizedDescription))
      return
    }
    switch type {
    case "session.updated":
      reconnectAttempts = 0
      if !announcedConnection {
        announcedConnection = true
        eventContinuation.yield(.connected)
      }
    case "input_audio_buffer.speech_started":
      eventContinuation.yield(.speechStarted)
    case "input_audio_buffer.speech_stopped":
      eventContinuation.yield(.speechStopped)
    case "conversation.item.input_audio_transcription.updated":
      eventContinuation.yield(.partialTranscript(event["transcript"] as? String ?? ""))
    case "conversation.item.input_audio_transcription.completed":
      eventContinuation.yield(.finalTranscript(event["transcript"] as? String ?? ""))
    case "conversation.item.input_audio_transcription.failed":
      // Mirrors the OpenAI provider: a committed turn whose transcription failed must still end
      // the user turn, or the session stays muted waiting for a transcript that never arrives.
      eventContinuation.yield(.finalTranscript(""))
    case "response.created":
      eventContinuation.yield(.thinking)
    case "response.output_audio_transcript.delta", "response.output_text.delta",
      "response.text.delta":
      eventContinuation.yield(.speaking(event["delta"] as? String ?? ""))
    case "response.output_audio.delta":
      if let encoded = event["delta"] as? String, let data = Data(base64Encoded: encoded) {
        audioContinuation.yield(data)
      }
    case "response.function_call_arguments.done":
      guard let id = event["call_id"] as? String,
        let name = event["name"] as? String,
        let arguments = event["arguments"] as? String,
        let argumentData = arguments.data(using: .utf8),
        let value = try? JSONDecoder().decode(JSONValue.self, from: argumentData)
      else {
        eventContinuation.yield(.failed("Invalid voice tool call"))
        return
      }
      eventContinuation.yield(.toolCall(id: id, name: name, arguments: value))
    case "response.done":
      eventContinuation.yield(.speechFinished)
    case "error":
      let error = event["error"] as? [String: Any]
      let code = error?["code"] as? String ?? ""
      let message = error?["message"] as? String ?? "xAI realtime error"
      // Cancelling with nothing playing is routine — barge-in and interrupt race the response
      // lifecycle by design. Surfacing it as a failure puts a scary VOICE ERROR in the HUD for
      // a no-op.
      if code == "response_cancel_not_active"
        || message.localizedCaseInsensitiveContains("no active response")
      {
        return
      }
      eventContinuation.yield(.failed(message))
    default:
      break
    }
  }

  private func sessionUpdateJSON() throws -> String {
    let projectedTools = try tools.map { definition -> [String: Any] in
      [
        "type": "function",
        "name": definition.name,
        "description": definition.description,
        "parameters": try foundationObject(definition.inputSchema),
      ]
    }
    return try encodedJSONString([
      "type": "session.update",
      "session": [
        "voice": configuration.voice,
        "instructions": try instructionsWithContext(),
        "reasoning": ["effort": configuration.reasoningEffort],
        "turn_detection": [
          "type": "server_vad",
          // xAI documents 0.85 as the production default. The previous 0.60 setting made short
          // mechanical noises from interacting with the Mac look like user barge-in.
          "threshold": 0.85,
          // 450ms treated a mid-sentence breath as end-of-turn, so the assistant answered a
          // truncated request and then answered again when the rest arrived — heard as "it
          // responds twice and gets me wrong". 800ms trades a beat of response latency for
          // whole-utterance turns.
          "silence_duration_ms": 800,
          "prefix_padding_ms": 333,
        ],
        "audio": ["input": ["transcription": ["model": "grok-transcribe"]]],
        "tools": projectedTools,
        "resumption": ["enabled": true],
      ],
    ])
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

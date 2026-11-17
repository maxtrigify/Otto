import Foundation
import OttoSecurity
import OttoTools
import os

public struct GPTLiveConfiguration: Sendable {
  public var model: String
  public var voice: String
  public var instructions: String
  /// How long a conversation may sit silent before it is closed. GPT-Live bills for every second
  /// a session is open, whether or not anyone is speaking.
  public var idleLimit: Duration

  public init(
    model: String = "gpt-live-1",
    voice: String = "marin",
    instructions: String,
    idleLimit: Duration = .seconds(45)
  ) {
    self.model = model
    self.voice = voice
    self.instructions = instructions
    self.idleLimit = idleLimit
  }
}

public enum GPTLiveError: Error, LocalizedError, Sendable {
  case missingAPIKey
  case couldNotStart(String)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey: "Add an OpenAI API key in Voice settings to use GPT-Live."
    case .couldNotStart(let detail): "GPT-Live could not start: \(detail)"
    }
  }
}

/// The parts of the GPT-Live conversation that can be reasoned about without a connection.
public enum GPTLiveProtocol {
  /// GPT-Live sends a steady stream of audio, silence included. Otto's microphone is held back
  /// while Otto is speaking, so playing that silence would hold it back for good.
  public static func isSilence(_ pcm16: Data) -> Bool {
    pcm16.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for sample in samples where sample > 120 || sample < -120 { return false }
      return true
    }
  }

  /// What Otto reports back for the voice model to say. It accepts five hundred tokens at most,
  /// so a long answer is cut at a sentence rather than rejected.
  public static func speakable(_ text: String, limit: Int = 1_600) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let head = String(trimmed.prefix(limit))
    if let end = head.lastIndex(where: { ".!?".contains($0) }) {
      return String(head[...end])
    }
    return head
  }

  public static func startEvent(_ configuration: GPTLiveConfiguration) -> [String: Any] {
    [
      "type": "session.start",
      "event_id": "start",
      "session": [
        "model": configuration.model,
        "instructions": configuration.instructions,
        "audio": [
          "format": ["type": "audio/pcm", "rate": 24_000],
          "output": ["voice": configuration.voice],
        ],
        // Otto is the backend: the voice model converses, and hands every request to Otto.
        "delegation": ["type": "client"],
      ],
    ]
  }
}

/// A voice engine where OpenAI's GPT-Live holds the conversation and Otto does the work.
///
/// GPT-Live listens and speaks at once, acknowledges a request the moment it ends and keeps the
/// person company while the work is done. It does none of the work itself: each request is handed
/// to Otto ("client delegation"), where the same assistant that serves voice on this Mac, on the
/// person's own subscription and with Otto's tools, carries it out and reports back for GPT-Live
/// to say. The only thing billed is the open conversation, by the second, so the conversation is
/// closed once it has been quiet for a while and opened again when the person next speaks.
public actor GPTLiveProvider: StreamingVoiceProvider {
  public nonisolated let events: AsyncStream<VoiceProviderEvent>
  public nonisolated let audioOutput: AsyncStream<Data>
  public nonisolated let capabilities = VoiceProviderCapabilities.continuousFullDuplex

  private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LiveVoice")
  private let secrets: any SecretStore
  private let brain: any LocalVoiceThinking
  private let configuration: GPTLiveConfiguration
  private let screenReader: VoiceScreenReader?
  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let audioContinuation: AsyncStream<Data>.Continuation

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var brainTask: Task<Void, Never>?
  private var idleTask: Task<Void, Never>?
  private var quietTask: Task<Void, Never>?
  private var started = false
  private var closed = false
  /// Microphone audio that arrived while the conversation was still opening.
  private var waitingAudio: [Data] = []
  private var endpointer = LocalVoiceEndpointer()

  /// What the person has said since Otto was last handed a request.
  private var heard = ""
  private var delegation: String?
  private var reply = ""
  private var speaking = false
  /// Whether the person's current turn has been recorded as finished.
  private var committed = true
  private var lastActivity = ContinuousClock.now
  private var pendingTools: [String: CheckedContinuation<(text: String, isError: Bool), Never>] =
    [:]
  private var context: VoiceContext?
  private var sentContext: VoiceContext?
  private var eventSerial = 0
  private var opened = ContinuousClock.now

  public init(
    secrets: any SecretStore, brain: any LocalVoiceThinking, configuration: GPTLiveConfiguration,
    screenReader: VoiceScreenReader? = nil
  ) {
    self.screenReader = screenReader
    self.secrets = secrets
    self.brain = brain
    self.configuration = configuration
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var audioContinuation: AsyncStream<Data>.Continuation!
    audioOutput = AsyncStream { audioContinuation = $0 }
    self.audioContinuation = audioContinuation
  }

  public func connect(tools: [ToolDefinition]) async throws {
    guard let key = try await secrets.value(for: "openai.api-key"), !key.isEmpty else {
      throw GPTLiveError.missingAPIKey
    }
    try await brain.start(tools: tools) { [weak self] name, arguments in
      await self?.runTool(name: name, arguments: arguments) ?? ("Voice has stopped.", true)
    }
    let brainEvents = brain.events
    brainTask = Task { [weak self] in
      for await event in brainEvents {
        guard !Task.isCancelled else { break }
        await self?.handle(event)
      }
    }

    var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/live/sessions")!)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let socket = URLSession.shared.webSocketTask(with: request)
    self.socket = socket
    opened = .now
    socket.resume()
    try await send(GPTLiveProtocol.startEvent(configuration))
    receiveTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let message = try await socket.receive()
          let text: String
          switch message {
          case .string(let string): text = string
          case .data(let data): text = String(decoding: data, as: UTF8.self)
          @unknown default: continue
          }
          await self?.receive(text)
        } catch {
          await self?.socketEnded(error)
          break
        }
      }
    }
    // The conversation takes a couple of seconds to open. The person is told it is connected at
    // once and may start talking; what they say meanwhile is kept and sent the moment it opens.
    touch()
    watchForIdleness()
    eventContinuation.yield(.connected)
  }

  // MARK: Hearing

  public func sendAudio(_ data: Data) async throws {
    guard !closed else { return }
    // Only for showing, on screen, when the person is speaking: GPT-Live decides for itself
    // when a turn has ended.
    for event in endpointer.process(data) {
      switch event {
      case .speechStarted:
        touch()
        committed = false
        eventContinuation.yield(.speechStarted)
      case .speechEnded:
        touch()
        eventContinuation.yield(.speechStopped)
      }
    }
    guard started else {
      // About ten seconds at most; an opening that takes longer has failed.
      if waitingAudio.count < 1_000 { waitingAudio.append(data) }
      return
    }
    try await send([
      "type": "session.input_audio.append", "audio": data.base64EncodedString(),
    ])
  }

  // MARK: The conversation

  private func receive(_ text: String) async {
    guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
      let type = event["type"] as? String
    else { return }
    switch type {
    case "session.started":
      started = true
      let took = ContinuousClock.now - opened
      Self.logger.notice(
        "conversation opened in \(Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18, format: .fixed(precision: 1), privacy: .public)s"
      )
      await tellWhereThePersonIs()
      let waiting = waitingAudio
      waitingAudio = []
      for audio in waiting {
        try? await send([
          "type": "session.input_audio.append", "audio": audio.base64EncodedString(),
        ])
      }
    case "session.output_audio.delta":
      guard let encoded = event["delta"] as? String, let audio = Data(base64Encoded: encoded),
        !GPTLiveProtocol.isSilence(audio)
      else { return }
      touch()
      audioContinuation.yield(audio)
      noteSpeech()
    case "session.input_transcript.delta":
      touch()
      heard += event["delta"] as? String ?? ""
      eventContinuation.yield(.partialTranscript(heard.trimmingCharacters(in: .whitespaces)))
    case "session.output_transcript.delta":
      touch()
      commitHeard()
      speaking = true
      eventContinuation.yield(.speaking(event["delta"] as? String ?? ""))
      noteSpeech()
    case "session.delegation.created":
      guard let id = (event["delegation"] as? [String: Any])?["id"] as? String else { return }
      touch()
      let request = heard.trimmingCharacters(in: .whitespacesAndNewlines)
      Self.logger.notice("handed a request of \(request.count, privacy: .public) characters")
      commitHeard()
      heard = ""
      guard !request.isEmpty else { return }
      // A newer request replaces whatever Otto was still doing for the last one.
      if delegation != nil { await brain.interrupt() }
      delegation = id
      reply = ""
      eventContinuation.yield(.thinking)
      await ask(request)
    case "session.closed":
      Self.logger.notice("conversation closed by the service")
      await finish(failure: nil)
    case "error":
      let detail = (event["error"] as? [String: Any])?["message"] as? String ?? text
      Self.logger.error("service error: \(detail, privacy: .public)")
      if !started { await finish(failure: GPTLiveError.couldNotStart(detail).localizedDescription) }
    default:
      break
    }
  }

  /// Records what the person said as a finished turn, once, when the model starts to answer or
  /// hands the request on.
  private func commitHeard() {
    let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !said.isEmpty, !committed else { return }
    committed = true
    eventContinuation.yield(.finalTranscript(said))
  }

  /// GPT-Live never says when it has finished speaking, so a pause in its audio is taken as the
  /// end of what it was saying.
  private func noteSpeech() {
    quietTask?.cancel()
    quietTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      guard !Task.isCancelled else { return }
      await self?.speechWentQuiet()
    }
  }

  private func speechWentQuiet() {
    guard speaking else { return }
    speaking = false
    // The model answered before any words of the person's arrived as text; their turn still has
    // to be closed, or Otto goes on showing them as mid-sentence.
    if !committed {
      committed = true
      eventContinuation.yield(.finalTranscript(heard.trimmingCharacters(in: .whitespaces)))
    }
    // What the person said while the model was answering belongs to their next turn.
    heard = ""
    eventContinuation.yield(.speechFinished)
  }

  // MARK: Otto does the work

  private func ask(_ text: String) async {
    var message = text
    if let context, context != sentContext, let json = try? JSONEncoder().encode(context) {
      sentContext = context
      message =
        "Current Otto workspace, for reference only (do not read it out):\n"
        + String(decoding: json, as: UTF8.self) + "\n\n" + text
    }
    message = await VoiceScreen.attaching(screenReader, to: message)
    await brain.ask(message)
  }

  private func handle(_ event: LocalVoiceBrainEvent) async {
    switch event {
    case .text(let text):
      reply += text
    case .pause:
      // Words before a tool call are progress, not the answer; the voice model is already
      // keeping the person company, so they are kept for the final report.
      if !reply.isEmpty, !reply.hasSuffix(" ") { reply += " " }
    case .finished:
      await report(reply.isEmpty ? "Done." : reply)
    case .failed(let message):
      Self.logger.error("assistant failed: \(message, privacy: .public)")
      await report("That did not work. \(message)")
    }
  }

  /// Gives the voice model the outcome to say in its own words.
  private func report(_ text: String) async {
    guard let delegation else { return }
    self.delegation = nil
    reply = ""
    touch()
    try? await send([
      "type": "session.commentary.append",
      "event_id": nextEventID(),
      "delegation_id": delegation,
      "content": GPTLiveProtocol.speakable(text),
    ])
  }

  private func runTool(name: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
    let id = UUID().uuidString
    touch()
    return await withCheckedContinuation { continuation in
      pendingTools[id] = continuation
      eventContinuation.yield(.toolCall(id: id, name: name, arguments: arguments))
    }
  }

  public func sendToolResult(_ result: VoiceToolResult) async {
    guard let continuation = pendingTools.removeValue(forKey: result.callID) else { return }
    touch()
    let text =
      (try? JSONEncoder().encode(result.result)).map { String(decoding: $0, as: UTF8.self) }
      ?? "null"
    continuation.resume(returning: (text, result.isError))
  }

  public func updateContext(_ context: VoiceContext) async {
    let moved = context.screen != self.context?.screen
    self.context = context
    if moved { await tellWhereThePersonIs() }
  }

  /// The voice model knows nothing of the workspace, but it should know what the person is
  /// looking at, so that "this" and "here" make sense to it and it hands such requests on.
  private func tellWhereThePersonIs() async {
    guard started, !closed, let screen = context?.screen else { return }
    try? await send([
      "type": "session.thinking.append",
      "event_id": nextEventID(),
      "delegation_id": NSNull(),
      "content": screen.summary,
    ])
  }

  /// Something happened elsewhere in Otto that is worth saying, such as an agent finishing.
  public func sendNotification(_ text: String) async {
    guard started, !closed else { return }
    touch()
    try? await send([
      "type": "session.commentary.append",
      "event_id": nextEventID(),
      "delegation_id": NSNull(),
      "content": GPTLiveProtocol.speakable(text),
    ])
  }

  public func interrupt() async {
    // The voice model stops itself when the person speaks; only Otto's own work needs stopping.
    await brain.interrupt()
    eventContinuation.yield(.interrupted)
  }

  // MARK: Opening and closing

  private func touch() { lastActivity = .now }

  /// Closes a conversation nobody is using. Work in progress and anything being said count as
  /// use; an open microphone that hears nothing does not.
  private func watchForIdleness() {
    idleTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self, !Task.isCancelled else { return }
        if await self.hasGoneIdle() {
          await self.finish(failure: nil)
          return
        }
      }
    }
  }

  private func hasGoneIdle() -> Bool {
    guard delegation == nil, pendingTools.isEmpty, !speaking else { return false }
    return ContinuousClock.now - lastActivity >= configuration.idleLimit
  }

  private func socketEnded(_ error: any Error) async {
    guard !closed else { return }
    Self.logger.error(
      "connection lost: \(VoiceFailureText.technicalDetail(for: error), privacy: .public)")
    await finish(
      failure: started
        ? nil
        : GPTLiveError.couldNotStart(error.localizedDescription)
          .localizedDescription)
  }

  private func finish(failure: String?) async {
    guard !closed else { return }
    closed = true
    let open = ContinuousClock.now - opened
    Self.logger.notice(
      "conversation was open for \(open.components.seconds, privacy: .public)s")
    idleTask?.cancel()
    quietTask?.cancel()
    if started { try? await send(["type": "session.close", "event_id": nextEventID()]) }
    receiveTask?.cancel()
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    brainTask?.cancel()
    for (_, continuation) in pendingTools {
      continuation.resume(returning: ("Voice has stopped.", true))
    }
    pendingTools.removeAll()
    await brain.stop()
    if let failure { eventContinuation.yield(.failed(failure)) }
    eventContinuation.yield(.disconnected)
  }

  public func disconnect() async {
    await finish(failure: nil)
  }

  private func nextEventID() -> String {
    eventSerial += 1
    return "otto-\(eventSerial)"
  }

  private func send(_ event: [String: Any]) async throws {
    guard let socket else { return }
    let data = try JSONSerialization.data(withJSONObject: event)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }
}

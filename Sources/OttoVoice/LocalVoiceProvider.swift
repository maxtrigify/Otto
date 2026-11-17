import Foundation
import OttoTools
import os

public enum LocalVoiceError: Error, LocalizedError, Sendable {
  case recognizerMissing

  public var errorDescription: String? {
    switch self {
    case .recognizerMissing:
      "Install Parakeet in Voice settings to use voice on this Mac."
    }
  }
}

/// A voice engine that runs on this Mac and needs no API key.
///
/// Hearing is the Parakeet recogniser Otto already installs. Thinking is the person's own Claude
/// Code sign-in. Speaking is a voice on this Mac. Only the text of a request leaves the machine,
/// and only to the assistant the person already uses.
///
/// To the rest of Otto this is one more `VoiceProvider`: it reports the same events as the cloud
/// engines, and tool calls go through `VoiceSession` exactly as theirs do, so anything started by
/// voice is a real session the person can see, under the same confirmation rules.
public actor LocalVoiceProvider: StreamingVoiceProvider {
  public nonisolated let events: AsyncStream<VoiceProviderEvent>
  public nonisolated let audioOutput: AsyncStream<Data>
  public nonisolated var capabilities: VoiceProviderCapabilities { .turnBased }

  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let audioContinuation: AsyncStream<Data>.Continuation
  private let recognizer: any LocalSpeechRecognizing
  private let brain: any LocalVoiceThinking
  private let synthesizer: any LocalSpeechSynthesizing
  private let filter: (any LocalVoiceFiltering)?
  private let onlyThePersonsVoice: Bool
  private let screenReader: VoiceScreenReader?
  /// How closely a sound must match the learned voice to be taken for the person.
  static let voiceMatchNeeded: Float = 0.4

  private var endpointer: LocalVoiceEndpointer
  private var splitter = SpokenSentenceSplitter()
  private var brainTask: Task<Void, Never>?
  private var speechTask: Task<Void, Never>?
  private var pieces: AsyncStream<SpokenPiece>.Continuation?
  private var pendingTools: [String: CheckedContinuation<(text: String, isError: Bool), Never>] =
    [:]
  /// Raised whenever the person cuts in, so speech made for an older reply is thrown away.
  private var generation = 0
  private var connected = false
  private var context: VoiceContext?
  private var sentContext: VoiceContext?

  /// What the engine hears and decides, without the words themselves. A voice engine that
  /// stays silent is impossible to diagnose from the outside otherwise.
  private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")
  /// When the audio already handed to the speakers will have finished playing.
  private var playbackEnds: ContinuousClock.Instant?
  /// Whether the last thing Otto said was a question, which makes a one-word answer meaningful.
  private var askedQuestion = false
  /// Whether the assistant has said anything yet in answer to the latest request.
  private var replyHasBegun = true
  /// The start of a sentence the person has not finished, kept until the rest arrives.
  private var heldWords: String?
  private var lastAcknowledgement: String?
  private var holds = 0
  /// When the person stopped speaking, for measuring how long they waited to hear anything.
  private var requestEnded: ContinuousClock.Instant?
  private var buffersSinceReport = 0
  private var peakSinceReport = 0.0
  private var secondsSinceReport = 0.0

  private enum SpokenPiece: Sendable {
    case text(String, generation: Int)
    /// Words whose audio has already been made.
    case ready(String, audio: Data, generation: Int)
    case end(generation: Int)
  }

  public init(
    recognizer: any LocalSpeechRecognizing,
    brain: any LocalVoiceThinking,
    synthesizer: any LocalSpeechSynthesizing,
    filter: (any LocalVoiceFiltering)? = nil,
    onlyThePersonsVoice: Bool = true,
    endpointing: LocalVoiceEndpointer.Configuration = .init(),
    screenReader: VoiceScreenReader? = nil
  ) {
    self.screenReader = screenReader
    self.recognizer = recognizer
    self.brain = brain
    self.synthesizer = synthesizer
    self.filter = filter
    self.onlyThePersonsVoice = onlyThePersonsVoice
    endpointer = LocalVoiceEndpointer(configuration: endpointing)
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var audioContinuation: AsyncStream<Data>.Continuation!
    audioOutput = AsyncStream { audioContinuation = $0 }
    self.audioContinuation = audioContinuation
  }

  public func connect(tools: [ToolDefinition]) async throws {
    try await recognizer.prepare()
    try await brain.start(tools: tools) { [weak self] name, arguments in
      await self?.runTool(name: name, arguments: arguments)
        ?? ("Voice has stopped.", true)
    }
    let brainEvents = brain.events
    brainTask = Task { [weak self] in
      for await event in brainEvents {
        guard !Task.isCancelled else { break }
        await self?.handle(event)
      }
    }
    let (stream, continuation) = AsyncStream<SpokenPiece>.makeStream()
    pieces = continuation
    speechTask = Task { [weak self] in
      for await piece in stream {
        guard !Task.isCancelled else { break }
        await self?.speak(piece)
      }
    }
    connected = true
    Self.logger.info("connected with \(tools.count, privacy: .public) tools")
    eventContinuation.yield(.connected)
  }

  public func sendAudio(_ data: Data) async throws {
    guard connected else { return }
    // The last word Otto spoke is still ringing in the room, and in the microphone, for a moment
    // after playback stops. Sound in that moment is not the person starting a request.
    let now = ContinuousClock.now
    if let playbackEnds, now >= playbackEnds, now < playbackEnds + .milliseconds(500),
      !endpointer.isCapturing
    {
      endpointer.reset()
      return
    }
    let events = endpointer.process(data)
    buffersSinceReport += 1
    peakSinceReport = max(peakSinceReport, endpointer.lastLevel)
    secondsSinceReport +=
      Double(data.count / MemoryLayout<Int16>.size) / endpointer.configuration.sampleRate
    if secondsSinceReport >= 3 {
      Self.logger.info(
        "mic: \(self.buffersSinceReport, privacy: .public) buffers, peak \(self.peakSinceReport, format: .fixed(precision: 4), privacy: .public), needs \(self.endpointer.lastThreshold, format: .fixed(precision: 4), privacy: .public), capturing \(self.endpointer.isCapturing, privacy: .public)"
      )
      buffersSinceReport = 0
      peakSinceReport = 0
      secondsSinceReport = 0
    }
    for event in events {
      switch event {
      case .speechStarted:
        Self.logger.info("speech started")
        // Whatever Otto was saying or doing for the previous request is now out of date.
        await cancelReply()
        eventContinuation.yield(.speechStarted)
      case .speechEnded(let audio, let deliberate):
        Self.logger.info(
          "speech ended after \(Double(audio.count) / 48_000, format: .fixed(precision: 1), privacy: .public)s"
        )
        eventContinuation.yield(.speechStopped)
        Task { await self.finishRequest(audio, deliberate: deliberate) }
      }
    }
  }

  private func finishRequest(_ audio: Data, deliberate: Bool) async {
    let began = ContinuousClock.now
    guard endpointer.isLongEnough(audio) else {
      eventContinuation.yield(.finalTranscript(""))
      return
    }
    let sampleRate = endpointer.configuration.sampleRate
    var samples = LocalVoiceEndpointer.floatSamples(audio)
    var heardRate = Int(sampleRate)
    var confident = false
    var score: Float?

    // First: is there speech in it at all, and is it the person Otto belongs to? A request made
    // with the Talk key held is theirs by definition and is never turned away.
    let voiced = await filter?.speech(
      in: LocalVoiceEndpointer.resampledTo16k(samples, from: sampleRate))
    if let voiced {
      guard voiced.count >= 4_000 else {
        Self.logger.info("ignored: no speech in it")
        eventContinuation.yield(.finalTranscript(""))
        return
      }
      samples = voiced
      heardRate = 16_000
      if !deliberate, onlyThePersonsVoice, let matched = await filter?.match(voiced) {
        score = matched
        let score = matched
        Self.logger.info(
          "voice match \(score, format: .fixed(precision: 2), privacy: .public), needs \(Self.voiceMatchNeeded, format: .fixed(precision: 2), privacy: .public)"
        )
        guard score >= Self.voiceMatchNeeded else {
          eventContinuation.yield(.finalTranscript(""))
          // Close to the person's voice and a real sentence: more likely a poor capture of them
          // than a stranger, so say so rather than staying silent. A clear stranger gets nothing.
          if score >= Self.voiceMatchNeeded - 0.1, voiced.count >= 16_000 { sayMisheard() }
          return
        }
        confident = score >= Self.voiceMatchNeeded + 0.15
      }
    }

    let heard: String
    do {
      heard = try await recognizer.text(samples: samples, sampleRate: heardRate)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      Self.logger.error(
        "transcription failed: \(VoiceFailureText.technicalDetail(for: error), privacy: .public)")
      eventContinuation.yield(.finalTranscript(""))
      eventContinuation.yield(.failed(VoiceFailureText.message(for: error)))
      return
    }
    let took = ContinuousClock.now - began
    Self.logger.info(
      "heard \(heard.count, privacy: .public) characters, \(Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18, format: .fixed(precision: 1), privacy: .public)s after the person stopped"
    )
    // What was heard is only written down by the development build, where it is the one way to
    // tell a mishearing from a misunderstanding. Released builds never log a person's words.
    if Self.logsWords { Self.logger.info("heard: \(heard, privacy: .public)") }
    let text = heldWords.map { $0 + " " + heard } ?? heard
    heldWords = nil
    holds += 1
    // People pause in the middle of a sentence. If they have already carried on talking, or what
    // was heard plainly trails off, the rest is on its way: answering now would talk over them
    // and act on half a request.
    let ending = SpokenRequest.ending(of: text)
    if !text.isEmpty, endpointer.isCapturing || ending != .finished {
      Self.logger.info("waiting for the rest of an unfinished sentence")
      // Half a sentence is still the person's voice, and still worth learning from.
      if let voiced, deliberate || confident { await filter?.learn(voiced) }
      heldWords = text
      let hold = holds
      eventContinuation.yield(.finalTranscript(""))
      // A sentence that plainly leads on is worth a long wait. One that merely lacks a full
      // stop is probably unfinished, but may be all there is, so it is not kept waiting long.
      let patience: Duration = ending == .leadsOn ? .seconds(3) : .milliseconds(1300)
      Task { [weak self] in
        try? await Task.sleep(for: patience)
        await self?.stopWaiting(hold: hold)
      }
      return
    }
    // A lone syllable is what a cough, a door or a neighbouring conversation turns into. From
    // an unknown voice it only means something as the answer to a question Otto has just
    // asked. From the person themselves, one word ("Hello", "Stop") is a real thing to say.
    let isThePerson = deliberate || score != nil
    guard Self.isRequest(text, answeringQuestion: askedQuestion, fromThePerson: isThePerson)
    else {
      Self.logger.info("ignored as too short to be a request")
      eventContinuation.yield(.finalTranscript(""))
      return
    }
    // Otto's picture of the voice comes only from sentences that were certainly the person's:
    // ones spoken with the key held, and ones that already matched strongly.
    if let voiced, deliberate || confident { await filter?.learn(voiced) }
    await send(text)
  }

  /// The rest of the sentence never came, so what was heard is the whole request after all.
  private func stopWaiting(hold: Int) async {
    guard hold == holds, let words = heldWords else { return }
    // They are speaking now: this will be joined to what they are saying when they finish. If
    // what the microphone is picking up turns out not to be them, look again shortly, so the
    // held words are never left to be joined to some unrelated request later.
    guard !endpointer.isCapturing else {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(1500))
        await self?.stopWaiting(hold: hold)
      }
      return
    }
    heldWords = nil
    await send(words)
  }

  private func send(_ text: String) async {
    if Self.logsWords { Self.logger.info("asked: \(text, privacy: .public)") }
    eventContinuation.yield(.finalTranscript(text))
    // "Go to sleep" is handled by the session itself and must not also reach the assistant.
    guard !text.isEmpty, !SpokenVoiceLifecycle.isSleepCommand(text) else { return }
    eventContinuation.yield(.thinking)
    let answering = askedQuestion
    replyHasBegun = false
    requestEnded = .now
    await ask(text)
    if let line = VoiceAcknowledgement.line(
      for: text, answeringQuestion: answering, avoiding: lastAcknowledgement)
    {
      lastAcknowledgement = line
      acknowledge(with: line)
    }
  }

  /// Says a word or two the moment a request has been heard, unless the assistant is already
  /// answering. The assistant needs a second or more to produce its first sentence, and silence
  /// for that long reads as not having been heard.
  private func acknowledge(with line: String) {
    let made = generation
    Task { [weak self, synthesizer] in
      async let audio = try? await synthesizer.speech(for: line)
      // A reply that starts within this time needs no acknowledgement in front of it.
      try? await Task.sleep(for: .milliseconds(350))
      guard let audio = await audio else { return }
      await self?.sayAcknowledgement(line, audio: audio, made: made)
    }
  }

  private func sayAcknowledgement(_ line: String, audio: Data, made: Int) {
    guard made == generation, !replyHasBegun else { return }
    // Never over the person, and never late: an acknowledgement that arrives after a pause of
    // its own, as when the voice is still loading, is worse than none.
    guard !endpointer.isCapturing, let requestEnded,
      ContinuousClock.now - requestEnded < .milliseconds(1500)
    else { return }
    pieces?.yield(.ready(line, audio: audio, generation: made))
  }

  private static let misheardLines = [
    "Sorry, I missed that. Could you say it again?",
    "Sorry, I didn't quite catch that.",
    "Pardon me, I missed that. Once more?",
  ]

  private func sayMisheard() {
    guard let line = Self.misheardLines.randomElement() else { return }
    pieces?.yield(.text(line, generation: generation))
    pieces?.yield(.end(generation: generation))
  }

  /// Only the development build writes down what was said, because there it is the one way to
  /// review a conversation. Released builds never log a person's words or Otto's.
  private static let logsWords = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

  /// Sounds people make without meaning anything by them.
  private static let fillers: Set<String> = [
    "um", "uh", "er", "erm", "ah", "oh", "hm", "hmm", "mm", "mhm", "huh",
  ]

  static func isRequest(_ text: String, answeringQuestion: Bool, fromThePerson: Bool = false)
    -> Bool
  {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    guard let first = words.first else { return false }
    if words.count >= 2 || answeringQuestion { return true }
    return fromThePerson && !fillers.contains(first.lowercased())
  }

  /// Sends words to the assistant, with a fresh picture of the workspace when it has changed.
  private func ask(_ text: String) async {
    var message = text
    if let context, context != sentContext,
      let json = try? JSONEncoder().encode(context)
    {
      sentContext = context
      message =
        "Current Otto workspace, for reference only (do not read it out):\n"
        + String(decoding: json, as: UTF8.self) + "\n\n" + text
    }
    message = await VoiceScreen.attaching(screenReader, to: message)
    await brain.ask(message)
  }

  private func handle(_ event: LocalVoiceBrainEvent) {
    switch event {
    case .text(let text):
      replyHasBegun = true
      for piece in splitter.append(text) { pieces?.yield(.text(piece, generation: generation)) }
    case .pause:
      // Words said before a tool call are spoken while the tool runs, not after it.
      for piece in splitter.flush() { pieces?.yield(.text(piece, generation: generation)) }
    case .finished:
      Self.logger.info("assistant finished its reply")
      for piece in splitter.flush() { pieces?.yield(.text(piece, generation: generation)) }
      pieces?.yield(.end(generation: generation))
    case .failed(let message):
      Self.logger.error("assistant failed: \(message, privacy: .public)")
      splitter = SpokenSentenceSplitter()
      eventContinuation.yield(.failed(message))
    }
  }

  private func speak(_ piece: SpokenPiece) async {
    switch piece {
    case .end(let made):
      guard made == generation else { return }
      eventContinuation.yield(.speechFinished)
    case .ready(let text, let audio, let made):
      play(text, audio: audio, made: made)
    case .text(let text, let made):
      guard made == generation else { return }
      let audio: Data
      do {
        audio = try await synthesizer.speech(for: text)
      } catch {
        Self.logger.error(
          "speech failed: \(VoiceFailureText.technicalDetail(for: error), privacy: .public)")
        return
      }
      play(text, audio: audio, made: made)
    }
  }

  private func play(_ text: String, audio: Data, made: Int) {
    // The person may have cut in while this piece was being made.
    guard made == generation else { return }
    if let requestEnded {
      let waited = ContinuousClock.now - requestEnded
      self.requestEnded = nil
      Self.logger.info(
        "first sound \(Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18, format: .fixed(precision: 1), privacy: .public)s after the request was heard"
      )
    }
    Self.logger.info(
      "speaking \(text.count, privacy: .public) characters, \(Double(audio.count) / 48_000, format: .fixed(precision: 1), privacy: .public)s of audio"
    )
    if Self.logsWords { Self.logger.info("said: \(text, privacy: .public)") }
    eventContinuation.yield(.speaking(text + " "))
    askedQuestion = text.hasSuffix("?")
    let duration = Duration.milliseconds(audio.count * 1000 / 48_000)
    playbackEnds = max(playbackEnds ?? .now, .now) + duration
    // Half-second slices, so stopping playback takes effect quickly.
    let slice = 24_000
    var offset = 0
    while offset < audio.count {
      let end = min(offset + slice, audio.count)
      audioContinuation.yield(audio.subdata(in: offset..<end))
      offset = end
    }
  }

  private func runTool(name: String, arguments: JSONValue) async -> (text: String, isError: Bool) {
    let id = UUID().uuidString
    Self.logger.info("tool requested: \(name, privacy: .public)")
    return await withCheckedContinuation { continuation in
      pendingTools[id] = continuation
      eventContinuation.yield(.toolCall(id: id, name: name, arguments: arguments))
    }
  }

  public func sendToolResult(_ result: VoiceToolResult) async {
    guard let continuation = pendingTools.removeValue(forKey: result.callID) else { return }
    Self.logger.info("tool \(result.isError ? "failed" : "finished", privacy: .public)")
    var text =
      (try? JSONEncoder().encode(result.result)).map { String(decoding: $0, as: UTF8.self) }
      ?? "null"
    if let instruction = result.responseInstruction { text += "\n\n" + instruction }
    continuation.resume(returning: (text, result.isError))
  }

  public func sendNotification(_ text: String) async {
    guard connected else { return }
    await ask(text)
  }

  public func updateContext(_ context: VoiceContext) async {
    self.context = context
  }

  public func interrupt() async {
    await cancelReply()
    eventContinuation.yield(.interrupted)
  }

  private func cancelReply() async {
    generation += 1
    splitter = SpokenSentenceSplitter()
    for (_, continuation) in pendingTools {
      continuation.resume(returning: ("Cancelled because the person spoke.", true))
    }
    pendingTools.removeAll()
    await brain.interrupt()
  }

  public func disconnect() async {
    guard connected else { return }
    connected = false
    generation += 1
    endpointer.reset()
    brainTask?.cancel()
    speechTask?.cancel()
    pieces?.finish()
    pieces = nil
    for (_, continuation) in pendingTools {
      continuation.resume(returning: ("Voice has stopped.", true))
    }
    pendingTools.removeAll()
    await brain.stop()
    eventContinuation.yield(.disconnected)
  }
}

/// The word or two Otto says the instant it has heard a request, before the answer is ready.
///
/// They are chosen by the shape of what was said, because nothing is yet known about the answer:
/// a question gets a thinking sound, an instruction gets assent. Anything that already has a
/// quick answer of its own, such as a greeting, thanks or a one-word reply, gets nothing.
public enum VoiceAcknowledgement {
  static let forQuestions = ["Hmm.", "Hmm, let me see.", "Let me think."]
  static let forInstructions = ["Right.", "Sure.", "Of course.", "Okay."]
  static let forRemarks = ["Mm.", "I see."]

  private static let questionOpeners: Set<String> = [
    "what", "whats", "why", "how", "when", "where", "who", "which", "is", "are", "was", "were",
    "do", "does", "did", "can", "could", "would", "should", "will", "have", "has", "any",
  ]
  private static let instructionOpeners: Set<String> = [
    "open", "show", "start", "create", "make", "send", "tell", "ask", "find", "check", "run",
    "stop", "close", "go", "take", "bring", "add", "write", "search", "look", "get", "give",
    "read", "set", "switch", "launch", "spin", "put", "move", "delete", "remove", "please",
    "use", "summarise", "summarize", "reply", "draft", "play", "pause", "rename", "save",
  ]
  private static let needsNothing: Set<String> = [
    "hello", "hi", "hey", "thanks", "thank", "cheers", "yes", "yeah", "yep", "no", "nope", "okay",
    "ok", "bye", "goodbye", "morning", "evening", "night", "sorry", "great", "nice", "perfect",
  ]

  /// "Can you open", "could you start", "would you send": a request for something to be done,
  /// phrased as a question out of politeness.
  private static let politeOpeners: Set<String> = ["can", "could", "would", "will"]
  private static let softeners: Set<String> = [
    "you", "we", "just", "please", "otto", "now", "also",
  ]

  public static func line(
    for request: String, answeringQuestion: Bool, avoiding last: String? = nil,
    pick: (Int) -> Int = { Int.random(in: 0..<$0) }
  ) -> String? {
    let words = request.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
      .map { $0.replacingOccurrences(of: "'", with: "") }
    // A short answer to Otto's own question, or a pleasantry, is answered at once.
    guard let first = words.first, words.count >= 2, !answeringQuestion,
      !needsNothing.contains(first)
    else { return nil }
    // The first word that carries meaning, past "can you just please".
    let meaning = words.first { !politeOpeners.contains($0) && !softeners.contains($0) }
    let isInstruction =
      instructionOpeners.contains(first)
      || (politeOpeners.contains(first) && meaning.map(instructionOpeners.contains) == true)
      || (softeners.contains(first) && meaning.map(instructionOpeners.contains) == true)
    var bank: [String]
    if isInstruction {
      bank = forInstructions
    } else if questionOpeners.contains(first) || request.hasSuffix("?") {
      bank = forQuestions
    } else if words.count >= 3 {
      bank = forRemarks
    } else {
      // Two words that are neither an instruction nor a question need no acknowledgement.
      return nil
    }
    // The same word twice running sounds like a recording.
    if let last, bank.count > 1 { bank.removeAll { $0 == last } }
    return bank[max(0, min(bank.count - 1, pick(bank.count)))]
  }
}

/// Whether what was heard is a whole request or the first part of one.
public enum SpokenRequest {
  /// Words a sentence does not end on. Hearing one last means the person paused mid-thought.
  private static let leadsOn: Set<String> = [
    "a", "an", "the", "and", "or", "but", "so", "then", "because", "with", "using", "called",
    "named", "to", "for", "of", "from", "into", "about", "that", "which", "my", "your", "our",
    "is", "are", "its", "like", "than", "if", "when", "while", "also", "um", "uh", "er",
  ]

  public enum Ending: Equatable, Sendable {
    /// A whole sentence.
    case finished
    /// It ends on a word no sentence ends on: the person paused mid-thought.
    case leadsOn
    /// No full stop or question mark. The recogniser punctuates a sentence that sounds
    /// complete, so one it leaves open usually is: "Go ahead and um give".
    case open
  }

  public static func ending(of text: String) -> Ending {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    guard words.count >= 2, let last = words.last else { return .finished }
    if trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { return .finished }
    if leadsOn.contains(String(last)) { return .leadsOn }
    return trimmed.hasSuffix(".") ? .finished : .open
  }

  public static func trailsOff(_ text: String) -> Bool { ending(of: text) == .leadsOn }
}

/// Reads what is in front of the person at the moment they speak.
public typealias VoiceScreenReader = @Sendable () async -> String?

public enum VoiceScreen {
  /// Adds what is on screen to a request, so "summarise this" needs no second step to find out
  /// what "this" is. Reading it is given a moment and no more: a request is never held up for it.
  public static func attaching(
    _ reader: VoiceScreenReader?, to request: String, patience: Duration = .milliseconds(700)
  ) async -> String {
    guard let reader else { return request }
    // Not a task group: a group waits for every child before returning, and a read that does
    // not stop when cancelled would hold the request for as long as it took.
    let seen: String? = await withCheckedContinuation { continuation in
      let first = FirstAnswer()
      Task {
        let read = await reader()
        if first.claim() { continuation.resume(returning: read) }
      }
      Task {
        try? await Task.sleep(for: patience)
        if first.claim() { continuation.resume(returning: nil) }
      }
    }
    guard let seen, !seen.isEmpty else { return request }
    return request
      + "\n\nWhat is on the user's screen right now, for reference only (do not read it out unless asked):\n"
      + seen
  }

  private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
      lock.withLock {
        if taken { return false }
        taken = true
        return true
      }
    }
  }

  /// Keeps what was read short enough to send with every request.
  public static func excerpt(_ text: String, limit: Int = 2_400) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return String(trimmed.prefix(limit)) + " …"
  }
}

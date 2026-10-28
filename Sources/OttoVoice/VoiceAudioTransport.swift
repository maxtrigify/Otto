@preconcurrency import AVFoundation
import Foundation

public protocol StreamingVoiceProvider: VoiceProvider {
  var audioOutput: AsyncStream<Data> { get }
  func sendAudio(_ data: Data) async throws
}

/// A playback-only realtime connection used by Settings previews. Preview sessions project no
/// tools and never start a microphone transport.
public protocol VoicePreviewProvider: VoiceProvider {
  var audioOutput: AsyncStream<Data> { get }
  func sendPreviewText(_ text: String) async throws
}

public protocol VoiceAudioTransport: Sendable {
  func setSpeechActivityHandler(_ handler: (@Sendable () -> Void)?) async
  func setInputMetricsHandler(_ handler: (@Sendable (VoiceAudioInputMetrics) -> Void)?) async
  func startInput(_ handler: @escaping @Sendable (Data) -> Void) async throws
  func setInputEnabled(_ enabled: Bool) async
  func play(_ data: Data) async throws
  func waitForPlaybackToFinish(timeout: Duration) async
  func stopPlayback() async
  func stop() async
}

extension VoiceAudioTransport {
  public func setSpeechActivityHandler(_ handler: (@Sendable () -> Void)?) async {}
  public func setInputMetricsHandler(_ handler: (@Sendable (VoiceAudioInputMetrics) -> Void)?) async
  {}
  public func waitForPlaybackToFinish(timeout: Duration) async {}
  public func setInputEnabled(_ enabled: Bool) async {}
}

public struct VoiceAudioInputMetrics: Sendable, Equatable {
  public var inputFrames: Int
  public var outputBytes: Int
  public var rootMeanSquare: Double
  public var inputName: String
  public var sampleRate: Double
  public var channelCount: Int

  public init(
    inputFrames: Int,
    outputBytes: Int,
    rootMeanSquare: Double,
    inputName: String = "System default microphone",
    sampleRate: Double = 0,
    channelCount: Int = 0
  ) {
    self.inputFrames = inputFrames
    self.outputBytes = outputBytes
    self.rootMeanSquare = rootMeanSquare
    self.inputName = inputName
    self.sampleRate = sampleRate
    self.channelCount = channelCount
  }
}

enum VoiceInputForwardingDecision: Equatable {
  case silence
  case forward
  case bufferForBargeIn
  case dropPlaybackLeakage
}

enum VoiceInputForwardingPolicy {
  static func decide(
    manualInputEnabled: Bool,
    playbackActive: Bool,
    interruptionReported: Bool,
    classifierAllowsSpeech: Bool
  ) -> VoiceInputForwardingDecision {
    guard manualInputEnabled else { return .silence }
    // Normal listening must never depend on Sound Analysis. Its broad music/singing classifier
    // can stay confidently wrong for an entire conversation, which previously left a healthy
    // realtime connection receiving no microphone audio. The classifier is useful only while
    // Otto is playing audio, where it helps distinguish a real barge-in from speaker leakage.
    if !playbackActive || interruptionReported { return .forward }
    return classifierAllowsSpeech ? .bufferForBargeIn : .dropPlaybackLeakage
  }
}

public enum VoiceAudioError: Error, LocalizedError, Sendable {
  case microphoneDenied
  case unavailableInputFormat
  case conversionFailed
  case invalidProviderAudio
  case audioEngineStartFailed(String)
  case audioOutputUnavailable

  public var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      "Microphone access is required to use voice. Enable it in System Settings > Privacy & Security."
    case .unavailableInputFormat:
      "The selected microphone does not expose a usable audio format."
    case .conversionFailed:
      "Otto could not convert microphone audio for the voice provider."
    case .invalidProviderAudio:
      "The voice provider returned an invalid audio buffer."
    case .audioEngineStartFailed(let message):
      "Otto could not start audio playback: \(message)"
    case .audioOutputUnavailable:
      "No audio output device is available. Connect speakers or headphones to use voice."
    }
  }
}

public protocol MicrophoneAuthorizing: Sendable {
  func requestAccess() async -> Bool
}

public struct SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
  public init() {}

  public func requestAccess() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      true
    case .notDetermined:
      await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      false
    @unknown default:
      false
    }
  }
}

/// Captures the default microphone and plays provider PCM using one AVAudioEngine.
/// Provider audio is signed 16-bit, mono PCM at 24 kHz.
public final class AVFoundationVoiceAudioTransport: @unchecked Sendable, VoiceAudioTransport {
  public static let providerSampleRate = 24_000.0

  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private let authorizer: any MicrophoneAuthorizing
  /// AVAudioEngine and AVAudioPlayerNode are not safe to mutate concurrently. In particular,
  /// `AVAudioPlayerNode.play()` raises an Objective-C exception (rather than a Swift error) when
  /// it races an engine stop or graph reconfiguration. All graph/player mutations live here.
  private let audioQueue = DispatchQueue(label: "io.openotto.voice.audio-graph")
  private let lock = NSLock()
  /// Provider audio arrives as interleaved 16-bit PCM and is converted to this standard float
  /// format before scheduling, so the engine graph only ever sees a format every mixer accepts.
  private let playbackFormat: AVAudioFormat
  /// Set once the player is attached and connected. Touching the output device is deferred to
  /// the first audio operation so constructing the transport (which happens during app launch)
  /// cannot fail on Macs without a usable output device.
  private var playbackGraphReady = false
  private var inputHandler: (@Sendable (Data) -> Void)?
  private var speechActivityHandler: (@Sendable () -> Void)?
  private var inputMetricsHandler: (@Sendable (VoiceAudioInputMetrics) -> Void)?
  private var sinkNode: AVAudioSinkNode?
  private var tapInstalled = false
  private var voiceProcessingActive = false
  private var loudInputBufferCount = 0
  private var interruptionReported = false
  private var metricBufferCount = 0
  private var playbackEpoch: UInt64 = 0
  private var pendingPlaybackBuffers = 0
  private var playbackActive = false
  private var manualInputEnabled = true
  private var soundAnalyzer: VoiceInputSoundAnalyzer?
  private var soundGate = VoiceInputSoundGate()
  private var inputPreRoll: [Data] = []
  private var inputPreRollBytes = 0

  private static let speechRMSFloor = 0.025
  // A click or trackpad tap can span a couple of audio callbacks. Requiring a continuous run of
  // voiced audio keeps direct, low-latency barge-in without treating ordinary app interaction as
  // speech. At the usual 48 kHz / 512-frame input this is roughly 85 ms.
  private static let speechBuffersRequired = 8
  private static let inputPreRollByteLimit = Int(providerSampleRate * 2 * 0.65)

  public init(authorizer: any MicrophoneAuthorizing = SystemMicrophoneAuthorizer()) {
    self.authorizer = authorizer
    playbackFormat = AVAudioFormat(
      standardFormatWithSampleRate: Self.providerSampleRate,
      channels: 1
    )!
    // Deliberately no graph work here: see `preparePlaybackGraph`.
  }

  /// Replaces the audio engine wholesale. Toggling voice processing off and on again across
  /// sessions on one AVAudioEngine instance is a documented source of silent-microphone bugs,
  /// and deallocating the engine is the only guaranteed release of the voice-processing IO unit
  /// (and with it the system-wide audio ducking). Must run on `audioQueue`.
  private func rebuildEngine() {
    engine = AVAudioEngine()
    player = AVAudioPlayerNode()
    playbackGraphReady = false
  }

  /// Attaches the player to the mixer on first use. Must run on `audioQueue`.
  ///
  /// `AVAudioEngine.mainMixerNode` implicitly wires the mixer to the output device, and
  /// AVFoundation raises an Objective-C exception rather than returning an error when that
  /// device is missing or reports an unusable format (0 Hz / 0 channels). Before this check
  /// Otto did that work inside `init`, which runs at launch, so an affected Mac could never
  /// open the app. Now the failure is reported as a voice error and everything else keeps
  /// working.
  private func preparePlaybackGraph() throws {
    guard !playbackGraphReady else { return }
    let hardwareFormat: AVAudioFormat
    do {
      hardwareFormat = try ObjectiveCExceptions.catching {
        engine.outputNode.outputFormat(forBus: 0)
      }
    } catch {
      throw VoiceAudioError.audioEngineStartFailed(error.localizedDescription)
    }
    guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
      throw VoiceAudioError.audioOutputUnavailable
    }
    do {
      try ObjectiveCExceptions.catching {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
      }
    } catch {
      if player.engine != nil { engine.detach(player) }
      throw VoiceAudioError.audioEngineStartFailed(error.localizedDescription)
    }
    playbackGraphReady = true
  }

  /// Stops the player when it is part of a graph. Must run on `audioQueue`.
  private func stopPlayerIfAttached() {
    guard playbackGraphReady, player.engine != nil else { return }
    try? ObjectiveCExceptions.catching { player.stop() }
  }

  public func setSpeechActivityHandler(_ handler: (@Sendable () -> Void)?) async {
    lock.withLock { speechActivityHandler = handler }
  }

  public func setInputMetricsHandler(
    _ handler: (@Sendable (VoiceAudioInputMetrics) -> Void)?
  ) async {
    lock.withLock { inputMetricsHandler = handler }
  }

  public func setInputEnabled(_ enabled: Bool) async {
    lock.withLock {
      manualInputEnabled = enabled
      soundGate.reset()
      clearInputPreRoll()
    }
  }

  public func startInput(_ handler: @escaping @Sendable (Data) -> Void) async throws {
    guard await authorizer.requestAccess() else { throw VoiceAudioError.microphoneDenied }

    let needsSetup = lock.withLock {
      inputHandler = handler
      guard !tapInstalled else { return false }
      // Reserve setup so a concurrent caller cannot install a second tap.
      tapInstalled = true
      return true
    }
    guard needsSetup else { return }

    do {
      try await performAudioOperation { [self] in
        try self.preparePlaybackGraph()
        try self.installInputGraph()
      }
    } catch {
      await performAudioOperation {
        if let sink = self.lock.withLock({ () -> AVAudioSinkNode? in
          defer { self.sinkNode = nil }
          return self.sinkNode
        }) {
          try? ObjectiveCExceptions.catching {
            self.engine.disconnectNodeInput(sink)
            self.engine.detach(sink)
          }
        }
      }
      lock.withLock {
        tapInstalled = false
        inputHandler = nil
        voiceProcessingActive = false
      }
      throw error
    }
  }

  /// Wires the microphone into the engine and starts it. Must run on `audioQueue`.
  ///
  /// Every AVFoundation call here can raise an Objective-C exception for an unusable input
  /// device or format, so the whole block runs under the exception guard and reports a voice
  /// error instead of terminating the app.
  private func installInputGraph() throws {
    do {
      try ObjectiveCExceptions.catching {
        let input = self.engine.inputNode
        var voiceProcessingActive = false
        // Voice processing supplies acoustic echo cancellation so Otto does not transcribe its own
        // speaker output or nearby nonvoice audio as a new user turn.
        do {
          if !input.isVoiceProcessingEnabled {
            try input.setVoiceProcessingEnabled(true)
          }
          input.isVoiceProcessingInputMuted = false
          input.isVoiceProcessingBypassed = false
          // AGC is deliberately OFF: macOS automatic gain control adjusts the system-wide
          // microphone input level and has been observed dragging it far enough down that
          // server-side voice detection stops triggering — persisting even after Otto quits.
          input.isVoiceProcessingAGCEnabled = false
          // Voice processing defaults to call-style ducking that noticeably quiets every other
          // app's audio (music, videos) system-wide. Echo cancellation still works at the
          // minimum ducking level, so keep the rest of the Mac at normal volume.
          input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
              enableAdvancedDucking: false,
              duckingLevel: .min
            )
          voiceProcessingActive = input.isVoiceProcessingEnabled
        } catch {
          voiceProcessingActive = false
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
          throw VoiceAudioError.unavailableInputFormat
        }
        let soundAnalyzer = try? VoiceInputSoundAnalyzer(format: format) {
          [weak self] observation in
          self?.handleSoundObservation(observation)
        }
        let sink = AVAudioSinkNode { [weak self, format] _, frameCount, inputData in
          guard
            let self,
            let buffer = AVAudioPCMBuffer(
              pcmFormat: format,
              bufferListNoCopy: inputData,
              deallocator: nil
            )
          else { return noErr }
          buffer.frameLength = frameCount
          self.consumeInput(buffer)
          return noErr
        }
        self.engine.attach(sink)
        self.engine.connect(input, to: sink, format: format)
        self.lock.withLock {
          self.sinkNode = sink
          self.voiceProcessingActive = voiceProcessingActive
          self.soundAnalyzer = soundAnalyzer
          self.soundGate.reset()
          self.clearInputPreRoll()
        }
        self.engine.prepare()
        // Never hold `lock` here: Core Audio can synchronously invoke the sink while starting.
        try self.engine.start()
      }
    } catch let error as VoiceAudioError {
      throw error
    } catch let error as ObjectiveCExceptions.Raised {
      throw VoiceAudioError.audioEngineStartFailed(error.reason)
    } catch {
      throw VoiceAudioError.audioEngineStartFailed(error.localizedDescription)
    }
  }

  public func play(_ data: Data) async throws {
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
      throw VoiceAudioError.invalidProviderAudio
    }
    guard let buffer = VoicePCMConverter.playbackBuffer(from: data, format: playbackFormat)
    else {
      throw VoiceAudioError.invalidProviderAudio
    }

    try await performAudioOperation { [self] in
      try self.preparePlaybackGraph()
      if !self.engine.isRunning {
        do {
          try ObjectiveCExceptions.catching {
            self.engine.prepare()
            try self.engine.start()
          }
        } catch {
          throw VoiceAudioError.audioEngineStartFailed(error.localizedDescription)
        }
      }

      let epoch = self.lock.withLock { () -> UInt64 in
        if !self.playbackActive {
          self.soundGate.reset()
          self.clearInputPreRoll()
        }
        self.pendingPlaybackBuffers += 1
        self.playbackActive = true
        self.loudInputBufferCount = 0
        self.interruptionReported = false
        return self.playbackEpoch
      }
      do {
        try ObjectiveCExceptions.catching {
          self.player.scheduleBuffer(buffer) { [weak self] in
            self?.markPlaybackBufferComplete(epoch: epoch)
          }
          if !self.player.isPlaying {
            // Safe because engine start, scheduling, play, stop, and graph changes are serialized.
            self.player.play()
          }
        }
      } catch {
        self.lock.withLock {
          self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
          if self.pendingPlaybackBuffers == 0 { self.playbackActive = false }
        }
        throw VoiceAudioError.audioEngineStartFailed(error.localizedDescription)
      }
    }
  }

  public func stopPlayback() async {
    await performAudioOperation {
      self.stopPlayerIfAttached()
      self.resetPlaybackState()
    }
  }

  public func waitForPlaybackToFinish(timeout: Duration) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if !lock.withLock({ playbackActive }) { return }
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  public func stop() async {
    await performAudioOperation {
      self.stopPlayerIfAttached()
      try? ObjectiveCExceptions.catching { self.engine.stop() }
      if let sink = self.lock.withLock({ () -> AVAudioSinkNode? in
        defer { self.sinkNode = nil }
        return self.sinkNode
      }) {
        try? ObjectiveCExceptions.catching {
          self.engine.disconnectNodeInput(sink)
          self.engine.detach(sink)
        }
        // Tear the voice-processing IO unit down completely: leaving it enabled keeps macOS in
        // call mode after voice sleeps — other apps' audio stays ducked and the system treats
        // the microphone chain as active even though Otto is no longer listening. The engine is
        // then replaced outright so the next session starts from a pristine graph instead of
        // re-toggling voice processing on a used engine, which is a known silent-microphone
        // failure mode. Only an engine that captured input ever touched the input node, so
        // this stays off the microphone hardware otherwise.
        try? ObjectiveCExceptions.catching {
          if self.engine.inputNode.isVoiceProcessingEnabled {
            try self.engine.inputNode.setVoiceProcessingEnabled(false)
          }
        }
      }
      self.rebuildEngine()
      self.lock.withLock {
        self.tapInstalled = false
        self.inputHandler = nil
        self.speechActivityHandler = nil
        self.inputMetricsHandler = nil
        self.voiceProcessingActive = false
        self.metricBufferCount = 0
        self.soundAnalyzer?.complete()
        self.soundAnalyzer = nil
        self.soundGate.reset()
        self.clearInputPreRoll()
      }
      self.resetPlaybackState()
    }
  }

  private func consumeInput(_ input: AVAudioPCMBuffer) {
    var detectedSpeech: (@Sendable () -> Void)?
    var reportedMetrics: (VoiceAudioInputMetrics, @Sendable (VoiceAudioInputMetrics) -> Void)?
    let (soundAnalyzer, inputEnabled) = lock.withLock {
      (self.soundAnalyzer, self.manualInputEnabled)
    }
    if inputEnabled { soundAnalyzer?.analyze(input) }
    var outgoing: [Data] = []
    var outgoingHandler: (@Sendable (Data) -> Void)?
    lock.withLock {
      guard let inputHandler else { return }
      let rms = rootMeanSquare(input)
      let classifierAllowsSpeech = soundAnalyzer == nil || soundGate.isOpen
      if voiceProcessingActive, playbackActive, !interruptionReported, classifierAllowsSpeech {
        if rms >= Self.speechRMSFloor {
          loudInputBufferCount += 1
        } else {
          // Do not accumulate separate mechanical transients (typing, clicks, or dragging) into
          // one synthetic utterance. Human speech remains above the floor continuously.
          loudInputBufferCount = 0
        }
        if loudInputBufferCount >= Self.speechBuffersRequired {
          playbackActive = false
          pendingPlaybackBuffers = 0
          playbackEpoch &+= 1
          interruptionReported = true
          detectedSpeech = speechActivityHandler
          // The real-time audio callback never mutates the player directly. Queueing the stop keeps
          // it ordered with any engine start, playback scheduling, or shutdown already in flight.
          audioQueue.async { [weak self] in self?.stopPlayerIfAttached() }
        }
      }
      // Do not stream Otto's own speaker output back to the provider. Voice processing removes
      // most echo, but the small residue is still enough for sensitive server VAD to invent a
      // user turn from fragments of the assistant's sentence. A genuine barge-in crosses the
      // sustained local speech threshold above, stops playback, and forwards audio from this
      // buffer onward. If voice processing is unavailable, playback remains half-duplex instead
      // of feeding raw speaker audio to the model.
      guard let data = VoicePCMConverter.providerPCM16(from: input) else { return }
      switch VoiceInputForwardingPolicy.decide(
        manualInputEnabled: manualInputEnabled,
        playbackActive: playbackActive,
        interruptionReported: interruptionReported,
        classifierAllowsSpeech: classifierAllowsSpeech
      ) {
      case .silence:
        // Keep server VAD supplied with silence so releasing push-to-talk finalizes the turn,
        // while guaranteeing that microphone content never leaves the Mac between presses.
        outgoing = [Data(repeating: 0, count: data.count)]
        outgoingHandler = inputHandler
      case .forward:
        outgoing = inputPreRoll
        clearInputPreRoll()
        outgoing.append(data)
        outgoingHandler = inputHandler
      case .bufferForBargeIn:
        appendToInputPreRoll(data)
      case .dropPlaybackLeakage:
        clearInputPreRoll()
      }
      metricBufferCount += 1
      if metricBufferCount == 1 || metricBufferCount.isMultiple(of: 25),
        let inputMetricsHandler
      {
        reportedMetrics = (
          VoiceAudioInputMetrics(
            inputFrames: Int(input.frameLength),
            outputBytes: data.count,
            rootMeanSquare: rms,
            inputName: localSpeechInputName(),
            sampleRate: input.format.sampleRate,
            channelCount: Int(input.format.channelCount)
          ),
          inputMetricsHandler
        )
      }
    }
    if let outgoingHandler {
      for data in outgoing { outgoingHandler(data) }
    }
    detectedSpeech?()
    if let (metrics, handler) = reportedMetrics { handler(metrics) }
  }

  private func handleSoundObservation(_ observation: VoiceInputSoundGate.Observation) {
    lock.withLock {
      guard inputHandler != nil else { return }
      soundGate.observe(observation)
      if !soundGate.isOpen, playbackActive { clearInputPreRoll() }
    }
  }

  /// Must be called while holding `lock`.
  private func appendToInputPreRoll(_ data: Data) {
    inputPreRoll.append(data)
    inputPreRollBytes += data.count
    while inputPreRollBytes > Self.inputPreRollByteLimit, !inputPreRoll.isEmpty {
      inputPreRollBytes -= inputPreRoll.removeFirst().count
    }
  }

  /// Must be called while holding `lock`.
  private func clearInputPreRoll() {
    inputPreRoll.removeAll(keepingCapacity: true)
    inputPreRollBytes = 0
  }

  private func markPlaybackBufferComplete(epoch: UInt64) {
    lock.withLock {
      guard playbackEpoch == epoch else { return }
      pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
      if pendingPlaybackBuffers == 0 { playbackActive = false }
    }
  }

  /// Must only be called from `audioQueue`.
  private func resetPlaybackState() {
    lock.withLock {
      playbackEpoch &+= 1
      pendingPlaybackBuffers = 0
      playbackActive = false
      loudInputBufferCount = 0
      interruptionReported = false
      soundGate.reset()
      clearInputPreRoll()
    }
  }

  private func performAudioOperation<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      audioQueue.async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func performAudioOperation(_ operation: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
      audioQueue.async {
        operation()
        continuation.resume()
      }
    }
  }

  private func rootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Double {
    let frames = Int(buffer.frameLength)
    guard frames > 0 else { return 0 }
    if let channels = buffer.floatChannelData {
      var sum = 0.0
      for frame in 0..<frames {
        let sample = Double(channels[0][frame])
        sum += sample * sample
      }
      return sqrt(sum / Double(frames))
    }
    if let channels = buffer.int16ChannelData {
      var sum = 0.0
      for frame in 0..<frames {
        let sample = Double(channels[0][frame]) / Double(Int16.max)
        sum += sample * sample
      }
      return sqrt(sum / Double(frames))
    }
    return 0
  }
}

enum VoicePCMConverter {
  /// Expands provider PCM16 (interleaved, mono, 24 kHz) into a standard float buffer in
  /// `format`. The engine graph is built entirely on the standard float format, which every
  /// AVAudioEngine mixer and output accepts, instead of asking the mixer to accept raw 16-bit
  /// input directly.
  static func playbackBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }
    let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    guard
      format.commonFormat == .pcmFormatFloat32, format.channelCount == 1,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
      let destination = buffer.floatChannelData?[0]
    else { return nil }
    buffer.frameLength = frameCount
    let scale = 1 / Float(Int16.max)
    data.withUnsafeBytes { raw in
      for frame in 0..<Int(frameCount) {
        let sample = raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self)
        destination[frame] = max(-1, Float(Int16(littleEndian: sample)) * scale)
      }
    }
    return buffer
  }

  static func providerPCM16(from input: AVAudioPCMBuffer) -> Data? {
    let inputFrames = Int(input.frameLength)
    let sampleRate = input.format.sampleRate
    guard inputFrames > 0, sampleRate > 0 else { return nil }
    let outputFrames = max(
      1,
      Int(
        (Double(inputFrames) * AVFoundationVoiceAudioTransport.providerSampleRate / sampleRate)
          .rounded(.down))
    )
    var samples = [Int16](repeating: 0, count: outputFrames)
    for outputFrame in 0..<outputFrames {
      let sourcePosition =
        Double(outputFrame) * sampleRate
        / AVFoundationVoiceAudioTransport.providerSampleRate
      let sourceFrame = min(inputFrames - 1, Int(sourcePosition.rounded(.down)))
      let normalized: Double
      if let channels = input.floatChannelData {
        let channelCount = max(1, Int(input.format.channelCount))
        var sum = 0.0
        for channel in 0..<channelCount {
          sum += Double(channels[channel][sourceFrame])
        }
        normalized = sum / Double(channelCount)
      } else if let channels = input.int16ChannelData {
        let channelCount = max(1, Int(input.format.channelCount))
        var sum = 0.0
        for channel in 0..<channelCount {
          sum += Double(channels[channel][sourceFrame]) / Double(Int16.max)
        }
        normalized = sum / Double(channelCount)
      } else {
        return nil
      }
      let clamped = max(-1.0, min(1.0, normalized))
      samples[outputFrame] = Int16(clamping: Int((clamped * Double(Int16.max)).rounded()))
    }
    return samples.withUnsafeBytes { Data($0) }
  }
}

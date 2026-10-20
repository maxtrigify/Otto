import AVFoundation
import Foundation
import Speech

public enum AppleSpeechError: Error, LocalizedError, Sendable {
  case unavailable
  case onDeviceRecognitionUnavailable

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      "On-device speech recognition is unavailable on this Mac"
    case .onDeviceRecognitionUnavailable:
      "Apple Speech has not downloaded an on-device recognizer for this language. Choose Parakeet or enable the required macOS language support; Otto will not send local command audio to a server."
    }
  }
}

public enum AppleSpeechPrivacyPolicy {
  /// Local Command and Dictate are advertised as offline. They must never allow Speech.framework
  /// to choose a server recognizer when the on-device language model is unavailable.
  public static func requireOnDeviceRecognition(_ supported: Bool) throws {
    guard supported else { throw AppleSpeechError.onDeviceRecognitionUnavailable }
  }
}

/// On-device speech recognition through SFSpeechRecognizer: free, private, and offline.
/// Audio is tapped from AVAudioEngine and never leaves the Mac (requiresOnDeviceRecognition).
public final class AppleSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
  public let inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic>
  private let lock = NSLock()
  private let diagnosticContinuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation
  private var audioEngine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?

  private var metricBufferCount = 0

  public init() {
    var continuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation!
    inputDiagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    diagnosticContinuation = continuation
  }

  public func requestAuthorization() async -> Bool {
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
    guard speech else { return false }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    default:
      return false
    }
  }

  public func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      throw AppleSpeechError.unavailable
    }
    try AppleSpeechPrivacyPolicy.requireOnDeviceRecognition(recognizer.supportsOnDeviceRecognition)
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      self?.recordInput(buffer)
    }
    engine.prepare()
    try engine.start()

    lock.withLock {
      audioEngine = engine
      self.request = request
    }

    return AsyncThrowingStream { continuation in
      let task = recognizer.recognitionTask(with: request) { result, error in
        if let result {
          continuation.yield(result.bestTranscription.formattedString)
          if result.isFinal { continuation.finish() }
        }
        if let error {
          // Cancellation after stopTranscribing is the normal shutdown path, not a failure.
          let code = (error as NSError).code
          if code == 216 || code == 301 {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
      }
      lock.withLock { recognitionTask = task }
      continuation.onTermination = { [weak self] _ in
        self?.teardown()
      }
    }
  }

  public func stopTranscribing() async {
    lock.withLock {
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      request?.endAudio()
    }
    // Give the recognizer a beat to emit its final segment before the task is torn down.
    try? await Task.sleep(for: .milliseconds(350))
    teardown()
  }

  private func teardown() {
    lock.withLock {
      recognitionTask?.cancel()
      recognitionTask = nil
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      audioEngine = nil
      request = nil
    }
  }

  private func recordInput(_ buffer: AVAudioPCMBuffer) {
    let shouldReport = lock.withLock { () -> Bool in
      metricBufferCount += 1
      return metricBufferCount == 1 || metricBufferCount.isMultiple(of: 10)
    }
    guard shouldReport else { return }
    diagnosticContinuation.yield(
      LocalSpeechInputDiagnostic(
        inputName: localSpeechInputName(),
        sampleRate: buffer.format.sampleRate,
        channelCount: Int(buffer.format.channelCount),
        rootMeanSquare: localSpeechRootMeanSquare(buffer)
      ))
  }
}

func localSpeechInputName() -> String {
  AVCaptureDevice.default(for: .audio)?.localizedName ?? "System default microphone"
}

func localSpeechRootMeanSquare(_ buffer: AVAudioPCMBuffer) -> Double {
  let frames = Int(buffer.frameLength)
  guard frames > 0 else { return 0 }
  let channelCount = max(1, Int(buffer.format.channelCount))
  var sum = 0.0
  var sampleCount = 0
  if let channels = buffer.floatChannelData {
    for channel in 0..<channelCount {
      for frame in 0..<frames {
        let value = Double(channels[channel][frame])
        sum += value * value
      }
      sampleCount += frames
    }
  } else if let channels = buffer.int16ChannelData {
    for channel in 0..<channelCount {
      for frame in 0..<frames {
        let value = Double(channels[channel][frame]) / Double(Int16.max)
        sum += value * value
      }
      sampleCount += frames
    }
  }
  return sampleCount == 0 ? 0 : sqrt(sum / Double(sampleCount))
}

public struct SpeechFileTranscription: Sendable, Equatable {
  public var text: String
  public var isOnDevice: Bool

  public init(text: String, isOnDevice: Bool) {
    self.text = text
    self.isOnDevice = isOnDevice
  }
}

/// File-based companion to the live microphone transcriber. Benchmarks use this API so every ASR
/// engine receives the exact same audio bytes rather than separately recorded utterances.
public enum AppleSpeechFileTranscriber {
  public static func transcribe(_ audioURL: URL, locale: Locale = .current) async throws
    -> SpeechFileTranscription
  {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw NSError(
        domain: "OttoVoiceBenchmark",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Apple speech recognition is unavailable"]
      )
    }
    let request = SFSpeechURLRecognitionRequest(url: audioURL)
    request.shouldReportPartialResults = false
    try AppleSpeechPrivacyPolicy.requireOnDeviceRecognition(recognizer.supportsOnDeviceRecognition)
    let onDevice = true
    request.requiresOnDeviceRecognition = true

    return try await withCheckedThrowingContinuation { continuation in
      let lock = NSLock()
      var resumed = false
      _ = recognizer.recognitionTask(with: request) { result, error in
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        if let result, result.isFinal {
          resumed = true
          continuation.resume(
            returning: SpeechFileTranscription(
              text: result.bestTranscription.formattedString,
              isOnDevice: onDevice
            ))
        } else if let error {
          resumed = true
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

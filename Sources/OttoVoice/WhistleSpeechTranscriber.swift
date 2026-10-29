import AVFoundation
import Foundation

/// Where the Whistle engine and weights live once `WhistleInstaller` has verified them.
public struct WhistleRuntimeConfiguration: Sendable, Equatable {
  public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Otto/VoiceModels/Whistle")

  public var engineURL: URL
  public var modelURL: URL

  public init(root: URL) {
    engineURL = root.appending(path: WhistleInstaller.engine.relativePath)
    modelURL = root.appending(path: WhistleInstaller.model.relativePath)
  }

  public static func installed(fileManager: FileManager = .default) -> Self? {
    let configuration = Self(root: defaultRoot)
    return configuration.validationError(fileManager: fileManager) == nil ? configuration : nil
  }

  public func validationError(fileManager: FileManager = .default) -> String? {
    guard fileManager.isExecutableFile(atPath: engineURL.path) else {
      return "Whistle's engine is missing. Install Whistle in Voice Settings."
    }
    let size = (try? fileManager.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?
      .intValue
    guard size == WhistleInstaller.model.size else {
      return "Whistle's model is missing or incomplete. Install Whistle in Voice Settings."
    }
    return nil
  }
}

public struct WhistleTranscription: Sendable, Equatable, Decodable {
  public var text: String
  public var language: String?

  public init(text: String, language: String? = nil) {
    self.text = text
    self.language = language
  }
}

public enum WhistleRuntimeError: Error, LocalizedError, Equatable {
  case invalidInstallation(String)
  case conversion(String)
  case failed(Int32, String)
  case missingResult

  public var errorDescription: String? {
    switch self {
    case .invalidInstallation(let detail): detail
    case .conversion(let detail): "Could not prepare the recording for Whistle: \(detail)"
    case .failed(let status, let detail): "Whistle exited with status \(status): \(detail)"
    case .missingResult: "Whistle returned no transcript"
    }
  }
}

/// Runs Cactus Compute's `needle` engine on one recording. The engine reads 16 kHz mono audio,
/// so the recording is first converted with macOS's own `afconvert`. Nothing leaves the Mac.
public struct WhistleOfflineRunner: Sendable {
  public var configuration: WhistleRuntimeConfiguration

  public init(configuration: WhistleRuntimeConfiguration) {
    self.configuration = configuration
  }

  public func transcribe(_ audioURL: URL) async throws -> WhistleTranscription {
    if let error = configuration.validationError() {
      throw WhistleRuntimeError.invalidInstallation(error)
    }
    let clip = FileManager.default.temporaryDirectory
      .appending(path: "otto-whistle-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: clip) }
    let converted = try await Self.run(
      URL(filePath: "/usr/bin/afconvert"),
      ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audioURL.path, clip.path])
    guard converted.status == 0 else {
      throw WhistleRuntimeError.conversion(converted.errorText)
    }
    let result = try await Self.run(
      configuration.engineURL,
      ["--model", configuration.modelURL.path, "--audio", clip.path])
    guard result.status == 0 else {
      throw WhistleRuntimeError.failed(result.status, result.errorText)
    }
    return try Self.parse(result.output)
  }

  /// The engine reports `{"text":...,"language":...}` (see `needle.h`). The last JSON object
  /// with a `text` field wins; plain output is taken as the transcript itself.
  static func parse(_ output: String) throws -> WhistleTranscription {
    let lines = output.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    for line in lines.reversed() where line.hasPrefix("{") {
      if let decoded = try? JSONDecoder().decode(WhistleTranscription.self, from: Data(line.utf8)) {
        return WhistleTranscription(
          text: decoded.text.trimmingCharacters(in: .whitespacesAndNewlines),
          language: decoded.language)
      }
    }
    let plain = lines.filter { !$0.isEmpty && !$0.hasPrefix("{") }.joined(separator: " ")
    guard !plain.isEmpty else { throw WhistleRuntimeError.missingResult }
    return WhistleTranscription(text: plain)
  }

  private static func run(_ executable: URL, _ arguments: [String]) async throws -> (
    status: Int32, output: String, errorText: String
  ) {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
    let errorTask = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
    await withCheckedContinuation { continuation in
      process.terminationHandler = { _ in continuation.resume() }
    }
    let errorText = String(decoding: await errorTask.value.suffix(2_000), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (
      process.terminationStatus, String(decoding: await outputTask.value, as: UTF8.self),
      errorText
    )
  }
}

/// Records the microphone locally, then transcribes with Whistle when push-to-talk ends. Audio
/// never leaves the Mac.
public final class WhistleSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {
  public let inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic>
  private let lock = NSLock()
  private let diagnosticContinuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation
  private let runner: WhistleOfflineRunner
  private var audioEngine: AVAudioEngine?
  private var audioFile: AVAudioFile?
  private var outputURL: URL?
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?
  private var metricBufferCount = 0

  public init(configuration: WhistleRuntimeConfiguration) {
    runner = WhistleOfflineRunner(configuration: configuration)
    var continuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation!
    inputDiagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    diagnosticContinuation = continuation
  }

  public func requestAuthorization() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: true
    case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
    default: false
    }
  }

  public func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    if let error = runner.configuration.validationError() {
      throw WhistleRuntimeError.invalidInstallation(error)
    }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let url = FileManager.default.temporaryDirectory
      .appending(path: "otto-whistle-capture-\(UUID().uuidString).wav")
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.withLock { try? self.audioFile?.write(from: buffer) }
      self.recordInput(buffer)
    }
    engine.prepare()
    try engine.start()
    lock.withLock {
      audioEngine = engine
      audioFile = file
      outputURL = url
    }
    return AsyncThrowingStream { continuation in
      self.lock.withLock { self.continuation = continuation }
      continuation.onTermination = { [weak self] _ in self?.teardown(removeAudio: true) }
    }
  }

  public func stopTranscribing() async {
    let state = lock.withLock { () -> (URL?, AsyncThrowingStream<String, Error>.Continuation?) in
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      audioEngine = nil
      audioFile = nil
      let state = (outputURL, continuation)
      outputURL = nil
      continuation = nil
      return state
    }
    guard let url = state.0, let continuation = state.1 else { return }
    do {
      continuation.yield(try await runner.transcribe(url).text)
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
    try? FileManager.default.removeItem(at: url)
  }

  private func teardown(removeAudio: Bool) {
    let url = lock.withLock { () -> URL? in
      audioEngine?.inputNode.removeTap(onBus: 0)
      audioEngine?.stop()
      audioEngine = nil
      audioFile = nil
      continuation = nil
      defer { outputURL = nil }
      return outputURL
    }
    if removeAudio, let url { try? FileManager.default.removeItem(at: url) }
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

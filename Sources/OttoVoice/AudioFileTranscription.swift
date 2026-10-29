import Foundation
import Speech

/// Engines that can transcribe a finished recording, such as a Telegram voice note.
public enum AudioFileTranscriptionEngine: String, Sendable, CaseIterable {
  case whistle, parakeet, apple
}

public enum AudioFileTranscriptionError: Error, LocalizedError, Equatable {
  case conversion(String)
  case noEngine
  case nothingHeard

  public var errorDescription: String? {
    switch self {
    case .conversion(let detail): "Could not read the recording: \(detail)"
    case .noEngine:
      "No on-device speech engine is ready. Allow Speech Recognition for Otto, or download Whistle in Voice settings."
    case .nothingHeard: "No speech was found in the recording."
    }
  }
}

/// Transcribes a recording on this Mac, never through a server. The file is first converted
/// with macOS's own `afconvert`, which also reads the Ogg Opus that Telegram voice notes use.
/// Engines are tried in the order given and skipped when not installed or not allowed.
public enum AudioFileTranscription {
  /// Telegram's Bot API serves files up to 20 MB; nothing larger is read.
  public static let maxBytes = 20_000_000

  public static func transcribe(
    _ audioURL: URL, preferring order: [AudioFileTranscriptionEngine]
  ) async throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let clip = directory.appending(path: "clip.wav")
    try await convert(audioURL, to: clip)

    var lastError: Error = AudioFileTranscriptionError.noEngine
    let engines = order + AudioFileTranscriptionEngine.allCases.filter { !order.contains($0) }
    for engine in engines {
      do {
        guard let text = try await transcribe(clip, with: engine) else { continue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        lastError = AudioFileTranscriptionError.nothingHeard
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  /// Nil when the engine is not installed or not permitted, so the next one is tried.
  private static func transcribe(_ clip: URL, with engine: AudioFileTranscriptionEngine)
    async throws -> String?
  {
    switch engine {
    case .whistle:
      guard let configuration = WhistleRuntimeConfiguration.installed() else { return nil }
      return try await WhistleOfflineRunner(configuration: configuration).transcribe(clip).text
    case .parakeet:
      guard let configuration = ParakeetRuntimeConfiguration.installed() else { return nil }
      return try await ParakeetOfflineRunner(configuration: configuration).transcribe(clip).text
    case .apple:
      guard SFSpeechRecognizer.authorizationStatus() == .authorized,
        let recognizer = SFSpeechRecognizer(), recognizer.isAvailable,
        recognizer.supportsOnDeviceRecognition
      else { return nil }
      let request = SFSpeechURLRecognitionRequest(url: clip)
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = false
      return try await withCheckedThrowingContinuation { continuation in
        var finished = false
        recognizer.recognitionTask(with: request) { result, error in
          guard !finished else { return }
          if let result, result.isFinal {
            finished = true
            continuation.resume(returning: result.bestTranscription.formattedString)
          } else if let error {
            finished = true
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  private static func convert(_ source: URL, to destination: URL) async throws {
    let size =
      (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
      .intValue ?? 0
    guard size > 0, size <= maxBytes else {
      throw AudioFileTranscriptionError.conversion("the file is empty or larger than 20 MB")
    }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/afconvert")
    process.arguments = [
      "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", source.path, destination.path,
    ]
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    let errorData = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw AudioFileTranscriptionError.conversion(
        String(decoding: errorData.suffix(300), as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }
}

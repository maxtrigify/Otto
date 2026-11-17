import Foundation

public enum VoiceSampleRecorderError: Error, LocalizedError, Sendable {
  case alreadyRecording

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording: "Otto is already listening for your voice."
    }
  }
}

/// Records the person reading a line aloud so Otto can learn their voice.
///
/// The audio is held in memory only for as long as it takes to turn it into a voiceprint. It is
/// never written to disk and never leaves this Mac.
public actor VoiceSampleRecorder {
  private let transport: any VoiceAudioTransport
  private let buffer = Buffer()
  private var recording = false

  private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var latest = 0.0
    func append(_ more: Data) {
      let level = LocalVoiceEndpointer.rootMeanSquare(more)
      lock.withLock {
        data.append(more)
        latest = level
      }
    }
    var level: Double { lock.withLock { latest } }
    func take() -> Data {
      lock.withLock {
        let taken = data
        data = Data()
        return taken
      }
    }
  }

  public init(transport: any VoiceAudioTransport = AVFoundationVoiceAudioTransport()) {
    self.transport = transport
  }

  public func start() async throws {
    guard !recording else { throw VoiceSampleRecorderError.alreadyRecording }
    _ = buffer.take()
    recording = true
    do {
      try await transport.startInput { [buffer] data in buffer.append(data) }
    } catch {
      recording = false
      throw error
    }
  }

  /// How loud the microphone is right now, from 0 (silent) upwards, for a live level meter.
  public nonisolated var level: Double { buffer.level }

  /// Stops and returns what was heard as 16 kHz samples, the rate the voice models expect.
  public func stop() async -> [Float] {
    guard recording else { return [] }
    recording = false
    await transport.stop()
    return LocalVoiceEndpointer.resampledTo16k(
      LocalVoiceEndpointer.floatSamples(buffer.take()),
      from: AVFoundationVoiceAudioTransport.providerSampleRate)
  }
}

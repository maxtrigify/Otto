@preconcurrency import AVFoundation
import Foundation

/// Turns one short piece of text into speech on this Mac.
///
/// Audio comes back in the format Otto's voice transport plays: signed 16-bit mono PCM at 24 kHz.
/// A neural voice can replace the system one by conforming to this protocol.
public protocol LocalSpeechSynthesizing: Sendable {
  func speech(for text: String) async throws -> Data
}

public struct LocalSpeechVoice: Identifiable, Sendable, Equatable {
  public var id: String
  public var name: String
  public var summary: String

  public init(id: String, name: String, summary: String) {
    self.id = id
    self.name = name
    self.summary = summary
  }
}

public enum LocalSpeechError: Error, LocalizedError, Sendable {
  case noAudio

  public var errorDescription: String? {
    switch self {
    case .noAudio: "Otto could not make speech for that reply."
    }
  }
}

/// Speaks with the voices built into macOS: nothing to download, and always available.
public final class SystemSpeechSynthesizer: NSObject, LocalSpeechSynthesizing, @unchecked Sendable {
  private let voiceIdentifier: String?
  private let rate: Float
  private let lock = NSLock()
  private var active: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

  public init(voiceIdentifier: String? = nil, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
    self.voiceIdentifier = voiceIdentifier
    self.rate = rate
  }

  /// English voices installed on this Mac, best quality first.
  public static func voices() -> [LocalSpeechVoice] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("en") }
      .sorted {
        ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name)
      }
      .map { voice in
        let quality =
          switch voice.quality {
          case .premium: "Premium"
          case .enhanced: "Enhanced"
          default: "Standard"
          }
        return LocalSpeechVoice(
          id: voice.identifier, name: voice.name,
          summary:
            "\(quality) · \(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)"
        )
      }
  }

  /// The best installed British voice, falling back to whatever English voice exists.
  public static func defaultVoiceIdentifier() -> String? {
    let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    let ranked = english.sorted { $0.quality.rawValue > $1.quality.rawValue }
    return (ranked.first { $0.language == "en-GB" } ?? ranked.first)?.identifier
  }

  public func speech(for text: String) async throws -> Data {
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = rate
    if let identifier = voiceIdentifier ?? Self.defaultVoiceIdentifier() {
      utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
    }
    let synthesizer = AVSpeechSynthesizer()
    let key = ObjectIdentifier(synthesizer)
    // The synthesizer must outlive the call that started it or it stops mid-sentence.
    lock.withLock { active[key] = synthesizer }
    defer { lock.withLock { active[key] = nil } }

    let collected = Collected()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
          // An empty buffer marks the end of the utterance.
          if collected.finish() { continuation.resume() }
          return
        }
        if let data = VoicePCMConverter.providerPCM16(from: pcm) { collected.append(data) }
      }
    }
    let audio = collected.data
    guard !audio.isEmpty else { throw LocalSpeechError.noAudio }
    return audio
  }

  private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false

    var data: Data { lock.withLock { storage } }

    func append(_ data: Data) {
      lock.withLock { storage.append(data) }
    }

    func finish() -> Bool {
      lock.withLock {
        if finished { return false }
        finished = true
        return true
      }
    }
  }
}

import Foundation

/// How loud the microphone and Otto's own speech are right now, for drawing voice activity.
///
/// The audio transport writes here from its audio threads and the interface reads from its
/// drawing loop, many times a second. Publishing each value through the voice controller would
/// redraw every view that watches voice for a number only one of them draws.
public final class VoiceActivityLevels: @unchecked Sendable {
  public static let shared = VoiceActivityLevels()

  /// The spacing of the loudness values kept for speech that is queued to play.
  static let outputStep: TimeInterval = 0.04
  /// Every voice provider hands Otto 24 kHz speech.
  static let providerSampleRate = 24_000.0

  private let lock = NSLock()
  private var input = 0.0
  private var inputAt = Date.distantPast
  private var output: [Double] = []
  private var outputStart = Date.distantPast

  public init() {}

  /// The microphone's loudness, zero once it has been quiet or stopped for a moment.
  public func inputLevel(at now: Date = Date()) -> Double {
    lock.withLock { now.timeIntervalSince(inputAt) < 0.3 ? input : 0 }
  }

  /// The loudness of the speech Otto is playing at this instant.
  public func outputLevel(at now: Date = Date()) -> Double {
    lock.withLock {
      let index = Int(now.timeIntervalSince(outputStart) / Self.outputStep)
      return output.indices.contains(index) ? output[index] : 0
    }
  }

  func noteInput(_ level: Double, at now: Date = Date()) {
    lock.withLock {
      input = level
      inputAt = now
    }
  }

  /// Speech arrives a sentence at a time and plays after whatever is already queued, so its
  /// loudness is laid out along the time it will be heard.
  func queueOutput(pcm16 data: Data, sampleRate: Double, at now: Date = Date()) {
    let levels = Self.levels(pcm16: data, sampleRate: sampleRate)
    guard !levels.isEmpty else { return }
    lock.withLock {
      let queuedUntil = outputStart.addingTimeInterval(Double(output.count) * Self.outputStep)
      if queuedUntil > now {
        output.append(contentsOf: levels)
      } else {
        output = levels
        outputStart = now
      }
    }
  }

  func clearOutput() {
    lock.withLock {
      output = []
      outputStart = .distantPast
    }
  }

  static func levels(pcm16 data: Data, sampleRate: Double) -> [Double] {
    let window = max(1, Int(sampleRate * outputStep))
    return data.withUnsafeBytes { raw -> [Double] in
      let samples = raw.bindMemory(to: Int16.self)
      guard !samples.isEmpty else { return [] }
      var levels: [Double] = []
      levels.reserveCapacity(samples.count / window + 1)
      var start = 0
      while start < samples.count {
        let end = min(samples.count, start + window)
        var sum = 0.0
        for index in start..<end {
          let sample = Double(samples[index]) / Double(Int16.max)
          sum += sample * sample
        }
        levels.append((sum / Double(end - start)).squareRoot())
        start = end
      }
      return levels
    }
  }
}

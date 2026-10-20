@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import SoundAnalysis

/// Small deterministic state machine kept separate from Sound Analysis so the speech/music
/// decision can be tested without a microphone or classifier model.
struct VoiceInputSoundGate: Sendable {
  struct Observation: Sendable, Equatable {
    var speech: Double
    var music: Double
    var singing: Double

    init(speech: Double = 0, music: Double = 0, singing: Double = 0) {
      self.speech = speech
      self.music = music
      self.singing = singing
    }
  }

  private(set) var isOpen = false
  private var musicWindows = 0
  let musicThreshold: Double
  let musicMargin: Double
  let musicWindowsRequired: Int

  init(
    musicThreshold: Double = 0.65,
    musicMargin: Double = 0.03,
    musicWindowsRequired: Int = 2
  ) {
    self.musicThreshold = musicThreshold
    self.musicMargin = musicMargin
    self.musicWindowsRequired = musicWindowsRequired
  }

  mutating func observe(_ observation: Observation) {
    let strongestNonSpeech = max(observation.music, observation.singing)
    let isConfidentMusic =
      strongestNonSpeech >= musicThreshold
      && strongestNonSpeech >= observation.speech + musicMargin

    if isConfidentMusic {
      musicWindows += 1
      if musicWindows >= musicWindowsRequired { isOpen = false }
      return
    }

    // Bias ambiguous or quiet classifications toward hearing the person. The previous gate
    // required a strong `speech` score and silently discarded ordinary soft/short requests.
    // We now reject only sustained, confident music or singing and leave uncertain audio to
    // OpenAI's far-field filter and VAD.
    musicWindows = 0
    isOpen = true
  }

  mutating func reset() {
    isOpen = false
    musicWindows = 0
  }
}

/// Feeds copied microphone buffers to Apple's built-in on-device classifier. The analyzer runs on
/// its own serial queue so the real-time Core Audio callback only pays the cost of copying a small
/// buffer and never waits for Core ML inference.
final class VoiceInputSoundAnalyzer: @unchecked Sendable {
  private let analyzer: SNAudioStreamAnalyzer
  private let observer: VoiceInputSoundObserver
  private let analysisQueue = DispatchQueue(label: "io.openotto.voice.sound-analysis")
  private var framePosition: AVAudioFramePosition = 0

  init(
    format: AVAudioFormat,
    observationHandler: @escaping @Sendable (VoiceInputSoundGate.Observation) -> Void
  ) throws {
    analyzer = SNAudioStreamAnalyzer(format: format)
    observer = VoiceInputSoundObserver(observationHandler: observationHandler)
    let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
    // Version 1 supports a 500 ms minimum window. Heavy overlap produces a fresh decision about
    // every 100 ms after that first window, which keeps the hangover responsive.
    request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16_000)
    request.overlapFactor = 0.8
    try analyzer.add(request, withObserver: observer)
  }

  func analyze(_ input: AVAudioPCMBuffer) {
    guard let copy = Self.copy(input) else { return }
    analysisQueue.async { [self] in
      analyzer.analyze(copy, atAudioFramePosition: framePosition)
      framePosition += AVAudioFramePosition(copy.frameLength)
    }
  }

  func complete() {
    analysisQueue.async { [analyzer] in analyzer.completeAnalysis() }
  }

  private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let copy = AVAudioPCMBuffer(
        pcmFormat: input.format,
        frameCapacity: input.frameLength
      )
    else { return nil }
    copy.frameLength = input.frameLength
    let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard source.count == destination.count else { return nil }
    for index in source.indices {
      guard let sourceData = source[index].mData, let destinationData = destination[index].mData
      else { return nil }
      memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
      destination[index].mDataByteSize = source[index].mDataByteSize
    }
    return copy
  }
}

private final class VoiceInputSoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
  private let observationHandler: @Sendable (VoiceInputSoundGate.Observation) -> Void

  init(observationHandler: @escaping @Sendable (VoiceInputSoundGate.Observation) -> Void) {
    self.observationHandler = observationHandler
  }

  func request(_ request: SNRequest, didProduce result: SNResult) {
    guard let result = result as? SNClassificationResult else { return }
    observationHandler(
      VoiceInputSoundGate.Observation(
        speech: result.classification(forIdentifier: "speech")?.confidence ?? 0,
        music: result.classification(forIdentifier: "music")?.confidence ?? 0,
        singing: max(
          result.classification(forIdentifier: "singing")?.confidence ?? 0,
          result.classification(forIdentifier: "choir_singing")?.confidence ?? 0
        )
      ))
  }

  func request(_ request: SNRequest, didFailWithError error: any Error) {}
  func requestDidComplete(_ request: SNRequest) {}
}

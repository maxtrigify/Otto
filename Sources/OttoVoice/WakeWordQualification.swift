@preconcurrency import AVFoundation
import Foundation

#if canImport(LiveKitWakeWord)
  import LiveKitWakeWord
#endif

public enum WakeWordQualificationLabel: String, Codable, Sendable {
  case positive
  case negative
}

public struct WakeWordQualificationCase: Codable, Sendable, Equatable {
  public var id: String
  public var audioFile: String
  public var label: WakeWordQualificationLabel
  public var speakerID: String?

  public init(
    id: String,
    audioFile: String,
    label: WakeWordQualificationLabel,
    speakerID: String? = nil
  ) {
    self.id = id
    self.audioFile = audioFile
    self.label = label
    self.speakerID = speakerID
  }
}

public struct WakeWordQualificationCorpus: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var corpusKind: String
  public var cases: [WakeWordQualificationCase]

  public init(
    schemaVersion: Int = 1,
    corpusKind: String = "held-out-real-speakers",
    cases: [WakeWordQualificationCase]
  ) {
    self.schemaVersion = schemaVersion
    self.corpusKind = corpusKind
    self.cases = cases
  }
}

public struct WakeWordQualificationReport: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var corpusKind: String
  public var realSpeakerCount: Int
  public var positiveSamples: Int
  public var negativeSamples: Int
  public var validationHours: Double
  public var threshold: Float
  public var recall: Double
  public var falsePositivesPerHour: Double

  public var passesReleaseGate: Bool {
    AcousticWakeWordModelQuality(
      evaluatedAt: "qualification",
      threshold: threshold,
      recall: recall,
      falsePositivesPerHour: falsePositivesPerHour,
      positiveSamples: positiveSamples,
      negativeSamples: negativeSamples,
      validationHours: validationHours,
      realSpeakerCount: realSpeakerCount,
      corpusKind: corpusKind,
      modelSHA256: String(repeating: "0", count: 64)
    ).passesReleaseGate
  }
}

public enum WakeWordQualificationError: Error, LocalizedError, Equatable {
  case runtimeNotLinked
  case invalidCorpus(String)
  case unsupportedAudio(String)

  public var errorDescription: String? {
    switch self {
    case .runtimeNotLinked:
      "The acoustic wake-word runtime is not linked."
    case .invalidCorpus(let detail), .unsupportedAudio(let detail):
      detail
    }
  }
}

public enum WakeWordQualificationEvaluator {
  public static func evaluate(
    corpusDirectory: URL,
    classifierURL: URL
  ) throws -> WakeWordQualificationReport {
    #if canImport(LiveKitWakeWord)
      let manifestURL = corpusDirectory.appendingPathComponent("manifest.json")
      let corpus = try JSONDecoder().decode(
        WakeWordQualificationCorpus.self,
        from: Data(contentsOf: manifestURL)
      )
      guard corpus.schemaVersion == 1,
        corpus.corpusKind == "held-out-real-speakers",
        corpus.cases.contains(where: { $0.label == .positive }),
        corpus.cases.contains(where: { $0.label == .negative })
      else {
        throw WakeWordQualificationError.invalidCorpus(
          "The wake-word corpus must contain held-out positive and negative real-speaker cases."
        )
      }
      let modelName = classifierURL.deletingPathExtension().lastPathComponent
      var models: [UInt32: WakeWordModel] = [:]
      var positives: [Float] = []
      var negatives: [[Float]] = []
      var negativeHours = 0.0
      var speakers = Set<String>()
      for testCase in corpus.cases {
        let audio = try readAudio(corpusDirectory.appendingPathComponent(testCase.audioFile))
        let model: WakeWordModel
        if let existing = models[audio.sampleRate] {
          model = existing
        } else {
          model = try WakeWordModel(
            models: [classifierURL],
            sampleRate: audio.sampleRate,
            executionProvider: .coreML
          )
          models[audio.sampleRate] = model
        }
        let scores = try windowScores(
          audio.samples,
          sampleRate: audio.sampleRate,
          model: model,
          modelName: modelName
        )
        switch testCase.label {
        case .positive:
          positives.append(scores.max() ?? 0)
          if let speakerID = testCase.speakerID, !speakerID.isEmpty { speakers.insert(speakerID) }
        case .negative:
          negatives.append(scores)
          negativeHours += audio.duration / 3_600
        }
      }
      return selectThreshold(
        positiveScores: positives,
        negativeScoreSequences: negatives,
        negativeHours: negativeHours,
        realSpeakerCount: speakers.count,
        corpusKind: corpus.corpusKind
      )
    #else
      throw WakeWordQualificationError.runtimeNotLinked
    #endif
  }

  static func selectThreshold(
    positiveScores: [Float],
    negativeScoreSequences: [[Float]],
    negativeHours: Double,
    realSpeakerCount: Int,
    corpusKind: String = "held-out-real-speakers"
  ) -> WakeWordQualificationReport {
    var selectedThreshold: Float = 0.99
    var selectedRecall = 0.0
    var selectedFPPH = Double.greatestFiniteMagnitude
    var selectedFalsePositiveWindows = Int.max
    for step in 1...99 {
      let threshold = Float(step) / 100
      let recall =
        Double(positiveScores.count(where: { $0 >= threshold }))
        / Double(max(1, positiveScores.count))
      let falsePositives = falsePositiveEvents(
        in: negativeScoreSequences,
        threshold: threshold
      )
      let fpph = negativeHours > 0 ? Double(falsePositives) / negativeHours : .infinity
      let falsePositiveWindows = negativeScoreSequences.reduce(into: 0) { count, sequence in
        count += sequence.count(where: { $0 >= threshold })
      }
      if fpph <= AcousticWakeWordConfiguration.maximumFalsePositivesPerHour,
        recall > selectedRecall
          || (recall == selectedRecall
            && falsePositiveWindows < selectedFalsePositiveWindows)
      {
        selectedThreshold = threshold
        selectedRecall = recall
        selectedFPPH = fpph
        selectedFalsePositiveWindows = falsePositiveWindows
      }
    }
    if !selectedFPPH.isFinite {
      let falsePositives = falsePositiveEvents(
        in: negativeScoreSequences,
        threshold: selectedThreshold
      )
      selectedFPPH = negativeHours > 0 ? Double(falsePositives) / negativeHours : .infinity
      selectedRecall =
        Double(positiveScores.count(where: { $0 >= selectedThreshold }))
        / Double(max(1, positiveScores.count))
    }
    return WakeWordQualificationReport(
      schemaVersion: 1,
      corpusKind: corpusKind,
      realSpeakerCount: realSpeakerCount,
      positiveSamples: positiveScores.count,
      negativeSamples: negativeScoreSequences.count,
      validationHours: negativeHours,
      threshold: selectedThreshold,
      recall: selectedRecall,
      falsePositivesPerHour: selectedFPPH
    )
  }

  private static func falsePositiveEvents(
    in sequences: [[Float]],
    threshold: Float
  ) -> Int {
    let debounceWindows = 7  // ceil(2 second production debounce / 320 ms stride)
    var events = 0
    for sequence in sequences {
      var lastEventIndex = -debounceWindows
      for (index, score) in sequence.enumerated()
      where score >= threshold && index - lastEventIndex >= debounceWindows {
        events += 1
        lastEventIndex = index
      }
    }
    return events
  }

  #if canImport(LiveKitWakeWord)
    private struct QualificationAudio {
      var samples: [Int16]
      var sampleRate: UInt32
      var duration: Double
    }

    private static func readAudio(_ url: URL) throws -> QualificationAudio {
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      guard format.sampleRate > 0, format.sampleRate <= Double(UInt32.max) else {
        throw WakeWordQualificationError.unsupportedAudio(
          "Wake-word qualification audio has an invalid sample rate: \(url.lastPathComponent)"
        )
      }
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: AVAudioFrameCount(file.length)
        )
      else {
        throw WakeWordQualificationError.unsupportedAudio(
          "Could not allocate audio buffer for \(url.lastPathComponent)"
        )
      }
      try file.read(into: buffer)
      guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
        throw WakeWordQualificationError.unsupportedAudio(
          "Wake-word qualification audio is empty: \(url.lastPathComponent)"
        )
      }
      let frameCount = Int(buffer.frameLength)
      let channelCount = Int(format.channelCount)
      var samples = [Int16](repeating: 0, count: frameCount)
      for frame in 0..<frameCount {
        var value: Float = 0
        for channel in 0..<channelCount { value += channels[channel][frame] }
        value = max(-1, min(1, value / Float(channelCount)))
        samples[frame] = Int16((value * Float(Int16.max)).rounded())
      }
      return QualificationAudio(
        samples: samples,
        sampleRate: UInt32(format.sampleRate.rounded()),
        duration: Double(frameCount) / format.sampleRate
      )
    }

    private static func windowScores(
      _ samples: [Int16],
      sampleRate: UInt32,
      model: WakeWordModel,
      modelName: String
    ) throws -> [Float] {
      let windowSize = Int(sampleRate) * 2
      let windowStride = max(1, Int((Double(sampleRate) * 0.32).rounded()))
      var padded = samples
      if padded.count < windowSize {
        padded.append(contentsOf: repeatElement(0, count: windowSize - padded.count))
      }
      var scores: [Float] = []
      for start in stride(from: 0, through: padded.count - windowSize, by: windowStride) {
        let window = Array(padded[start..<(start + windowSize)])
        scores.append(try model.predict(window)[modelName] ?? 0)
      }
      return scores
    }
  #endif
}

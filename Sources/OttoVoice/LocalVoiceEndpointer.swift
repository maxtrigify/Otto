import Foundation

/// Finds where a spoken request starts and ends in the microphone stream, on this Mac.
///
/// Cloud voice providers do this on their servers. The local engine has no server, so it watches
/// loudness: a request starts when sound stays clearly above the room's own level and ends when
/// it falls well below how loud the speaker was. Measuring against the room and the speaker,
/// rather than against silence, is what lets it work with music or a television in the background.
public struct LocalVoiceEndpointer: Sendable {
  public enum Event: Sendable, Equatable {
    case speechStarted
    /// The whole request as signed 16-bit mono PCM, including a short lead-in. `deliberate` is
    /// true when the person held the Talk key for it, which makes it certainly theirs.
    case speechEnded(Data, deliberate: Bool)
  }

  public struct Configuration: Sendable, Equatable {
    public var sampleRate: Double
    /// Loudness below this is never speech, however quiet the room is.
    public var minimumSpeechLevel: Double
    /// How far above the room's level sound must be to count as speech.
    public var roomMultiplier: Double
    /// The request has ended once sound falls below this share of the speaker's own level.
    public var speakerShare: Double
    public var startDuration: Double
    public var endDuration: Double
    public var leadInDuration: Double
    public var maximumDuration: Double
    public var minimumDuration: Double

    public init(
      sampleRate: Double = 24_000,
      minimumSpeechLevel: Double = 0.025,
      roomMultiplier: Double = 2.6,
      speakerShare: Double = 0.45,
      startDuration: Double = 0.2,
      endDuration: Double = 0.8,
      leadInDuration: Double = 0.35,
      maximumDuration: Double = 30,
      minimumDuration: Double = 0.3
    ) {
      self.sampleRate = sampleRate
      self.minimumSpeechLevel = minimumSpeechLevel
      self.roomMultiplier = roomMultiplier
      self.speakerShare = speakerShare
      self.startDuration = startDuration
      self.endDuration = endDuration
      self.leadInDuration = leadInDuration
      self.maximumDuration = maximumDuration
      self.minimumDuration = minimumDuration
    }
  }

  public let configuration: Configuration
  public private(set) var isCapturing = false
  /// The loudness of the last buffer and the level it had to beat, for diagnostics.
  public private(set) var lastLevel = 0.0
  public private(set) var lastThreshold = 0.0

  private var recentLevels: [(level: Double, seconds: Double)] = []
  private var recentSeconds = 0.0
  private var secondsSinceRoomUpdate = 0.0
  private var roomLevel = 0.004
  private var speakerLevel = 0.0
  private var loudSeconds = 0.0
  private var quietSeconds = 0.0
  private var capturedSeconds = 0.0
  private var leadIn: [Data] = []
  private var leadInSeconds = 0.0
  private var captured = Data()
  private var captureLevels: [(level: Double, seconds: Double)] = []
  /// Push to talk sends true digital silence until the key goes down. Sound that follows a run
  /// of it was let through by the person on purpose; an open microphone is never exactly silent.
  private var silentBuffers = 0
  private var keyHeld = false
  private var captureIsDeliberate = false

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
  }

  /// Feeds one buffer of signed 16-bit mono PCM and reports what it changed.
  public mutating func process(_ pcm: Data) -> [Event] {
    let frames = pcm.count / MemoryLayout<Int16>.size
    guard frames > 0 else { return [] }
    let seconds = Double(frames) / configuration.sampleRate
    let level = Self.rootMeanSquare(pcm)

    if !isCapturing {
      // The room's level is the quiet end of the last few seconds, so steady background sound
      // raises it and only something clearly louder is taken for a person speaking.
      // Measured over about four seconds whatever size the microphone's buffers are.
      recentLevels.append((level, seconds))
      recentSeconds += seconds
      while recentSeconds > 4, recentLevels.count > 1 {
        recentSeconds -= recentLevels.removeFirst().seconds
      }
      secondsSinceRoomUpdate += seconds
      if recentSeconds >= 0.5, secondsSinceRoomUpdate >= 0.25 {
        secondsSinceRoomUpdate = 0
        roomLevel = recentLevels.map(\.level).sorted()[recentLevels.count / 5]
      }
    }

    var threshold = max(configuration.minimumSpeechLevel, roomLevel * configuration.roomMultiplier)
    if isCapturing {
      if level > threshold {
        speakerLevel = speakerLevel == 0 ? level : speakerLevel * 0.9 + level * 0.1
      }
      threshold = max(threshold, speakerLevel * configuration.speakerShare)
    }

    lastLevel = level
    lastThreshold = threshold
    if level == 0 {
      silentBuffers += 1
      if silentBuffers >= 3 { keyHeld = false }
    } else {
      if silentBuffers >= 3 { keyHeld = true }
      silentBuffers = 0
    }
    if !isCapturing {
      leadIn.append(pcm)
      leadInSeconds += seconds
      while leadInSeconds > configuration.leadInDuration, leadIn.count > 1 {
        let dropped = leadIn.removeFirst()
        leadInSeconds -=
          Double(dropped.count / MemoryLayout<Int16>.size) / configuration.sampleRate
      }
      loudSeconds = level > threshold ? loudSeconds + seconds : max(0, loudSeconds - seconds)
      guard loudSeconds >= configuration.startDuration else { return [] }
      isCapturing = true
      captured = leadIn.reduce(into: Data()) { $0.append($1) }
      capturedSeconds = leadInSeconds
      leadIn.removeAll()
      leadInSeconds = 0
      loudSeconds = 0
      quietSeconds = 0
      speakerLevel = level
      captureIsDeliberate = keyHeld
      return [.speechStarted]
    }

    captured.append(pcm)
    capturedSeconds += seconds
    // A voice rises and falls from one syllable to the next. Sound that holds one level for two
    // seconds is something switched on in the room, so it becomes the new room level and the
    // capture it started is allowed to end.
    captureLevels.append((level, seconds))
    var window = captureLevels.reduce(0) { $0 + $1.seconds }
    while window - (captureLevels.first?.seconds ?? 0) >= 2, captureLevels.count > 1 {
      window -= captureLevels.removeFirst().seconds
    }
    if window >= 2, let lowest = captureLevels.map(\.level).min(),
      let highest = captureLevels.map(\.level).max(), lowest > highest * 0.7
    {
      roomLevel = max(roomLevel, highest)
      recentLevels = [(highest, 4)]
      recentSeconds = 4
      threshold = max(threshold, roomLevel * configuration.roomMultiplier)
    }
    // Push to talk sends true silence once the key is released, which ends the request at once.
    let quiet = level == 0 ? seconds * 4 : seconds
    quietSeconds = level > threshold ? 0 : quietSeconds + quiet
    guard
      quietSeconds >= configuration.endDuration
        || capturedSeconds >= configuration.maximumDuration
    else { return [] }
    let deliberate = captureIsDeliberate
    return [.speechEnded(finishCapture(), deliberate: deliberate)]
  }

  /// Ends any request in progress, for example when voice is interrupted or put to sleep.
  public mutating func reset() {
    _ = finishCapture()
    leadIn.removeAll()
    leadInSeconds = 0
    loudSeconds = 0
  }

  /// True when a finished capture is long enough to be worth transcribing.
  public func isLongEnough(_ pcm: Data) -> Bool {
    Double(pcm.count / MemoryLayout<Int16>.size) / configuration.sampleRate
      >= configuration.minimumDuration
  }

  private mutating func finishCapture() -> Data {
    let audio = captured
    captured = Data()
    captureLevels.removeAll()
    capturedSeconds = 0
    quietSeconds = 0
    speakerLevel = 0
    isCapturing = false
    return audio
  }

  static func rootMeanSquare(_ pcm: Data) -> Double {
    let frames = pcm.count / MemoryLayout<Int16>.size
    guard frames > 0 else { return 0 }
    var sum = 0.0
    pcm.withUnsafeBytes { raw in
      for frame in 0..<frames {
        let sample = Int16(
          littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))
        let value = Double(sample) / Double(Int16.max)
        sum += value * value
      }
    }
    return (sum / Double(frames)).squareRoot()
  }

  /// 24 kHz samples at the 16 kHz the speech and voice models expect.
  public static func resampledTo16k(_ samples: [Float], from sampleRate: Double) -> [Float] {
    guard sampleRate != 16_000, !samples.isEmpty else { return samples }
    let ratio = sampleRate / 16_000
    let count = Int(Double(samples.count) / ratio)
    var output = [Float](repeating: 0, count: count)
    for index in 0..<count {
      let position = Double(index) * ratio
      let lower = Int(position)
      let upper = min(lower + 1, samples.count - 1)
      let fraction = Float(position - Double(lower))
      output[index] = samples[lower] * (1 - fraction) + samples[upper] * fraction
    }
    return output
  }

  /// Signed 16-bit PCM as the floating-point samples a recogniser expects.
  public static func floatSamples(_ pcm: Data) -> [Float] {
    let frames = pcm.count / MemoryLayout<Int16>.size
    var samples = [Float](repeating: 0, count: frames)
    pcm.withUnsafeBytes { raw in
      for frame in 0..<frames {
        let sample = Int16(
          littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))
        samples[frame] = Float(sample) / Float(Int16.max)
      }
    }
    return samples
  }
}

/// Cuts a reply that is still being written into pieces short enough to speak straight away.
///
/// Speech is made one piece at a time while the previous piece plays. Whole sentences come first;
/// a long sentence is cut again at its commas, because a long piece takes longer to make than the
/// short one before it takes to play, and that gap is heard as dead air.
public struct SpokenSentenceSplitter: Sendable {
  private var buffer = ""
  private let clauseLimit: Int

  public init(clauseLimit: Int = 70) {
    self.clauseLimit = clauseLimit
  }

  /// Adds newly written text and returns the pieces that are now complete.
  public mutating func append(_ text: String) -> [String] {
    buffer += text
    var sentences: [String] = []
    var start = buffer.startIndex
    var index = buffer.startIndex
    while index < buffer.endIndex {
      let character = buffer[index]
      let next = buffer.index(after: index)
      if ".!?".contains(character), next < buffer.endIndex, buffer[next].isWhitespace {
        sentences.append(String(buffer[start...index]))
        start = next
      }
      index = next
    }
    buffer = String(buffer[start...])
    return pieces(from: merged(sentences))
  }

  /// Returns whatever is left, once the reply or a block of it has ended.
  public mutating func flush() -> [String] {
    let rest = buffer
    buffer = ""
    return pieces(from: [rest])
  }

  /// A very short sentence ("Ah.") sounds clipped alone, so it stays with what follows it.
  private func merged(_ sentences: [String]) -> [String] {
    var result: [String] = []
    for sentence in sentences {
      if let last = result.last, last.trimmingCharacters(in: .whitespaces).count < 14 {
        result[result.count - 1] = last + sentence
      } else {
        result.append(sentence)
      }
    }
    return result
  }

  private func pieces(from sentences: [String]) -> [String] {
    sentences.flatMap(clauses).map(Self.spoken).filter { !$0.isEmpty }
  }

  private func clauses(_ sentence: String) -> [String] {
    guard sentence.count > clauseLimit else { return [sentence] }
    var parts: [String] = []
    var current = ""
    for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
      current += current.isEmpty ? String(word) : " " + word
      if let last = word.last, ",;:".contains(last), current.count >= 28 {
        parts.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      if current.count < 18, let last = parts.popLast() {
        parts.append(last + " " + current)
      } else {
        parts.append(current)
      }
    }
    return parts
  }

  /// Removes what a speech engine would read out as noise.
  static func spoken(_ text: String) -> String {
    var result = text
    for marker in ["```", "**", "__", "`", "#"] {
      result = result.replacingOccurrences(of: marker, with: "")
    }
    result = result.replacingOccurrences(of: "*", with: "")
    return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

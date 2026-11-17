import Foundation
import os

/// What Otto knows about how one person sounds: a few short lists of numbers, never a recording.
///
/// A single sample is a thin picture of a voice, because people speak differently when reading,
/// asking and answering. So the print holds several, taken from sentences that were certainly the
/// person's own, and a new sound is compared with whichever of them it resembles most.
public struct Voiceprint: Codable, Equatable, Sendable {
  /// How many sentences Otto needs before it will turn other voices away.
  public static let sentencesNeeded = 3
  public static let capacity = 8

  public private(set) var samples: [[Float]]

  public init(samples: [[Float]] = []) {
    self.samples = samples
  }

  public var isReady: Bool { samples.count >= Self.sentencesNeeded }

  /// Starts again from a deliberate recording of the person, cut into several samples.
  public mutating func replace(with embeddings: [[Float]]) {
    samples = Array(embeddings.filter { !$0.isEmpty }.prefix(Self.capacity))
  }

  /// Adds a sentence known to be the person's. The earliest ones stay as an anchor so the print
  /// cannot drift, sentence by sentence, into someone else's voice; later ones are replaced.
  public mutating func learn(_ embedding: [Float]) {
    guard !embedding.isEmpty else { return }
    samples.append(embedding)
    if samples.count > Self.capacity {
      samples.remove(at: Self.sentencesNeeded)
    }
  }

  /// From about 0 (a stranger) to 1 (the same voice), against the closest stored sample.
  public func match(_ embedding: [Float]) -> Float? {
    guard isReady else { return nil }
    return samples.map { Self.similarity($0, embedding) }.max()
  }

  static func similarity(_ first: [Float], _ second: [Float]) -> Float {
    guard first.count == second.count, !first.isEmpty else { return 0 }
    var product: Float = 0
    var firstLength: Float = 0
    var secondLength: Float = 0
    for index in first.indices {
      product += first[index] * second[index]
      firstLength += first[index] * first[index]
      secondLength += second[index] * second[index]
    }
    let scale = (firstLength * secondLength).squareRoot()
    return scale > 0 ? product / scale : 0
  }
}

public enum VoiceprintStatus: Sendable, Equatable {
  /// The models that recognise speech and voices are not loaded yet, or could not be.
  case unavailable
  case learning(heard: Int, needed: Int)
  case ready
}

/// Decides whether a captured sound is a request from the person Otto belongs to.
public protocol LocalVoiceFiltering: Sendable {
  /// Only the stretches of 16 kHz audio that contain speech; nil when that cannot be judged yet.
  func speech(in samples: [Float]) async -> [Float]?
  /// How closely speech matches the learned voice; nil until a voice has been learned.
  func match(_ speech: [Float]) async -> Float?
  /// Adds speech that is certainly the person's own to what Otto knows of their voice.
  func learn(_ speech: [Float]) async
  /// Learns the voice in one go from a recording of the person reading aloud. Returns false
  /// when the recording held too little speech to learn from.
  func enroll(_ samples: [Float]) async -> Bool
  func status() async -> VoiceprintStatus
  func forget() async
}

/// Where a voiceprint is kept: one small file on this Mac, readable only by its owner.
public struct VoiceprintStore: Sendable {
  public var url: URL

  public init(url: URL = VoiceprintStore.defaultURL()) {
    self.url = url
  }

  public static func defaultURL(fileManager: FileManager = .default) -> URL {
    fileManager.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Otto/VoiceModels/Voiceprint/voiceprint.json")
  }

  public func load() -> Voiceprint {
    guard let data = try? Data(contentsOf: url),
      let print = try? JSONDecoder().decode(Voiceprint.self, from: data)
    else { return Voiceprint() }
    return print
  }

  public func save(_ voiceprint: Voiceprint) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(voiceprint).write(to: url, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")
        .error("Could not save the voiceprint: \(error.localizedDescription, privacy: .public)")
    }
  }

  public func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}

#if canImport(FluidAudio)
  import FluidAudio

  /// The voice filter that ships: a speech detector and a speaker model, both on this Mac.
  ///
  /// The models load in the background the first time local voice is used. Until they have,
  /// every sound is let through, exactly as before the filter existed.
  public actor OnDeviceVoiceFilter: LocalVoiceFiltering {
    private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")
    private let store: VoiceprintStore
    private var voiceprint: Voiceprint
    private var detector: VadManager?
    private var speakerModel: SpeakerModel?
    private var preparation: Task<Void, Never>?

    /// `DiarizerManager` is not safe to share across threads; this actor is its only user.
    private final class SpeakerModel: @unchecked Sendable {
      let manager: DiarizerManager
      init(_ manager: DiarizerManager) { self.manager = manager }
    }

    private var mayDownload: Bool

    /// `mayDownload` is the person's consent to fetch the two small models (about 14 MB). Without
    /// it the filter only loads models that are already on this Mac.
    public init(store: VoiceprintStore = VoiceprintStore(), mayDownload: Bool = false) {
      self.store = store
      self.mayDownload = mayDownload
      voiceprint = store.load()
    }

    /// Whether the models are already on this Mac, so loading them downloads nothing.
    public static func isDownloaded(fileManager: FileManager = .default) -> Bool {
      let models = fileManager.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/FluidAudio/Models")
      return ["speaker-diarization", "silero-vad-coreml"].allSatisfy {
        fileManager.fileExists(atPath: models.appending(path: $0).path)
      }
    }

    public func approveDownload() {
      mayDownload = true
      prepare()
    }

    public var isReady: Bool { detector != nil }

    public func prepare() {
      guard preparation == nil, detector == nil else { return }
      guard mayDownload || Self.isDownloaded() else { return }
      preparation = Task {
        do {
          let detector = try await VadManager()
          let manager = DiarizerManager()
          manager.initialize(models: try await DiarizerModels.downloadIfNeeded())
          self.finishPreparing(detector, SpeakerModel(manager))
        } catch {
          Self.logger.error(
            "Voice filter could not load: \(String(reflecting: error), privacy: .public)")
          self.preparation = nil
        }
      }
    }

    private func finishPreparing(_ detector: VadManager, _ speakerModel: SpeakerModel) {
      self.detector = detector
      self.speakerModel = speakerModel
      preparation = nil
      Self.logger.info("Voice filter ready")
    }

    public func speech(in samples: [Float]) async -> [Float]? {
      guard let detector else {
        prepare()
        return nil
      }
      guard let segments = try? await detector.segmentSpeechAudio(samples) else { return nil }
      return segments.flatMap { $0 }
    }

    private func embedding(_ speech: [Float]) -> [Float]? {
      // Under half a second there is too little voice to tell one person from another.
      guard let speakerModel, speech.count >= 8_000 else { return nil }
      return try? speakerModel.manager.extractSpeakerEmbedding(from: speech)
    }

    public func match(_ speech: [Float]) async -> Float? {
      guard voiceprint.isReady, let embedding = embedding(speech) else { return nil }
      return voiceprint.match(embedding)
    }

    public func learn(_ speech: [Float]) async {
      // A full sentence, so one clipped word cannot stand for the whole voice.
      guard speech.count >= 24_000, let embedding = embedding(speech) else { return }
      voiceprint.learn(embedding)
      store.save(voiceprint)
      Self.logger.info(
        "Learned a sentence; voiceprint has \(self.voiceprint.samples.count, privacy: .public)")
    }

    public func enroll(_ samples: [Float]) async -> Bool {
      prepare()
      await preparation?.value
      guard let detector, let segments = try? await detector.segmentSpeechAudio(samples) else {
        return false
      }
      let speech = segments.flatMap { $0 }
      // Four seconds of actual speech, cut in three, gives three independent samples.
      guard speech.count >= 64_000 else { return false }
      let third = speech.count / 3
      let embeddings = (0..<3).compactMap { index in
        embedding(Array(speech[(index * third)..<((index + 1) * third)]))
      }
      guard embeddings.count == 3 else { return false }
      voiceprint.replace(with: embeddings)
      store.save(voiceprint)
      Self.logger.info("Learned the voice from a recording")
      return true
    }

    public func status() async -> VoiceprintStatus {
      if voiceprint.isReady { return .ready }
      guard detector != nil else {
        prepare()
        return voiceprint.samples.isEmpty
          ? .unavailable
          : .learning(heard: voiceprint.samples.count, needed: Voiceprint.sentencesNeeded)
      }
      return .learning(heard: voiceprint.samples.count, needed: Voiceprint.sentencesNeeded)
    }

    public func forget() async {
      voiceprint = Voiceprint()
      store.remove()
    }
  }
#endif

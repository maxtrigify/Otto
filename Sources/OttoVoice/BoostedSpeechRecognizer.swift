import Foundation
import os

/// A name Otto should recognise when it is spoken: a harness, a model, a bot, a project.
///
/// No speech model has heard these words, so left alone it writes the nearest ordinary ones.
/// `soundsLike` lists what it tends to write instead, so those can be put right.
public struct SpokenName: Hashable, Sendable {
  public var text: String
  public var soundsLike: [String]
  /// One of Otto's own words or a harness, chosen by hand, as opposed to whatever a bot,
  /// session, model or project happens to be called.
  public var isOttosOwn: Bool

  public init(_ text: String, soundsLike: [String] = [], isOttosOwn: Bool = false) {
    self.text = text
    self.soundsLike = soundsLike
    self.isOttosOwn = isOttosOwn
  }

  /// The names worth teaching a recogniser: long enough to be told apart from ordinary speech,
  /// each listed once, and few enough that looking for them stays quick.
  public static func teachable(_ names: [SpokenName], limit: Int = 120) -> [SpokenName] {
    var seen: Set<String> = []
    var kept: [SpokenName] = []
    for name in names {
      let text = name.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.count >= 3, text.count <= 40, text.contains(where: \.isLetter) else { continue }
      // A short single word is too easily mistaken for an ordinary one ("Ling" for "using").
      // Otto's own names are listed with care and exempt; everything else must be distinctive.
      if !name.isOttosOwn, !text.contains(" "), text.count < 6 { continue }
      guard seen.insert(text.lowercased()).inserted else { continue }
      kept.append(SpokenName(text, soundsLike: name.soundsLike, isOttosOwn: name.isOttosOwn))
      if kept.count == limit { break }
    }
    return kept
  }
}

#if canImport(FluidAudio)
  import FluidAudio

  /// Hears with Parakeet Ultra on this Mac's Neural Engine, then checks what it wrote against
  /// the names Otto knows, so "codecs" spoken in a request for a harness comes out as "Codex".
  ///
  /// Ultra is a more accurate retraining of the Parakeet model Otto has always used. Its models
  /// are a large download, so until they are on this Mac and loaded, the recogniser given as
  /// `fallback` does the hearing and nothing is lost by choosing this one.
  public actor BoostedSpeechRecognizer: LocalSpeechRecognizing {
    public enum Readiness: Sendable, Equatable {
      case notStarted
      case preparing
      case ready
      case failed(String)
    }

    public private(set) var readiness = Readiness.notStarted

    private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")
    private var fallback: (any LocalSpeechRecognizing)?
    private var mayDownload: Bool
    private var manager: AsrManager?
    private var nameModels: CtcModels?
    private var names: [SpokenName] = []
    private var boosting: VocabularyBoostingSession?
    private var boostingIsCurrent = true
    private var preparation: Task<Void, Never>?

    public init(fallback: (any LocalSpeechRecognizing)?, mayDownload: Bool = false) {
      self.fallback = fallback
      self.mayDownload = mayDownload
    }

    /// The older recogniser changes when the person installs or removes it.
    public func use(fallback: (any LocalSpeechRecognizing)?) {
      self.fallback = fallback
    }

    /// Whether the models are already on this Mac, so loading them downloads nothing.
    public static func isDownloaded() -> Bool {
      AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra)
    }

    /// The person has agreed to the download: fetch the models and load them.
    public func approveDownload() {
      mayDownload = true
      if case .failed = readiness { readiness = .notStarted }
      startLoading()
    }

    /// The names to listen for. They change as bots and sessions come and go, so the next
    /// request is heard against the current list.
    public func listen(for names: [SpokenName]) {
      let teachable = SpokenName.teachable(names)
      guard teachable != self.names else { return }
      self.names = teachable
      boostingIsCurrent = false
      // Prepared now, between requests, so no request ever waits for it.
      Task { await self.refreshBoosting() }
    }

    public func prepare() async throws {
      startLoading()
      do {
        guard let fallback else { throw LocalVoiceError.recognizerMissing }
        try await fallback.prepare()
      } catch {
        // Without the older recogniser there is nothing to hear with until Ultra has loaded.
        await preparation?.value
        guard manager != nil else { throw error }
      }
    }

    private func startLoading() {
      guard preparation == nil, manager == nil else { return }
      guard mayDownload || Self.isDownloaded() else { return }
      readiness = .preparing
      preparation = Task {
        let started = ContinuousClock.now
        do {
          let models = try await AsrModels.downloadAndLoad(version: .ultra)
          let manager = AsrManager(config: .default)
          try await manager.loadModels(models)
          // The names are checked by a second, small model. Hearing works without it.
          let nameModels = try? await CtcModels.downloadAndLoad()
          self.finishLoading(
            manager, nameModels: nameModels,
            seconds: (ContinuousClock.now - started).components.seconds)
        } catch {
          self.failLoading(error)
        }
      }
    }

    private func finishLoading(_ manager: AsrManager, nameModels: CtcModels?, seconds: Int64) {
      self.manager = manager
      self.nameModels = nameModels
      boostingIsCurrent = false
      preparation = nil
      Task { await self.warmUp(manager) }
      Self.logger.info(
        "Parakeet Ultra ready after \(seconds, privacy: .public)s, names \(nameModels == nil ? "unavailable" : "available", privacy: .public)"
      )
    }

    /// The first thing a model hears after loading takes seconds while the Neural Engine
    /// settles, and the names take a moment to prepare. Both are spent here, on silence, so the
    /// person's first request is as quick as every later one.
    private func warmUp(_ manager: AsrManager) async {
      let silence = [Float](repeating: 0, count: 16_000)
      var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
      _ = try? await manager.transcribe(silence, decoderState: &state)
      await refreshBoosting()
      if let boosting {
        _ = await boosting.rescore(
          text: "hello",
          tokenTimings: [
            TokenTiming(token: "hello", tokenId: 0, startTime: 0, endTime: 0.5, confidence: 1)
          ], audioSamples: silence)
      }
      readiness = .ready
    }

    private func failLoading(_ error: any Error) {
      readiness = .failed(error.localizedDescription)
      preparation = nil
      Self.logger.error(
        "Parakeet Ultra could not load: \(String(reflecting: error), privacy: .public)")
    }

    public func text(samples: [Float], sampleRate: Int) async throws -> String {
      guard let manager, readiness == .ready else {
        startLoading()
        guard let fallback else { throw LocalVoiceError.recognizerMissing }
        return try await fallback.text(samples: samples, sampleRate: sampleRate)
      }
      let audio = LocalVoiceEndpointer.resampledTo16k(samples, from: Double(sampleRate))
      do {
        let began = ContinuousClock.now
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        let transcribed = ContinuousClock.now
        let text = await named(result, audio: audio)
        Self.logger.info(
          "transcribed in \(Self.milliseconds(transcribed - began), privacy: .public) ms, names checked in \(Self.milliseconds(ContinuousClock.now - transcribed), privacy: .public) ms"
        )
        return text
      } catch {
        Self.logger.error(
          "Parakeet Ultra could not hear a request: \(String(reflecting: error), privacy: .public)")
        guard let fallback else { throw error }
        return try await fallback.text(samples: samples, sampleRate: sampleRate)
      }
    }

    /// Puts right any of Otto's names the model wrote as ordinary words. A name is only written
    /// in when the sound of the recording supports it better than what the model wrote.
    private func named(_ result: ASRResult, audio: [Float]) async -> String {
      guard let boosting, let timings = result.tokenTimings, !timings.isEmpty,
        let rescored = await boosting.rescore(
          text: result.text, tokenTimings: timings, audioSamples: audio)
      else { return result.text }
      if rescored.wasModified {
        Self.logger.info(
          "put right \(rescored.replacements.count, privacy: .public) of Otto's names")
        // The development build keeps both versions, so a name written in wrongly can be seen.
        if Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true {
          Self.logger.info(
            "before names: \(result.text, privacy: .public) | after: \(rescored.text, privacy: .public)"
          )
        }
      }
      return rescored.text
    }

    /// How alike what was heard and a name must be before the name is written in its place.
    static let nameSimilarity: Float = 0.85

    static func milliseconds(_ duration: Duration) -> Int {
      Int(duration.components.seconds * 1000)
        + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private func refreshBoosting() async {
      guard !boostingIsCurrent else { return }
      boostingIsCurrent = true
      guard let nameModels, !names.isEmpty else {
        boosting = nil
        return
      }
      let terms = names.map { name in
        CustomVocabularyTerm(
          text: name.text, aliases: name.soundsLike.isEmpty ? nil : name.soundsLike)
      }
      do {
        // Strict on purpose. Left at the library's settings, a name replaces any ordinary word
        // that sounds a little like it: "using" became the model name "Ling" and "open a Codex"
        // became "OpenCode", turning a request that had been heard correctly into nonsense.
        // A name is now written in only where what was heard is nearly that name already, or
        // is one of the mishearings listed for it.
        boosting = try await VocabularyBoostingSession(
          vocabulary: CustomVocabularyContext(terms: terms, minSimilarity: Self.nameSimilarity),
          ctcModels: nameModels,
          config: VocabularyRescorer.Config(
            shortTermCbwTaperPivot: 5, spotterRescueEnabled: false))
      } catch {
        boosting = nil
        Self.logger.error(
          "Otto's names could not be prepared: \(String(reflecting: error), privacy: .public)")
      }
    }

    public func shutdown() async {
      await fallback?.shutdown()
    }
  }
#endif

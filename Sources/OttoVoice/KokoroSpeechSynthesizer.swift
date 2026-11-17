#if canImport(FluidAudio)
  import FluidAudio
  import Foundation
  import os

  /// Speaks with Kokoro, an open-source neural voice, running on this Mac through Core ML.
  ///
  /// The model is about 430 MB and is downloaded and prepared the first time it is needed, which
  /// takes around a minute. Voice must not be silent for that minute, so until Kokoro is ready,
  /// and again if it ever fails, the built-in macOS voice speaks instead.
  public actor KokoroSpeechSynthesizer: LocalSpeechSynthesizing {
    public enum Readiness: Sendable, Equatable {
      case notStarted
      case preparing
      case ready
      case failed(String)
    }

    /// A calm British male voice; the one chosen for Otto in listening tests.
    public static let defaultVoice = "bm_daniel"

    /// Where the model lives, beside Otto's other voice models.
    public static func modelsDirectory(fileManager: FileManager = .default) -> URL {
      fileManager.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Otto/VoiceModels/Kokoro")
    }

    public private(set) var readiness = Readiness.notStarted

    private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")
    private let voice: String
    private let speed: Float
    private let directory: URL
    private let fallback: any LocalSpeechSynthesizing
    private var manager: KokoroAneManager?
    private var preparation: Task<Void, Never>?
    private var mayDownload: Bool

    public init(
      voice: String = KokoroSpeechSynthesizer.defaultVoice,
      speed: Float = 1.0,
      directory: URL = KokoroSpeechSynthesizer.modelsDirectory(),
      fallback: any LocalSpeechSynthesizing = SystemSpeechSynthesizer(),
      mayDownload: Bool = false
    ) {
      self.mayDownload = mayDownload
      self.voice = voice
      self.speed = speed
      self.directory = directory
      self.fallback = fallback
    }

    /// Whether the model is already on this Mac, so loading it downloads nothing.
    public static func isDownloaded(
      directory: URL = KokoroSpeechSynthesizer.modelsDirectory(),
      fileManager: FileManager = .default
    ) -> Bool {
      let model = directory.appending(path: "kokoro-82m-coreml")
      return ((try? fileManager.contentsOfDirectory(atPath: model.path)) ?? []).isEmpty == false
    }

    /// The person has agreed to the download: fetch the model and load it.
    public func download() {
      mayDownload = true
      if case .failed = readiness { readiness = .notStarted }
      prepare()
    }

    /// Loads the model without waiting for it. Nothing is downloaded without the person's
    /// consent: until then, and whenever the model is missing, the macOS voice speaks.
    public func prepare() {
      guard preparation == nil, manager == nil else { return }
      guard mayDownload || Self.isDownloaded(directory: directory) else { return }
      readiness = .preparing
      preparation = Task { [voice, directory] in
        let started = ContinuousClock.now
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          // The library's newer "v3" runtime is several times quicker but runs part of the voice
          // on the graphics chip, and on macOS 27 that aborts the whole app from inside Metal
          // (its notes list this as still unfixed). It crashed Otto five times in two days,
          // mid-sentence. The standard runtime keeps Metal out of the chain.
          let manager = KokoroAneManager(defaultVoice: voice, directory: directory)
          try await manager.initialize(preloadVoices: [voice])
          // Kokoro's own text reader only knows American pronunciation. A British voice given
          // American sounds says "skedule" and "wadder" and never sounds right.
          if voice.hasPrefix("b"), let british = Self.britishPronunciations(in: directory) {
            await manager.setEnglishCustomLexicon(british)
          }
          // The first sentence after loading is slow; spend that here, not on a real reply.
          _ = try await manager.synthesizeDetailed(text: "Ready.", voice: voice)
          self.finishPreparing(manager, seconds: (ContinuousClock.now - started).components.seconds)
        } catch {
          self.failPreparing(error)
        }
      }
    }

    private func finishPreparing(_ manager: KokoroAneManager, seconds: Int64) {
      self.manager = manager
      readiness = .ready
      preparation = nil
      Self.logger.info("Kokoro voice ready after \(seconds, privacy: .public)s")
    }

    private func failPreparing(_ error: any Error) {
      readiness = .failed(error.localizedDescription)
      preparation = nil
      Self.logger.error(
        "Kokoro voice could not load: \(String(reflecting: error), privacy: .public)")
    }

    public func speech(for text: String) async throws -> Data {
      if manager == nil {
        prepare()
        // The voice is on this Mac and still loading, as it is for the first minute after Otto
        // opens. Waiting is better than answering in the built-in voice and then changing voice
        // mid-conversation; that voice is only for when Kokoro is absent or broken.
        await preparation?.value
      }
      guard let manager else { return try await fallback.speech(for: text) }
      do {
        let began = ContinuousClock.now
        let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
        let took = ContinuousClock.now - began
        Self.logger.info(
          "voiced \(text.count, privacy: .public) characters in \(Int(took.components.seconds * 1000) + Int(took.components.attoseconds / 1_000_000_000_000_000), privacy: .public) ms"
        )
        let audio = Self.pcm16(result.samples)
        guard !audio.isEmpty else { throw LocalSpeechError.noAudio }
        return audio
      } catch {
        Self.logger.error(
          "Kokoro could not speak a reply: \(String(reflecting: error), privacy: .public)")
        return try await fallback.speech(for: text)
      }
    }

    /// British pronunciations for the words Kokoro knows, from the lexicon that arrives with
    /// its model but that it never reads. Nil when that file is not there.
    static func britishPronunciations(in directory: URL) -> [String: String]? {
      struct Lexicon: Decodable {
        var lower: [String: [String]]
        var caseSensitive: [String: [String]]?
      }
      let url = directory.appending(path: "kokoro/gb_lexicon_cache.json")
      guard let data = try? Data(contentsOf: url),
        let lexicon = try? JSONDecoder().decode(Lexicon.self, from: data)
      else { return nil }
      var words = lexicon.lower.mapValues { $0.joined() }
      for (word, sounds) in lexicon.caseSensitive ?? [:] { words[word] = sounds.joined() }
      return words.isEmpty ? nil : words
    }

    /// Kokoro produces 24 kHz floating-point samples; Otto's transport plays 24 kHz 16-bit PCM.
    static func pcm16(_ samples: [Float]) -> Data {
      var output = [Int16](repeating: 0, count: samples.count)
      for index in samples.indices {
        let clamped = max(-1, min(1, samples[index]))
        output[index] = Int16((clamped * Float(Int16.max)).rounded())
      }
      return output.withUnsafeBytes { Data($0) }
    }
  }
#endif

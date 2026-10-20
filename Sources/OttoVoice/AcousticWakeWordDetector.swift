import CryptoKit
import Foundation

#if canImport(LiveKitWakeWord)
  import LiveKitWakeWord
#endif

public struct AcousticWakeWordDetection: Equatable, Sendable {
  public let name: String
  public let confidence: Float
  public let timestamp: Date

  public init(name: String, confidence: Float, timestamp: Date) {
    self.name = name
    self.confidence = confidence
    self.timestamp = timestamp
  }
}

public struct AcousticWakeWordConfiguration: Equatable, Sendable {
  public static let minimumRecall = 0.90
  public static let maximumFalsePositivesPerHour = 0.10
  public static let minimumRealSpeakerCount = 5
  public static let minimumPositiveSamples = 100
  public static let minimumValidationHours = 10.0

  public var classifierURL: URL
  public var threshold: Float
  public var debounce: TimeInterval

  public init(
    classifierURL: URL = Self.defaultClassifierURL,
    threshold: Float? = nil,
    debounce: TimeInterval = 2.0
  ) {
    self.classifierURL = classifierURL
    self.threshold = threshold ?? Self.quality(at: classifierURL)?.threshold ?? 0.68
    self.debounce = debounce
  }

  public static var wakeWordDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Otto/VoiceModels/WakeWord")
  }

  /// A trained `hey_otto.onnx` when one is installed; otherwise the only model trained so far,
  /// `hey_muse.onnx`, which listens for "Hey Muse".
  public static var defaultClassifierURL: URL {
    classifierURL(in: wakeWordDirectory)
  }

  static func classifierURL(
    in directory: URL, fileManager: FileManager = .default
  ) -> URL {
    let otto = directory.appendingPathComponent("hey_otto.onnx")
    if fileManager.fileExists(atPath: otto.path) { return otto }
    return directory.appendingPathComponent("hey_muse.onnx")
  }

  /// The phrase a classifier file was trained on, for honest UI copy.
  public static func phrase(for classifierURL: URL) -> String {
    classifierURL.lastPathComponent.hasPrefix("hey_otto") ? "Hey Otto" : "Hey Muse"
  }

  /// The phrase the default (installed or expected) classifier listens for.
  public static var defaultPhrase: String { phrase(for: defaultClassifierURL) }

  public var phrase: String { Self.phrase(for: classifierURL) }

  public var classifierIsInstalled: Bool {
    FileManager.default.fileExists(atPath: classifierURL.path)
  }

  public var qualityURL: URL {
    classifierURL.deletingPathExtension().appendingPathExtension("quality.json")
  }

  public var installedQuality: AcousticWakeWordModelQuality? {
    Self.quality(at: classifierURL)
  }

  public var classifierIsProductionReady: Bool {
    guard classifierIsInstalled, let quality = installedQuality, quality.passesReleaseGate else {
      return false
    }
    guard let data = try? Data(contentsOf: classifierURL) else { return false }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return digest == quality.modelSHA256.lowercased()
  }

  private static func quality(at classifierURL: URL) -> AcousticWakeWordModelQuality? {
    let url = classifierURL.deletingPathExtension().appendingPathExtension("quality.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(AcousticWakeWordModelQuality.self, from: data)
  }
}

public struct AcousticWakeWordModelQuality: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var evaluatedAt: String
  public var threshold: Float
  public var recall: Double
  public var falsePositivesPerHour: Double
  public var positiveSamples: Int
  public var negativeSamples: Int
  public var validationHours: Double
  public var realSpeakerCount: Int
  public var corpusKind: String
  public var modelSHA256: String

  public init(
    schemaVersion: Int = 1,
    evaluatedAt: String,
    threshold: Float,
    recall: Double,
    falsePositivesPerHour: Double,
    positiveSamples: Int,
    negativeSamples: Int,
    validationHours: Double,
    realSpeakerCount: Int,
    corpusKind: String,
    modelSHA256: String
  ) {
    self.schemaVersion = schemaVersion
    self.evaluatedAt = evaluatedAt
    self.threshold = threshold
    self.recall = recall
    self.falsePositivesPerHour = falsePositivesPerHour
    self.positiveSamples = positiveSamples
    self.negativeSamples = negativeSamples
    self.validationHours = validationHours
    self.realSpeakerCount = realSpeakerCount
    self.corpusKind = corpusKind
    self.modelSHA256 = modelSHA256
  }

  public var passesReleaseGate: Bool {
    schemaVersion == 1
      && corpusKind == "held-out-real-speakers"
      && realSpeakerCount >= AcousticWakeWordConfiguration.minimumRealSpeakerCount
      && positiveSamples >= AcousticWakeWordConfiguration.minimumPositiveSamples
      && negativeSamples > 0
      && validationHours >= AcousticWakeWordConfiguration.minimumValidationHours
      && recall >= AcousticWakeWordConfiguration.minimumRecall
      && falsePositivesPerHour <= AcousticWakeWordConfiguration.maximumFalsePositivesPerHour
      && threshold > 0
      && threshold < 1
      && modelSHA256.count == 64
  }
}

public enum AcousticWakeWordError: Error, LocalizedError, Equatable {
  case runtimeNotLinked
  case classifierMissing(URL)
  case classifierUnqualified(URL)

  public var errorDescription: String? {
    switch self {
    case .runtimeNotLinked:
      "The acoustic wake-word runtime is not included in this build."
    case .classifierMissing(let url):
      "The trained \(AcousticWakeWordConfiguration.phrase(for: url)) classifier is missing at \(url.path)."
    case .classifierUnqualified(let url):
      "The \(AcousticWakeWordConfiguration.phrase(for: url)) classifier has not passed real-speaker release "
        + "qualification at \(url.path)."
    }
  }
}

public protocol AcousticWakeWordDetecting: Sendable {
  var detections: AsyncStream<AcousticWakeWordDetection> { get }
  func start() async throws
  func stop() async
}

public enum AcousticWakeWordDetectorFactory {
  public static var runtimeIsLinked: Bool {
    #if canImport(LiveKitWakeWord)
      true
    #else
      false
    #endif
  }

  public static func make(
    configuration: AcousticWakeWordConfiguration = AcousticWakeWordConfiguration()
  ) throws -> any AcousticWakeWordDetecting {
    guard configuration.classifierIsInstalled else {
      throw AcousticWakeWordError.classifierMissing(configuration.classifierURL)
    }
    guard configuration.classifierIsProductionReady else {
      throw AcousticWakeWordError.classifierUnqualified(configuration.qualityURL)
    }
    #if canImport(LiveKitWakeWord)
      return try LiveKitAcousticWakeWordDetector(configuration: configuration)
    #else
      throw AcousticWakeWordError.runtimeNotLinked
    #endif
  }
}

#if canImport(LiveKitWakeWord)
  /// A raw-audio detector. Otto owns capture instead of using LiveKit's stock listener so the same
  /// macOS acoustic echo cancellation used by cloud voice also protects wake-word inference.
  public actor LiveKitAcousticWakeWordDetector: AcousticWakeWordDetecting {
    public nonisolated let detections: AsyncStream<AcousticWakeWordDetection>

    private let configuration: AcousticWakeWordConfiguration
    private let continuation: AsyncStream<AcousticWakeWordDetection>.Continuation
    private let transport: AVFoundationVoiceAudioTransport
    private var model: WakeWordModel?
    private var ringBuffer: [Int16] = []
    private var writeIndex = 0
    private var samplesWritten = 0
    private var inferenceInFlight = false
    private var lastPredictionAt = Date.distantPast
    private var lastDetectionAt: [String: Date] = [:]
    private var runID = UUID()

    public init(configuration: AcousticWakeWordConfiguration) throws {
      guard configuration.classifierIsInstalled else {
        throw AcousticWakeWordError.classifierMissing(configuration.classifierURL)
      }
      self.configuration = configuration
      transport = AVFoundationVoiceAudioTransport()
      let pair = AsyncStream<AcousticWakeWordDetection>.makeStream()
      detections = pair.stream
      continuation = pair.continuation
    }

    public func start() async throws {
      guard model == nil else { return }
      let inputSampleRate = UInt32(AVFoundationVoiceAudioTransport.providerSampleRate)
      let model = try WakeWordModel(
        models: [configuration.classifierURL],
        sampleRate: inputSampleRate,
        executionProvider: .coreML
      )
      self.model = model
      ringBuffer = [Int16](repeating: 0, count: Int(inputSampleRate) * 2)
      writeIndex = 0
      samplesWritten = 0
      inferenceInFlight = false
      lastPredictionAt = .distantPast
      lastDetectionAt = [:]
      runID = UUID()
      do {
        try await transport.startInput { [weak self] data in
          Task { await self?.ingest(data) }
        }
      } catch {
        self.model = nil
        ringBuffer = []
        throw error
      }
    }

    public func stop() async {
      runID = UUID()
      await transport.stop()
      model = nil
      ringBuffer = []
      writeIndex = 0
      samplesWritten = 0
      inferenceInFlight = false
    }

    private func ingest(_ data: Data) {
      guard let model, !ringBuffer.isEmpty, data.count >= MemoryLayout<Int16>.size else { return }
      let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
      for sample in samples {
        ringBuffer[writeIndex] = sample
        writeIndex = (writeIndex + 1) % ringBuffer.count
      }
      samplesWritten = min(samplesWritten + samples.count, ringBuffer.count)
      let now = Date()
      guard samplesWritten == ringBuffer.count,
        !inferenceInFlight,
        now.timeIntervalSince(lastPredictionAt) >= 0.02
      else { return }

      var snapshot = Array(ringBuffer[writeIndex...])
      if writeIndex > 0 { snapshot.append(contentsOf: ringBuffer[..<writeIndex]) }
      inferenceInFlight = true
      lastPredictionAt = now
      let currentRunID = runID
      Task.detached { [weak self, model, snapshot] in
        let result = Result { try model.predict(snapshot) }
        await self?.finishInference(result, runID: currentRunID)
      }
    }

    private func finishInference(
      _ result: Result<[String: Float], Error>,
      runID expectedRunID: UUID
    ) {
      guard runID == expectedRunID, model != nil else { return }
      inferenceInFlight = false
      guard case .success(let scores) = result,
        let match = scores.max(by: { $0.value < $1.value }),
        match.value >= configuration.threshold
      else { return }
      let now = Date()
      if let previous = lastDetectionAt[match.key],
        now.timeIntervalSince(previous) < configuration.debounce
      {
        return
      }
      lastDetectionAt[match.key] = now
      continuation.yield(
        AcousticWakeWordDetection(name: match.key, confidence: match.value, timestamp: now))
    }
  }
#endif

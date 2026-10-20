@preconcurrency import AVFoundation
import Foundation

public struct WakeWordQualificationRecording: Sendable, Equatable {
  public var url: URL
  public var duration: TimeInterval

  public init(url: URL, duration: TimeInterval) {
    self.url = url
    self.duration = duration
  }
}

public enum WakeWordQualificationRecorderError: Error, LocalizedError, Equatable {
  case alreadyRecording
  case notRecording
  case recordingTooShort
  case invalidAudio

  public var errorDescription: String? {
    switch self {
    case .alreadyRecording: "A qualification recording is already in progress."
    case .notRecording: "No qualification recording is in progress."
    case .recordingTooShort: "Record at least half a second before saving the sample."
    case .invalidAudio: "Otto could not write the qualification recording."
    }
  }
}

public actor WakeWordQualificationRecorder {
  private let transport: any VoiceAudioTransport
  private let capture = QualificationCaptureBuffer()
  private var outputURL: URL?

  public init(transport: any VoiceAudioTransport = AVFoundationVoiceAudioTransport()) {
    self.transport = transport
  }

  public func start(outputURL: URL) async throws {
    guard self.outputURL == nil else {
      throw WakeWordQualificationRecorderError.alreadyRecording
    }
    capture.reset()
    self.outputURL = outputURL
    do {
      try await transport.startInput { [capture] data in capture.append(data) }
    } catch {
      self.outputURL = nil
      throw error
    }
  }

  public func stop() async throws -> WakeWordQualificationRecording {
    guard let outputURL else { throw WakeWordQualificationRecorderError.notRecording }
    self.outputURL = nil
    await transport.stop()
    let data = capture.snapshot()
    capture.reset()
    let sampleCount = data.count / MemoryLayout<Int16>.size
    let duration = Double(sampleCount) / AVFoundationVoiceAudioTransport.providerSampleRate
    guard duration >= 0.5 else { throw WakeWordQualificationRecorderError.recordingTooShort }
    try Self.writePCM16WAV(data, to: outputURL)
    return WakeWordQualificationRecording(url: outputURL, duration: duration)
  }

  public func cancel() async {
    outputURL = nil
    await transport.stop()
    capture.reset()
  }

  static func writePCM16WAV(_ data: Data, to url: URL) throws {
    guard !data.isEmpty,
      data.count.isMultiple(of: MemoryLayout<Int16>.size),
      data.count <= Int(UInt32.max) - 36
    else {
      throw WakeWordQualificationRecorderError.invalidAudio
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let sampleRate = UInt32(AVFoundationVoiceAudioTransport.providerSampleRate.rounded())
    let channelCount: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let blockAlign = channelCount * (bitsPerSample / 8)
    let byteRate = sampleRate * UInt32(blockAlign)
    var wav = Data()
    wav.reserveCapacity(44 + data.count)
    wav.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36 + data.count), to: &wav)
    wav.append(contentsOf: "WAVEfmt ".utf8)
    appendLittleEndian(UInt32(16), to: &wav)
    appendLittleEndian(UInt16(1), to: &wav)
    appendLittleEndian(channelCount, to: &wav)
    appendLittleEndian(sampleRate, to: &wav)
    appendLittleEndian(byteRate, to: &wav)
    appendLittleEndian(blockAlign, to: &wav)
    appendLittleEndian(bitsPerSample, to: &wav)
    wav.append(contentsOf: "data".utf8)
    appendLittleEndian(UInt32(data.count), to: &wav)
    wav.append(data)
    try wav.write(to: url, options: .atomic)
  }

  private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }
}

private final class QualificationCaptureBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ value: Data) {
    lock.withLock { data.append(value) }
  }

  func snapshot() -> Data {
    lock.withLock { data }
  }

  func reset() {
    lock.withLock { data.removeAll(keepingCapacity: true) }
  }
}

public actor WakeWordQualificationCorpusStore {
  public let directory: URL

  public init(directory: URL = WakeWordQualificationCorpusStore.defaultDirectory) {
    self.directory = directory
  }

  /// One corpus per phrase: samples recorded for "Hey Muse" must not qualify a "Hey Otto" model.
  public static var defaultDirectory: URL {
    let folder = AcousticWakeWordConfiguration.defaultPhrase.replacingOccurrences(of: " ", with: "")
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Otto/VoiceQualification/\(folder)")
  }

  public func append(_ testCase: WakeWordQualificationCase) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    var corpus: WakeWordQualificationCorpus
    if FileManager.default.fileExists(atPath: manifestURL.path) {
      corpus = try JSONDecoder().decode(
        WakeWordQualificationCorpus.self,
        from: Data(contentsOf: manifestURL)
      )
    } else {
      corpus = WakeWordQualificationCorpus(cases: [])
    }
    corpus.cases.removeAll(where: { $0.id == testCase.id })
    corpus.cases.append(testCase)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(corpus).write(to: manifestURL, options: .atomic)
  }

  public func summary() throws -> (positive: Int, negative: Int, speakers: Int) {
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else { return (0, 0, 0) }
    let corpus = try JSONDecoder().decode(
      WakeWordQualificationCorpus.self,
      from: Data(contentsOf: manifestURL)
    )
    let speakers = Set(
      corpus.cases.compactMap { testCase in
        testCase.label == .positive ? testCase.speakerID : nil
      })
    return (
      corpus.cases.count(where: { $0.label == .positive }),
      corpus.cases.count(where: { $0.label == .negative }),
      speakers.count
    )
  }
}

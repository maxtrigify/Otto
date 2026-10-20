import AVFoundation
import Foundation
import Testing

@testable import OttoVoice

@Suite("Wake-word qualification recorder")
struct WakeWordQualificationRecorderTests {
  @Test("PCM writer produces a readable 24 kHz mono WAV")
  func waveWriter() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-wake-recorder-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("sample.wav")
    let samples = [Int16](repeating: 1_000, count: 24_000)
    let data = samples.withUnsafeBytes { Data($0) }

    try WakeWordQualificationRecorder.writePCM16WAV(data, to: url)

    let file = try AVAudioFile(forReading: url)
    #expect(Int(file.processingFormat.sampleRate.rounded()) == 24_000)
    #expect(file.processingFormat.channelCount == 1)
    #expect(file.length == 24_000)
  }

  @Test("Corpus store preserves labels and distinct real speakers")
  func corpusStore() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-wake-corpus-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WakeWordQualificationCorpusStore(directory: root)
    try await store.append(
      WakeWordQualificationCase(
        id: "positive-1",
        audioFile: "positive-1.wav",
        label: .positive,
        speakerID: "speaker-a"
      ))
    try await store.append(
      WakeWordQualificationCase(
        id: "negative-1",
        audioFile: "negative-1.wav",
        label: .negative
      ))

    let summary = try await store.summary()
    #expect(summary.positive == 1)
    #expect(summary.negative == 1)
    #expect(summary.speakers == 1)
  }
}

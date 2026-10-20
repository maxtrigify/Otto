import Foundation
import Testing

@testable import OttoVoice

@Suite("Acoustic wake word")
struct AcousticWakeWordDetectorTests {
  @Test("Hey Otto uses the production threshold and local application support path")
  func defaults() {
    let configuration = AcousticWakeWordConfiguration()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("onnx")
    let fallback = AcousticWakeWordConfiguration(classifierURL: missing)

    #expect(fallback.threshold == 0.68)
    #expect(configuration.debounce == 2.0)
    #expect(
      ["hey_otto.onnx", "hey_muse.onnx"].contains(configuration.classifierURL.lastPathComponent))
    #expect(configuration.classifierURL.path.contains("Otto/VoiceModels/WakeWord"))
  }

  @Test("A trained hey_otto model wins; otherwise the hey_muse model and its phrase are used")
  func classifierSelection() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-wake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let legacy = AcousticWakeWordConfiguration.classifierURL(in: directory)
    #expect(legacy.lastPathComponent == "hey_muse.onnx")
    #expect(AcousticWakeWordConfiguration.phrase(for: legacy) == "Hey Muse")

    try Data().write(to: directory.appendingPathComponent("hey_otto.onnx"))
    let current = AcousticWakeWordConfiguration.classifierURL(in: directory)
    #expect(current.lastPathComponent == "hey_otto.onnx")
    #expect(AcousticWakeWordConfiguration.phrase(for: current) == "Hey Otto")
  }

  @Test("Factory fails closed when the acoustic classifier is absent")
  func missingClassifier() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("onnx")
    let configuration = AcousticWakeWordConfiguration(classifierURL: missing)

    #expect(throws: AcousticWakeWordError.classifierMissing(missing)) {
      _ = try AcousticWakeWordDetectorFactory.make(configuration: configuration)
    }
  }

  @Test("Installed classifier remains disabled until real-speaker gates pass")
  func productionQualification() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("muse-wake-quality-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = root.appendingPathComponent("hey_muse.onnx")
    try Data("model".utf8).write(to: model)

    var quality = AcousticWakeWordModelQuality(
      evaluatedAt: "2026-08-03T00:00:00Z",
      threshold: 0.73,
      recall: 0.89,
      falsePositivesPerHour: 0.1,
      positiveSamples: 100,
      negativeSamples: 1_000,
      validationHours: 10,
      realSpeakerCount: 5,
      corpusKind: "held-out-real-speakers",
      modelSHA256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
    )
    let qualityURL = model.deletingPathExtension().appendingPathExtension("quality.json")
    try JSONEncoder().encode(quality).write(to: qualityURL)

    #expect(!AcousticWakeWordConfiguration(classifierURL: model).classifierIsProductionReady)

    quality.recall = 0.91
    try JSONEncoder().encode(quality).write(to: qualityURL)
    let qualified = AcousticWakeWordConfiguration(classifierURL: model)
    #expect(qualified.classifierIsProductionReady)
    #expect(qualified.threshold == 0.73)
  }
}

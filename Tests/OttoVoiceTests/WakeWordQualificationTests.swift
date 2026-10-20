import Testing

@testable import OttoVoice

@Suite("Wake-word qualification")
struct WakeWordQualificationTests {
  @Test("Threshold selection maximizes recall while holding the false-positive gate")
  func thresholdSelection() {
    let report = WakeWordQualificationEvaluator.selectThreshold(
      positiveScores: [0.95, 0.90, 0.80, 0.70, 0.60],
      negativeScoreSequences: [[0.75, 0.20, 0.10]],
      negativeHours: 10,
      realSpeakerCount: 5
    )

    #expect(report.threshold == 0.21)
    #expect(report.recall == 1)
    #expect(report.falsePositivesPerHour == 0.1)
    #expect(!report.passesReleaseGate)
  }

  @Test("Repeated negative windows count as debounced false activations")
  func falseActivationEvents() {
    let report = WakeWordQualificationEvaluator.selectThreshold(
      positiveScores: [0.95, 0.90, 0.80, 0.70, 0.60],
      negativeScoreSequences: [[Float](repeating: 0.75, count: 15)],
      negativeHours: 10,
      realSpeakerCount: 5
    )

    #expect(report.threshold == 0.76)
    #expect(report.recall == 0.6)
    #expect(report.falsePositivesPerHour == 0)
  }

  @Test("Report only passes with the real-speaker release evidence")
  func releaseGate() {
    let report = WakeWordQualificationReport(
      schemaVersion: 1,
      corpusKind: "held-out-real-speakers",
      realSpeakerCount: 5,
      positiveSamples: 100,
      negativeSamples: 100,
      validationHours: 10,
      threshold: 0.7,
      recall: 0.91,
      falsePositivesPerHour: 0.1
    )

    #expect(report.passesReleaseGate)
  }
}

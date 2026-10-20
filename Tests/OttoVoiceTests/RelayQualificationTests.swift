import Foundation
import Testing

@testable import OttoVoice

@Suite("Relay qualification")
struct RelayQualificationTests {
  @Test("Word comparison ignores presentation punctuation but not substitutions")
  func normalizedWords() {
    #expect(
      RelayQualificationEvaluator.normalizedWords("Fix API_v2 now.")
        == RelayQualificationEvaluator.normalizedWords("fix API v2 now")
    )
    #expect(
      RelayQualificationEvaluator.normalizedWords("verbatim")
        != RelayQualificationEvaluator.normalizedWords("verbate and")
    )
  }

  @Test("Edit distance counts word substitutions, insertions, and deletions")
  func editDistance() {
    #expect(RelayQualificationEvaluator.editDistance(["a", "b"], ["a", "c"]) == 1)
    #expect(RelayQualificationEvaluator.editDistance(["a"], ["a", "b"]) == 1)
    #expect(RelayQualificationEvaluator.editDistance(["a", "b"], ["a"]) == 1)
  }

  @Test("Nearest-rank p95 never falls below the median for a small sample")
  func percentile() {
    #expect(RelayQualificationEvaluator.percentile([354, 483], fraction: 0.95) == 483)
  }

  @Test("Release report requires real scale, fidelity, routing, and latency")
  func releaseGate() {
    let report = RelayQualificationReport(
      schemaVersion: 1,
      corpusKind: "held-out-real-speakers",
      realSpeakerCount: 5,
      caseCount: 100,
      wordErrorRatePercent: 1,
      transcriptExactAccuracy: 0.99,
      routeAccuracy: 0.99,
      payloadExactAccuracy: 0.99,
      latencyMedianMilliseconds: 300,
      latencyP95Milliseconds: 900,
      results: []
    )
    #expect(report.passesReleaseGate)
  }

  @Test("Corpus store persists cases and distinct speaker counts")
  func corpusStore() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-relay-qualification-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RelayQualificationCorpusStore(directory: directory)
    try await store.append(
      RelayQualificationCase(
        id: "one",
        audioFile: "one.wav",
        speakerID: "speaker-a",
        targetName: "Chase",
        expectedTranscript: "Tell Chase verbatim keep API v2",
        expectedPayload: "keep API v2"
      ))
    try await store.append(
      RelayQualificationCase(
        id: "two",
        audioFile: "two.wav",
        speakerID: "speaker-b",
        targetName: "Chase",
        expectedTranscript: "Tell Chase verbatim keep API v3",
        expectedPayload: "keep API v3"
      ))

    let summary = try await store.summary()
    #expect(summary.cases == 2)
    #expect(summary.speakers == 2)
  }
}

import Foundation
import OttoVoice
import Testing

@Suite("Dictation draft safety")
struct DictationDraftStoreTests {
  @Test("Rolling drafts replace speculative text and survive a new store instance")
  func rollingPersistence() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-draft-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = UUID()
    let firstStore = DictationDraftStore(directory: directory)
    let first = try #require(
      await firstStore.save(
        transcript: "Open the", targetNodeID: target, sourceBundleID: "io.openotto.desktop.dev"))
    let updated = try #require(
      await firstStore.save(
        transcript: "Open the release notes",
        targetNodeID: target,
        sourceBundleID: "io.openotto.desktop.dev"
      ))

    #expect(updated.id == first.id)
    #expect(updated.transcript == "Open the release notes")
    let restored = try #require(await DictationDraftStore(directory: directory).load())
    #expect(restored.id == updated.id)
    #expect(restored.transcript == updated.transcript)
    #expect(restored.targetNodeID == updated.targetNodeID)
    #expect(restored.sourceBundleID == updated.sourceBundleID)

    try await firstStore.clear()
    #expect(try await firstStore.load() == nil)
  }

  @Test("Only one Otto process lease may own a microphone lock path")
  func exclusiveLease() {
    let path = FileManager.default.temporaryDirectory.appending(
      path: "otto-voice-lease-\(UUID().uuidString)"
    ).path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let first = VoiceCaptureLease(path: path)
    let second = VoiceCaptureLease(path: path)

    #expect(first.acquire(owner: "Otto Dev"))
    #expect(!second.acquire(owner: "Otto"))
    first.release()
    #expect(second.acquire(owner: "Otto"))
    second.release()
  }
}

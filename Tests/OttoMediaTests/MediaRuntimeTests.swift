import Foundation
import OttoMedia
import Testing

@Suite("Media runtime")
struct MediaRuntimeTests {
  @Test("Playback commands clamp values and publish deterministic state")
  func playbackLifecycle() async throws {
    let runtime = MediaRuntime()
    let id = UUID()
    await runtime.register(nodeID: id, source: "https://example.test/audio.mp3")
    #expect(try await runtime.play(nodeID: id).isPlaying)
    #expect(try await runtime.setVolume(nodeID: id, volume: 2).volume == 1)
    #expect(try await runtime.seek(nodeID: id, position: 42).position == 42)
    let stopped = try await runtime.stop(nodeID: id)
    #expect(!stopped.isPlaying)
    #expect(stopped.position == 0)
    #expect(stopped.requestedAction == .stop)
  }
}

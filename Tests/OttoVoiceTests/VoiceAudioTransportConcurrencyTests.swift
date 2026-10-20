import Foundation
import OttoVoice
import Testing

@Suite("Voice audio transport concurrency")
struct VoiceAudioTransportConcurrencyTests {
  @Test(
    "Concurrent provider audio and playback cancellation stay serialized",
    .disabled(
      if: ProcessInfo.processInfo.environment["CI"] == "true",
      "Requires an audio output device"
    )
  )
  func concurrentPlayAndStop() async {
    let transport = AVFoundationVoiceAudioTransport()
    let silence = Data(repeating: 0, count: 480)

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<100 {
        if index.isMultiple(of: 3) {
          group.addTask { await transport.stopPlayback() }
        } else {
          group.addTask { try? await transport.play(silence) }
        }
      }
    }

    await transport.stop()
  }
}

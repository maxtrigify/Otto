import AVFoundation
import Foundation
import Testing

@testable import OttoVoice

@Suite("Voice audio transport launch safety")
struct VoiceAudioTransportLaunchSafetyTests {
  @Test("Constructing the transport never touches audio hardware")
  func constructionIsInert() async {
    // Otto builds this transport while launching. Before the playback graph became lazy an
    // AVAudioEngine connection ran inside `init`, and on Macs whose output device was missing
    // or exposed an unusable format AVFoundation raised an exception that killed the app
    // before its first window. This must stay safe on every machine, including CI runners.
    let transport = AVFoundationVoiceAudioTransport()
    await transport.stopPlayback()
  }

  @Test("Objective-C exceptions become Swift errors")
  func exceptionsAreCaught() {
    #expect(throws: ObjectiveCExceptions.Raised.self) {
      try ObjectiveCExceptions.catching {
        NSException(
          name: .internalInconsistencyException,
          reason: "required condition is false: IsFormatSampleRateAndChannelCountValid(format)",
          userInfo: nil
        ).raise()
      }
    }
    do {
      try ObjectiveCExceptions.catching {
        NSException(name: .genericException, reason: "boom", userInfo: nil).raise()
      }
      Issue.record("Expected the exception to surface as an error")
    } catch let error as ObjectiveCExceptions.Raised {
      #expect(error.reason == "boom")
      #expect(error.name == NSExceptionName.genericException.rawValue)
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  @Test("Swift errors and values pass through the exception guard")
  func swiftErrorsPassThrough() throws {
    struct Marker: Error {}
    #expect(throws: Marker.self) {
      try ObjectiveCExceptions.catching { throw Marker() }
    }
    let value = try ObjectiveCExceptions.catching { 42 }
    #expect(value == 42)
  }

  @Test("Provider PCM16 is converted to float playback buffers")
  func providerAudioBecomesFloat() throws {
    let format = try #require(
      AVAudioFormat(
        standardFormatWithSampleRate: AVFoundationVoiceAudioTransport.providerSampleRate,
        channels: 1
      )
    )
    let samples: [Int16] = [0, Int16.max, Int16.min, 16_384]
    let data = samples.withUnsafeBytes { Data($0) }
    let buffer = try #require(VoicePCMConverter.playbackBuffer(from: data, format: format))
    #expect(buffer.frameLength == 4)
    let channel = try #require(buffer.floatChannelData?[0])
    #expect(channel[0] == 0)
    #expect(abs(channel[1] - 1) < 0.001)
    #expect(channel[2] == -1)
    #expect(abs(channel[3] - 0.5) < 0.001)
    #expect(VoicePCMConverter.playbackBuffer(from: Data([1]), format: format) == nil)
    #expect(VoicePCMConverter.playbackBuffer(from: Data(), format: format) == nil)
  }
}

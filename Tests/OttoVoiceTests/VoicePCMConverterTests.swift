import AVFoundation
import Testing

@testable import OttoVoice

@Suite("Voice microphone PCM conversion")
struct VoicePCMConverterTests {
  @Test("48 kHz processed microphone audio becomes non-silent 24 kHz PCM16")
  func convertsProcessedMicrophoneAudio() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
      ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    let samples = try #require(buffer.floatChannelData?[0])
    for frame in 0..<480 {
      samples[frame] = frame.isMultiple(of: 2) ? 0.5 : -0.5
    }

    let converted = try #require(VoicePCMConverter.providerPCM16(from: buffer))
    #expect(converted.count == 480)
    #expect(converted.contains { $0 != 0 })
  }

  @Test(
    "Common microphone formats convert to mono 24 kHz",
    arguments: [16_000.0, 44_100.0, 48_000.0, 96_000.0], [1, 2]
  )
  func commonFormats(sampleRate: Double, channels: Int) throws {
    let inputFrames = Int(sampleRate / 100)
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels),
        interleaved: false
      ))
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(inputFrames)))
    buffer.frameLength = AVAudioFrameCount(inputFrames)
    let samples = try #require(buffer.floatChannelData)
    for channel in 0..<channels {
      for frame in 0..<inputFrames {
        samples[channel][frame] = sin(Float(frame) * 0.12) * 0.25
      }
    }

    let converted = try #require(VoicePCMConverter.providerPCM16(from: buffer))
    #expect(converted.count == 480)
    #expect(converted.contains { $0 != 0 })
  }

  @Test("Silence remains silence and is classified as no signal")
  func silence() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
      ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480

    let converted = try #require(VoicePCMConverter.providerPCM16(from: buffer))
    #expect(converted.allSatisfy { $0 == 0 })
    #expect(LocalSpeechInputDiagnostic.quality(for: 0) == .silent)
    #expect(LocalSpeechInputDiagnostic.quality(for: 0.01) == .low)
    #expect(LocalSpeechInputDiagnostic.quality(for: 0.1) == .good)
    #expect(LocalSpeechInputDiagnostic.quality(for: 0.9) == .clipping)
  }
}

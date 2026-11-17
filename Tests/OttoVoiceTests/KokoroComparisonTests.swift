#if canImport(FluidAudio)
  import Foundation
  import Testing

  @testable import OttoVoice

  /// Not a regression test: speaks a list of sentences with Otto's own voice and writes them
  /// out as sound files, for comparing by ear with another build of the same voice.
  ///
  ///     OTTO_KOKORO_COMPARE=/tmp/voice-compare scripts/otto-swift test --filter KokoroComparison
  ///
  /// The folder holds `lines.json`, a list of lists of sentences, and receives `otto-N.wav`.
  @Suite("Otto's voice, for listening to")
  struct KokoroComparisonTests {
    private static let folder = ProcessInfo.processInfo.environment["OTTO_KOKORO_COMPARE"]

    private static func wav(_ pcm: Data) -> Data {
      var header = Data()
      func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
      }
      header.append(Data("RIFF".utf8))
      append(UInt32(36 + pcm.count))
      header.append(Data("WAVEfmt ".utf8))
      append(UInt32(16))
      append(UInt16(1))
      append(UInt16(1))
      append(UInt32(24_000))
      append(UInt32(48_000))
      append(UInt16(2))
      append(UInt16(16))
      header.append(Data("data".utf8))
      append(UInt32(pcm.count))
      return header + pcm
    }

    @Test(.enabled(if: folder != nil))
    func speaksTheListedSentences() async throws {
      let folder = URL(fileURLWithPath: try #require(Self.folder))
      let lines = try JSONDecoder().decode(
        [[String]].self, from: Data(contentsOf: folder.appending(path: "lines.json")))
      let voice = KokoroSpeechSynthesizer()
      for (index, sentences) in lines.enumerated() {
        var audio = Data()
        // One sentence at a time, joined end to end, exactly as Otto plays a reply.
        for sentence in sentences { audio += try await voice.speech(for: sentence) }
        try Self.wav(audio).write(to: folder.appending(path: "otto-\(index + 1).wav"))
      }
      #expect(await voice.readiness == .ready, "Kokoro was not used; this was the macOS voice")
    }
  }
#endif

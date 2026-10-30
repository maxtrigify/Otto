import Foundation
import OttoVoice
import Testing

@Suite("Recorded audio transcription")
struct AudioFileTranscriptionTests {
  @Test("An empty or unreadable recording is reported before any engine runs")
  func unreadableRecording() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "audio-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appending(path: "empty.oga")
    try Data().write(to: empty)
    await #expect(throws: AudioFileTranscriptionError.self) {
      _ = try await AudioFileTranscription.transcribe(empty, preferring: [.whistle])
    }
    let garbage = directory.appending(path: "garbage.oga")
    try Data("not audio".utf8).write(to: garbage)
    await #expect(throws: AudioFileTranscriptionError.self) {
      _ = try await AudioFileTranscription.transcribe(garbage, preferring: [.whistle])
    }
  }
}

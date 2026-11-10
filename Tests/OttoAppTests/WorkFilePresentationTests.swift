import Foundation
import Testing

@testable import OttoApp

@Suite("Work panel file presentation")
struct WorkFilePresentationTests {
  @Test(
    "Pictures, movies, sounds and documents go to the system previewer",
    arguments: [
      "/tmp/Reel 7/storyboard-8-bloating.png",
      "/tmp/photo.JPG",
      "/tmp/screen recording.mov",
      "/tmp/clip.mp4",
      "/tmp/voice note.m4a",
      "/tmp/track.mp3",
      "/tmp/brief.pdf",
      "/tmp/archive.zip",
      "/tmp/vector.svg",
    ])
  func previewsMediaAndDocuments(path: String) {
    // Even a file whose bytes happen to decode as text must not reach the editor: it is
    // still a picture, a movie or a document.
    #expect(WorkFilePresentation.forPath(path, decodesAsText: true) == .systemPreview)
    #expect(WorkFilePresentation.forPath(path, decodesAsText: false) == .systemPreview)
  }

  @Test(
    "Source and notes stay in the editor",
    arguments: [
      "/tmp/notes.md", "/tmp/README.markdown", "/tmp/Package.swift", "/tmp/main.py",
      "/tmp/config.yaml", "/tmp/data.json", "/tmp/script.sh", "/tmp/styles.css",
    ])
  func keepsTextInEditor(path: String) {
    #expect(WorkFilePresentation.forPath(path, decodesAsText: true) == .text)
    // A text file that this build cannot decode still offers the previewer rather than an
    // editor that would overwrite it with mojibake on save.
    #expect(WorkFilePresentation.forPath(path, decodesAsText: false) == .systemPreview)
  }

  @Test func unknownExtensionsFollowTheBytes() {
    #expect(WorkFilePresentation.forPath("/tmp/sketch.bin", decodesAsText: true) == .text)
    #expect(WorkFilePresentation.forPath("/tmp/sketch.bin", decodesAsText: false) == .systemPreview)
    // Files without an extension (Makefile, Dockerfile, .gitignore) decide the same way.
    #expect(WorkFilePresentation.forPath("/repo/Makefile", decodesAsText: true) == .text)
    #expect(WorkFilePresentation.forPath("/repo/.gitignore", decodesAsText: true) == .text)
    #expect(WorkFilePresentation.forPath("/tmp/mystery", decodesAsText: false) == .systemPreview)
  }

  @Test func readsTextAndRejectsBinaryOrMissingFiles() throws {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "work-file-presentation-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let text = folder.appending(path: "note.md")
    try "# Draft\n\nSix shots.\n".write(to: text, atomically: true, encoding: .utf8)
    #expect(WorkFilePresentation.decodeText(atPath: text.path) == "# Draft\n\nSix shots.\n")

    let empty = folder.appending(path: "empty.txt")
    try Data().write(to: empty)
    #expect(WorkFilePresentation.decodeText(atPath: empty.path) == "")

    // The PNG header, NUL-padded like a real bitmap: readable-ish ASCII, still not text.
    let image = folder.appending(path: "storyboard.png")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
      .write(to: image)
    #expect(WorkFilePresentation.decodeText(atPath: image.path) == nil)

    // Latin-1 bytes are not UTF-8, so they belong to the previewer.
    let latin1 = folder.appending(path: "legacy.txt")
    try Data([0x48, 0x69, 0x20, 0xE9]).write(to: latin1)
    #expect(WorkFilePresentation.decodeText(atPath: latin1.path) == nil)

    #expect(WorkFilePresentation.decodeText(atPath: folder.appending(path: "gone.md").path) == nil)
  }
}

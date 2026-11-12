import Testing

@testable import OttoApp

/// Issue #73: photos, videos and sounds opened from a chat link showed
/// "Could not read this file as text." in the Files panel.
struct WorkFilePreviewTests {
  @Test(arguments: [
    "/tmp/storyboard-8-bloating.png", "/tmp/photo.JPG", "/tmp/shot.heic", "/tmp/anim.gif",
    "/tmp/frame.webp",
  ])
  func photosAreDrawnNotOpenedInTheTextEditor(path: String) {
    #expect(WorkFilePreviewKind.kind(forPath: path) == .image)
  }

  @Test(arguments: [
    "/tmp/reel.mp4", "/tmp/clip.mov", "/tmp/voice.m4a", "/tmp/song.mp3", "/tmp/take.wav",
    "/tmp/paper.pdf",
  ])
  func mediaFilesGetAPreviewNotTheTextEditor(path: String) {
    #expect(WorkFilePreviewKind.kind(forPath: path) == .media)
  }

  @Test(arguments: [
    "/tmp/SCRIPTS.md", "/tmp/notes.txt", "/tmp/App.swift", "/tmp/data.json", "/tmp/icon.svg",
    "/tmp/Makefile", "/tmp/unknown.zzqx",
  ])
  func textFilesStayInTheEditor(path: String) {
    #expect(WorkFilePreviewKind.kind(forPath: path) == .text)
  }

  @Test(arguments: ["/tmp/Contract.docx", "/tmp/backup.zip", "/tmp/blob.zzqx", "/tmp/Makefile"])
  func filesThatAreNotTextGoToQuickLook(path: String) {
    #expect(WorkFilePreviewKind.kind(forPath: path, decodesAsText: false) == .media)
  }

  @Test func readableTextAndMediaKeepTheirKind() {
    #expect(WorkFilePreviewKind.kind(forPath: "/tmp/notes.md", decodesAsText: true) == .text)
    #expect(WorkFilePreviewKind.kind(forPath: "/tmp/shot.png", decodesAsText: false) == .image)
  }
}

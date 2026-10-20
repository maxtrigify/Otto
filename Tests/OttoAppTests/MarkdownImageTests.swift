import AppKit
import Foundation
import OttoModels
import SwiftUI
import Testing

@testable import OttoApp

@Suite("Markdown images")
struct MarkdownImageTests {
  @Test func localScreenshotPaths() {
    let reference = ChatImageReference.parse("![Paper](</tmp/Paper shot (1).png>)")
    #expect(reference?.target == "/tmp/Paper shot (1).png")
    #expect(
      ChatImageReference.localURL(reference!.target, directory: nil)?.path == reference?.target)
    #expect(
      ChatImageReference.localURL("file:///tmp/Paper%20shot.png", directory: nil)?.path
        == "/tmp/Paper shot.png")
    #expect(ChatImageReference.localURL("https://example.com/a.png", directory: nil) == nil)
    #expect(ChatImageReference.localURL("file://server/share/a.png", directory: nil) == nil)
    let blocks = MarkdownBlockParser.parse("![Paper](</tmp/Paper shot (1).png>)")
    #expect(blocks.first?.content == .image(alt: "Paper", target: "/tmp/Paper shot (1).png"))
  }

  @Test("Parses standalone local and remote images as image blocks")
  func parsesImages() {
    let blocks = MarkdownBlockParser.parse(
      """
      Before

      ![Sketch](attachments/sketch.png)

      ![Reference](https://example.com/reference.jpg)
      """)

    #expect(blocks.count == 3)
    #expect(blocks[1].content == .image(alt: "Sketch", target: "attachments/sketch.png"))
    #expect(
      blocks[2].content
        == .image(alt: "Reference", target: "https://example.com/reference.jpg"))
  }
  @Test @MainActor func renderLocalImage() throws {
    guard let directory = ProcessInfo.processInfo.environment["OTTO_IMAGE_SNAPSHOTS"] else {
      return
    }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let path = URL(fileURLWithPath: directory).appendingPathComponent("sample (1).png")
    let sample = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
      NSColor.systemIndigo.setFill()
      rect.fill()
      ("Saved screenshot" as NSString).draw(
        at: NSPoint(x: 40, y: 170),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.white,
        ])
      return true
    }
    let rep = try #require(NSBitmapImageRep(data: sample.tiffRepresentation!))
    try #require(rep.representation(using: .png, properties: [:])).write(to: path)
    _ = NSApplication.shared
    for width in [390, 900] {
      let view = MarkdownMessageView(
        text: "Here is the screenshot.\n\n![Saved screenshot](<\(path.path)>)", scale: 1,
        palette: .fieldNotes
      )
      .padding(20).frame(width: CGFloat(width)).background(OttoPalette.fieldNotes.surface)
      let host = NSHostingView(rootView: view)
      host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      defer { window.close() }
      host.layoutSubtreeIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.2))
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("chat-\(width).png"))
    }
  }

}

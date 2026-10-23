import AppKit
import Foundation
import Testing

@testable import OttoApp

@Suite("Composer image attachments")
@MainActor
struct ChatImageAttachmentTests {
  private func png() throws -> Data {
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(.red, atX: 0, y: 0)
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  @Test("A copied screenshot is saved in the workspace and can start a chat by itself")
  func screenshotPaste() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setData(try png(), forType: .png)
    let images = try ChatImageAttachmentStore(directory: directory.path).paste(from: pasteboard)
    #expect(images.count == 1)
    let image = try #require(images.first)
    #expect(URL(fileURLWithPath: image.path).deletingLastPathComponent().path == directory.path)
    #expect(NSImage(contentsOfFile: image.path) != nil)
    let prompt = try #require(
      ChatImageAttachmentStore.compose(typed: nil, pastes: [], images: images))
    #expect(prompt.contains("Please look at the attached image."))
    #expect(prompt.contains(image.path))
  }

  @Test("Copied image files keep their bytes and receive unique attachment names")
  func filePaste() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "example.png")
    let bytes = try png()
    try bytes.write(to: source)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([source as NSURL])
    let store = ChatImageAttachmentStore(directory: directory.appending(path: "attachments").path)
    let first = try #require(store.paste(from: pasteboard).first)
    let second = try #require(store.paste(from: pasteboard).first)
    #expect(first.path != second.path)
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == bytes)
    #expect(try Data(contentsOf: source) == bytes)
    let prompt = try #require(
      ChatImageAttachmentStore.compose(
        typed: "Compare these", pastes: [ChatPastedText("Extra context")], images: [first, second]))
    #expect(prompt.contains("Compare these"))
    #expect(prompt.contains("Extra context"))
    #expect(prompt.contains("2 images"))
    #expect(prompt.contains(first.path) && prompt.contains(second.path))
    #expect(ChatImageAttachmentStore.compose(typed: nil, pastes: [], images: []) == nil)
  }

  @Test("Empty clipboards report an error without creating attachments")
  func emptyClipboard() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(throws: ChatImageAttachmentStore.AttachmentError.self) {
      try ChatImageAttachmentStore(directory: directory.path).paste(from: pasteboard)
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test("Directories and files over 50 MB are rejected before copying")
  func invalidFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ChatImageAttachmentStore(directory: directory.appending(path: "attachments").path)
    #expect(throws: ChatImageAttachmentStore.AttachmentError.self) { try store.saveFile(directory) }
    let source = directory.appending(path: "large.png")
    FileManager.default.createFile(atPath: source.path, contents: nil)
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(ChatImageAttachmentStore.maximumImageBytes + 1))
    try handle.close()
    #expect(throws: ChatImageAttachmentStore.AttachmentError.self) { try store.saveFile(source) }
    #expect(!FileManager.default.fileExists(atPath: store.directory))
  }
}

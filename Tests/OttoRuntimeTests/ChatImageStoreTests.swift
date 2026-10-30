import Foundation
import Testing

@testable import OttoRuntime

@Suite("Chat reply image storage")
struct ChatImageStoreTests {
  @Test func survivesOriginalDeletionAndDeduplicates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Paper shot (1).png")
    let bytes = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
    )!
    try bytes.write(to: source)
    let input = "![Paper](<\(source.path)>)"
    let code = "```markdown\n\(input)\n```"
    #expect(ChatImageStore.preservingImages(in: code, workingDirectory: root.path) == code)
    let saved = ChatImageStore.preservingImages(in: input, workingDirectory: root.path)
    #expect(saved != input)
    #expect(
      ChatImageStore.preservingImages(
        in: "![Paper](\(source.absoluteString))", workingDirectory: root.path) == saved)
    #expect(
      ChatImageStore.preservingImages(
        in: "![Paper](<Paper shot (1).png>)", workingDirectory: root.path) == saved)
    #expect(ChatImageStore.preservingImages(in: input, workingDirectory: root.path) == saved)
    try FileManager.default.removeItem(at: source)
    #expect(ChatImageStore.preservingImages(in: saved, workingDirectory: root.path) == saved)
    let files = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent(".otto/chat-attachments/replies"),
      includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(try Data(contentsOf: files[0]) == bytes)
  }

  @Test func storesCopiesInOttoWorkspaceNotTheProjectFolder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("repo")
    let otto = root.appendingPathComponent("otto")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII="
    )!
    try bytes.write(to: project.appendingPathComponent("shot.png"))
    let saved = ChatImageStore.preservingImages(
      in: "![Shot](shot.png)", workingDirectory: project.path, storageRoot: otto.path)
    #expect(saved.contains(otto.appendingPathComponent(".otto/chat-attachments/replies").path))
    #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".otto").path))
  }

  @Test func leavesRemoteMissingAndCodeReferencesAlone() {
    let text =
      "![Remote](https://example.com/a.png)\n![Missing](/nonexistent/image.png)\n```md\n![Example](/tmp/example.png)\n```"
    #expect(ChatImageStore.preservingImages(in: text, workingDirectory: "/tmp") == text)
  }
}

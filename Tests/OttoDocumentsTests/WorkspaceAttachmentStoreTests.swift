import Foundation
import OttoDocuments
import Testing

@Suite("Workspace attachment imports")
struct WorkspaceAttachmentStoreTests {
  @Test("Copies files into workspace assets without retaining source paths")
  func importsFile() async throws {
    let fixture = try AttachmentFixture()
    defer { fixture.remove() }
    let source = fixture.source.appending(path: "Launch Notes.md")
    let bytes = Data("# Launch\n".utf8)
    try bytes.write(to: source)
    let store = WorkspaceAttachmentStore(rootPath: fixture.workspace.path)

    let attachments = try await store.importFiles([source])
    let attachment = try #require(attachments.first)
    #expect(attachment.displayName == "Launch Notes.md")
    #expect(attachment.relativePath.hasPrefix(".otto/attachments/"))
    #expect(!attachment.relativePath.contains(fixture.source.path))
    #expect(attachment.mimeType == "text/markdown")
    #expect(attachment.byteCount == Int64(bytes.count))
    #expect(
      try Data(contentsOf: fixture.workspace.appending(path: attachment.relativePath)) == bytes)
  }

  @Test("Rejects oversized and symbolic-link sources and rolls back a partial batch")
  func rejectsUnsafeBatch() async throws {
    let fixture = try AttachmentFixture()
    defer { fixture.remove() }
    let valid = fixture.source.appending(path: "valid.txt")
    let oversized = fixture.source.appending(path: "oversized.bin")
    try Data("valid".utf8).write(to: valid)
    try Data(repeating: 0x41, count: 32).write(to: oversized)
    let store = WorkspaceAttachmentStore(rootPath: fixture.workspace.path, maximumBytes: 16)

    await #expect(throws: AttachmentImportError.fileTooLarge("oversized.bin", 16)) {
      try await store.importFiles([valid, oversized])
    }
    let attachmentRoot = fixture.workspace.appending(path: ".otto/attachments")
    let remaining =
      (try? FileManager.default.contentsOfDirectory(atPath: attachmentRoot.path)) ?? []
    #expect(remaining.isEmpty)

    let link = fixture.source.appending(path: "linked.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)
    await #expect(throws: AttachmentImportError.symbolicLinkNotSupported("linked.txt")) {
      try await store.importFiles([link])
    }
  }
}

private struct AttachmentFixture {
  let root: URL
  let source: URL
  let workspace: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "otto-attachment-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    source = root.appending(path: "source", directoryHint: .isDirectory)
    workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

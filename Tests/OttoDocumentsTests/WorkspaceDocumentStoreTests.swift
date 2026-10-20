import Foundation
import OttoDocuments
import Testing

@Suite("Workspace document confinement")
struct WorkspaceDocumentStoreTests {
  @Test("Creates, reads, replaces, and appends workspace documents")
  func documentLifecycle() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-docs-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)

    try await store.replace(relativePath: "notes/goals.md", text: "# Goals\n")
    #expect(try await store.read(relativePath: "notes/goals.md") == "# Goals\n")
    #expect(
      try await store.append(relativePath: "notes/goals.md", text: "- [ ] Ship\n")
        == "# Goals\n- [ ] Ship\n")
  }

  @Test("Creates unique canvas notes from templates and indexes their tasks")
  func canvasNotes() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-notes-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)
    let canvasID = UUID()

    #expect(
      try await store.listCanvasNotes(canvasID: canvasID, canvasName: "Product / Launch").isEmpty)

    let first = try await store.createCanvasNote(
      canvasID: canvasID,
      canvasName: "Product / Launch",
      template: .todo
    )
    let second = try await store.createCanvasNote(
      canvasID: canvasID,
      canvasName: "Product / Launch",
      template: .todo
    )

    #expect(first.relativePath.hasPrefix("Notes/Product - Launch-"))
    #expect(first.relativePath.hasSuffix("/Todo.md"))
    #expect(second.relativePath.hasSuffix("/Todo 2.md"))
    let notes = try await store.listCanvasNotes(canvasID: canvasID, canvasName: "Product / Launch")
    #expect(notes.count == 2)
    #expect(notes.flatMap(\.tasks).count == 2)
    #expect(notes.flatMap(\.tasks).allSatisfy { !$0.isCompleted })
    let afterCanvasRename = try await store.listCanvasNotes(
      canvasID: canvasID, canvasName: "Renamed launch")
    #expect(afterCanvasRename.map(\.relativePath) == notes.map(\.relativePath))
  }

  @Test("Migrates pathless notes and searches title and body text")
  func migratesAndSearchesCanvasNotes() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-note-search-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)
    let canvasID = UUID()

    let migrated = try await store.migrateCanvasNote(
      text: "# Campaign ideas\n\nTry a founder video.\n- [x] Draft script\n",
      canvasID: canvasID,
      canvasName: "Launch"
    )
    let matches = try await store.searchCanvasNotes(
      canvasID: canvasID,
      canvasName: "Launch",
      query: "founder campaign"
    )

    #expect(migrated.title == "Campaign ideas")
    #expect(matches.map(\.relativePath) == [migrated.relativePath])
    #expect(matches[0].tasks.first?.isCompleted == true)
  }

  @Test("Parses wiki links, resolves canvas notes, and indexes backlinks")
  func canvasNoteLinks() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-note-links-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)
    let canvasID = UUID()

    let destination = try await store.migrateCanvasNote(
      text: "# Launch plan\n\nShip it.\n",
      canvasID: canvasID,
      canvasName: "Product"
    )
    let source = try await store.migrateCanvasNote(
      text: "# Weekly meeting\n\nReview [[Launch plan]] and [[Launch plan|the plan]].\n",
      canvasID: canvasID,
      canvasName: "Product"
    )

    #expect(
      source.links == [
        CanvasNoteLink(target: "Launch plan", label: "Launch plan"),
        CanvasNoteLink(target: "Launch plan", label: "the plan"),
      ])
    #expect(
      try await store.resolveCanvasNote(
        canvasID: canvasID, canvasName: "Product", target: "launch PLAN")?.relativePath
        == destination.relativePath)
    #expect(
      try await store.backlinks(
        to: destination, canvasID: canvasID, canvasName: "Product"
      ).map(\.relativePath) == [source.relativePath])
    let created = try await store.resolveOrCreateCanvasNote(
      canvasID: canvasID, canvasName: "Product", target: "Research"
    )
    #expect(created.title == "Research")
    #expect(
      try await store.resolveOrCreateCanvasNote(
        canvasID: canvasID, canvasName: "Product", target: "research"
      ).relativePath == created.relativePath)
  }

  @Test("Renames a note's heading and durable file without overwriting siblings")
  func renamesCanvasNote() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-note-rename-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)
    let canvasID = UUID()
    let first = try await store.createCanvasNote(
      canvasID: canvasID, canvasName: "Product", template: .blank)
    _ = try await store.migrateCanvasNote(
      text: "# Launch plan\n\nExisting sibling\n", canvasID: canvasID, canvasName: "Product")

    let renamed = try await store.renameCanvasNote(
      relativePath: first.relativePath,
      title: "Launch plan",
      text: "# Untitled\n\nNew content\n"
    )

    #expect(renamed.note.title == "Launch plan")
    #expect(renamed.note.relativePath.hasSuffix("/Launch plan 2.md"))
    #expect(renamed.text == "# Launch plan\n\nNew content\n")
    #expect(try await store.read(relativePath: renamed.note.relativePath) == renamed.text)
    await #expect(throws: (any Error).self) {
      try await store.read(relativePath: first.relativePath)
    }
    await #expect(throws: (any Error).self) {
      try await store.renameCanvasNote(
        relativePath: renamed.note.relativePath, title: "  ", text: renamed.text)
    }
  }

  @Test("Directory watcher survives atomic external replacement")
  func watchesAtomicReplacement() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-watch-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)
    try await store.replace(relativePath: "goals.md", text: "first")
    let updates = try await store.watch(relativePath: "goals.md")
    let eventTask = Task<DocumentFileEvent?, Never> {
      for await event in updates { return event }
      return nil
    }

    try Data("external replacement".utf8).write(
      to: root.appending(path: "goals.md"),
      options: .atomic
    )

    let event = await withTaskGroup(of: DocumentFileEvent?.self) { group in
      group.addTask { await eventTask.value }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    #expect(event == .changed)
    #expect(try await store.read(relativePath: "goals.md") == "external replacement")
  }

  @Test("Rejects traversal, absolute paths, and symlink escapes")
  func confinement() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-safe-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceDocumentStore(rootPath: root.path)

    await #expect(throws: (any Error).self) {
      try await store.replace(relativePath: "../escape.md", text: "no")
    }
    await #expect(throws: (any Error).self) {
      try await store.replace(relativePath: "/tmp/escape.md", text: "no")
    }

    let link = root.appending(path: "outside")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))
    await #expect(throws: (any Error).self) {
      try await store.replace(relativePath: "outside/escape.md", text: "no")
    }
  }
}

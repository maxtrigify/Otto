import Darwin
import Dispatch
import Foundation

public enum DocumentFileEvent: Equatable, Sendable {
  case changed
  case deleted
}

public enum DocumentStoreError: Error, LocalizedError, Sendable {
  case unsafePath(String)
  case unreadable(String)
  case invalidTitle

  public var errorDescription: String? {
    switch self {
    case .unsafePath(let path): "Document path escapes the workspace: \(path)"
    case .unreadable(let path): "Document cannot be read as UTF-8: \(path)"
    case .invalidTitle: "Note names cannot be empty."
    }
  }
}

public enum CanvasNoteTemplate: String, CaseIterable, Identifiable, Sendable {
  case blank
  case todo
  case meeting
  case idea
  case decision

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .blank: "Untitled"
    case .todo: "Todo"
    case .meeting: "Meeting notes"
    case .idea: "Idea"
    case .decision: "Decision"
    }
  }

  public var initialText: String {
    switch self {
    case .blank: "# Untitled\n\n"
    case .todo: "# Todo\n\n- [ ] First task\n"
    case .meeting:
      "# Meeting notes\n\n**Date:** \n**Attendees:** \n\n## Agenda\n\n- \n\n## Notes\n\n\n## Actions\n\n- [ ] \n"
    case .idea:
      "# Idea\n\n## The idea\n\n\n## Why it matters\n\n\n## Next step\n\n- [ ] \n"
    case .decision:
      "# Decision\n\n**Status:** Proposed\n\n## Context\n\n\n## Decision\n\n\n## Consequences\n\n"
    }
  }
}

public struct CanvasNoteTask: Identifiable, Equatable, Sendable {
  public let notePath: String
  public let noteTitle: String
  public let lineNumber: Int
  public let text: String
  public let isCompleted: Bool

  public var id: String { "\(notePath):\(lineNumber)" }
}

public struct CanvasNoteSummary: Identifiable, Equatable, Sendable {
  public let relativePath: String
  public let title: String
  public let modifiedAt: Date
  public let tasks: [CanvasNoteTask]
  public let links: [CanvasNoteLink]

  public var id: String { relativePath }
}

public struct CanvasNoteRenameResult: Equatable, Sendable {
  public let note: CanvasNoteSummary
  public let text: String
}

public struct CanvasNoteLink: Equatable, Sendable {
  public let target: String
  public let label: String

  public init(target: String, label: String) {
    self.target = target
    self.label = label
  }

  public static func parse(in text: String) -> [CanvasNoteLink] {
    guard let expression = try? NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)
    else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let contentRange = Range(match.range(at: 1), in: text) else { return nil }
      let pieces = text[contentRange].split(
        separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
      let target = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { return nil }
      let label =
        pieces.count == 2
        ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
        : target
      return CanvasNoteLink(target: target, label: label.isEmpty ? target : label)
    }
  }
}

public actor WorkspaceDocumentStore {
  public nonisolated let rootPath: String

  public init(rootPath: String) {
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    self.rootPath = root.path
  }

  public func read(relativePath: String) throws -> String {
    let url = try resolve(relativePath, createParents: false)
    guard let text = try String(contentsOf: url, encoding: .utf8) as String? else {
      throw DocumentStoreError.unreadable(relativePath)
    }
    return text
  }

  public func replace(relativePath: String, text: String) throws {
    let url = try resolve(relativePath, createParents: true)
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  /// Moves a workspace file or directory to the Trash, so removals stay user-recoverable.
  /// Missing paths are a no-op: deleting an already-gone package should not fail the caller.
  public func trash(relativePath: String) throws {
    let url = try resolve(relativePath, createParents: false)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }

  public func append(relativePath: String, text: String) throws -> String {
    let existing = (try? read(relativePath: relativePath)) ?? ""
    let updated = existing + text
    try replace(relativePath: relativePath, text: updated)
    return updated
  }

  public func createCanvasNote(
    canvasID: UUID,
    canvasName: String,
    template: CanvasNoteTemplate = .blank
  ) throws -> CanvasNoteSummary {
    try createUniqueCanvasNote(
      text: template.initialText,
      title: template.title,
      canvasID: canvasID,
      canvasName: canvasName
    )
  }

  /// Gives an old canvas-only note a durable file without overwriting any existing note.
  public func migrateCanvasNote(
    text: String,
    canvasID: UUID,
    canvasName: String
  ) throws -> CanvasNoteSummary {
    try createUniqueCanvasNote(
      text: text,
      title: Self.noteTitle(text: text, fallback: "Untitled"),
      canvasID: canvasID,
      canvasName: canvasName
    )
  }

  public func listCanvasNotes(canvasID: UUID, canvasName: String) throws -> [CanvasNoteSummary] {
    let directory = canvasNotesDirectory(canvasID: canvasID, canvasName: canvasName)
    try createSafeDirectories(components: NSString(string: directory).pathComponents)
    let directoryURL = try resolve(directory, createParents: false)
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    return
      try urls
      .filter { $0.pathExtension.lowercased() == "md" }
      .map { url in
        let relativePath = "\(directory)/\(url.lastPathComponent)"
        return try noteSummary(relativePath: relativePath)
      }
      .sorted {
        if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
  }

  public func searchCanvasNotes(
    canvasID: UUID,
    canvasName: String,
    query: String
  ) throws -> [CanvasNoteSummary] {
    let notes = try listCanvasNotes(canvasID: canvasID, canvasName: canvasName)
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !terms.isEmpty else { return notes }
    return try notes.filter { note in
      let body = try read(relativePath: note.relativePath)
      let haystack = note.title + "\n" + body
      return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
    }
  }

  public func resolveCanvasNote(
    canvasID: UUID,
    canvasName: String,
    target: String
  ) throws -> CanvasNoteSummary? {
    let normalizedTarget = Self.normalizedNoteReference(target)
    return try listCanvasNotes(canvasID: canvasID, canvasName: canvasName).first { note in
      Self.normalizedNoteReference(note.title) == normalizedTarget
        || Self.normalizedNoteReference(
          URL(fileURLWithPath: note.relativePath).deletingPathExtension().lastPathComponent
        ) == normalizedTarget
        || Self.normalizedNoteReference(note.relativePath) == normalizedTarget
    }
  }

  public func resolveOrCreateCanvasNote(
    canvasID: UUID,
    canvasName: String,
    target: String
  ) throws -> CanvasNoteSummary {
    if let existing = try resolveCanvasNote(
      canvasID: canvasID,
      canvasName: canvasName,
      target: target
    ) {
      return existing
    }
    let title = target.trimmingCharacters(in: .whitespacesAndNewlines)
    return try createUniqueCanvasNote(
      text: "# \(title.isEmpty ? "Untitled" : title)\n\n",
      title: title.isEmpty ? "Untitled" : title,
      canvasID: canvasID,
      canvasName: canvasName
    )
  }

  public func renameCanvasNote(
    relativePath: String,
    title: String,
    text: String
  ) throws -> CanvasNoteRenameResult {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else { throw DocumentStoreError.invalidTitle }
    let sourceURL = try resolve(relativePath, createParents: false)
    let directory = NSString(string: relativePath).deletingLastPathComponent
    let updatedText = Self.replacingNoteTitle(in: text, with: trimmedTitle)
    let stem = sanitizedFilename(trimmedTitle)
    var destinationPath = "\(directory)/\(stem).md"
    var ordinal = 1
    while destinationPath != relativePath,
      FileManager.default.fileExists(
        atPath: try resolve(destinationPath, createParents: false).path)
    {
      ordinal += 1
      destinationPath = "\(directory)/\(stem) \(ordinal).md"
    }

    if destinationPath == relativePath {
      try replace(relativePath: relativePath, text: updatedText)
    } else {
      let destinationURL = try resolve(destinationPath, createParents: true)
      try Data(updatedText.utf8).write(to: destinationURL, options: .atomic)
      do {
        try FileManager.default.removeItem(at: sourceURL)
      } catch {
        try? FileManager.default.removeItem(at: destinationURL)
        throw error
      }
    }
    return CanvasNoteRenameResult(
      note: try noteSummary(relativePath: destinationPath),
      text: updatedText
    )
  }

  public func backlinks(
    to note: CanvasNoteSummary,
    canvasID: UUID,
    canvasName: String
  ) throws -> [CanvasNoteSummary] {
    let title = Self.normalizedNoteReference(note.title)
    let path = Self.normalizedNoteReference(note.relativePath)
    let stem = Self.normalizedNoteReference(
      URL(fileURLWithPath: note.relativePath).deletingPathExtension().lastPathComponent)
    return try listCanvasNotes(canvasID: canvasID, canvasName: canvasName).filter { candidate in
      candidate.relativePath != note.relativePath
        && candidate.links.contains { link in
          let target = Self.normalizedNoteReference(link.target)
          return target == title || target == path || target == stem
        }
    }
  }

  public func watch(relativePath: String) throws -> AsyncStream<DocumentFileEvent> {
    let file = try resolve(relativePath, createParents: false)
    let directory = file.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else { throw DocumentStoreError.unreadable(relativePath) }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: DispatchQueue(label: "io.openotto.document-watch.\(UUID().uuidString)")
    )
    let token = DocumentWatchToken(source: source, descriptor: descriptor)
    return AsyncStream { continuation in
      source.setEventHandler {
        continuation.yield(
          FileManager.default.fileExists(atPath: file.path) ? .changed : .deleted)
      }
      source.setCancelHandler { close(descriptor) }
      continuation.onTermination = { [token] _ in token.cancel() }
      source.resume()
    }
  }

  private func resolve(_ relativePath: String, createParents: Bool) throws -> URL {
    guard !relativePath.hasPrefix("/"), !relativePath.isEmpty else {
      throw DocumentStoreError.unsafePath(relativePath)
    }
    let components = NSString(string: relativePath).pathComponents
    guard !components.contains(".."), !components.contains("~") else {
      throw DocumentStoreError.unsafePath(relativePath)
    }

    var candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
    for component in components {
      candidate.appendPathComponent(component)
    }
    guard isInsideRoot(candidate) else { throw DocumentStoreError.unsafePath(relativePath) }
    let parent = candidate.deletingLastPathComponent()
    if createParents {
      try createSafeDirectories(components: Array(components.dropLast()))
    }
    let resolvedParent = parent.resolvingSymlinksInPath()
    guard isInsideRoot(resolvedParent) else { throw DocumentStoreError.unsafePath(relativePath) }
    if FileManager.default.fileExists(atPath: candidate.path) {
      guard isInsideRoot(candidate.resolvingSymlinksInPath()) else {
        throw DocumentStoreError.unsafePath(relativePath)
      }
    }
    return candidate
  }

  private func createUniqueCanvasNote(
    text: String,
    title: String,
    canvasID: UUID,
    canvasName: String
  ) throws -> CanvasNoteSummary {
    let directory = canvasNotesDirectory(canvasID: canvasID, canvasName: canvasName)
    let stem = sanitizedFilename(title)
    var ordinal = 1
    var relativePath = "\(directory)/\(stem).md"
    while FileManager.default.fileExists(
      atPath: try resolve(relativePath, createParents: false).path)
    {
      ordinal += 1
      relativePath = "\(directory)/\(stem) \(ordinal).md"
    }
    try replace(relativePath: relativePath, text: text)
    return try noteSummary(relativePath: relativePath)
  }

  private func canvasNotesDirectory(canvasID: UUID, canvasName: String) -> String {
    let name = sanitizedFilename(canvasName)
    let suffix = canvasID.uuidString.lowercased().prefix(8)
    let notesRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
      .appendingPathComponent("Notes", isDirectory: true)
    if let directories = try? FileManager.default.contentsOfDirectory(
      at: notesRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ),
      let existing = directories.first(where: { url in
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory && url.lastPathComponent.hasSuffix("-\(suffix)")
      })
    {
      return "Notes/\(existing.lastPathComponent)"
    }
    return "Notes/\(name)-\(suffix)"
  }

  private func sanitizedFilename(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let pieces = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
    let joined = pieces.joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return String((joined.isEmpty ? "Untitled" : joined).prefix(80))
  }

  private func noteSummary(relativePath: String) throws -> CanvasNoteSummary {
    let url = try resolve(relativePath, createParents: false)
    let text = try read(relativePath: relativePath)
    let fallback = url.deletingPathExtension().lastPathComponent
    let title = Self.noteTitle(text: text, fallback: fallback)
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
    return CanvasNoteSummary(
      relativePath: relativePath,
      title: title,
      modifiedAt: values.contentModificationDate ?? .distantPast,
      tasks: Self.noteTasks(text: text, relativePath: relativePath, title: title),
      links: CanvasNoteLink.parse(in: text)
    )
  }

  private static func normalizedNoteReference(_ value: String) -> String {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "/")
      .lowercased()
    if normalized.hasSuffix(".md") { normalized.removeLast(3) }
    return normalized
  }

  private static func noteTitle(text: String, fallback: String) -> String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("# ") {
        let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
      }
    }
    return fallback
  }

  private static func replacingNoteTitle(in text: String, with title: String) -> String {
    var lines = text.components(separatedBy: .newlines)
    if let index = lines.firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
    }) {
      let indentation = String(lines[index].prefix { $0.isWhitespace })
      lines[index] = "\(indentation)# \(title)"
      return lines.joined(separator: "\n")
    }
    return "# \(title)\n\n\(text)"
  }

  private static func noteTasks(text: String, relativePath: String, title: String)
    -> [CanvasNoteTask]
  {
    text.components(separatedBy: .newlines).enumerated().compactMap { offset, line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let markerLength: Int
      let completed: Bool
      if trimmed.hasPrefix("- [ ] ") {
        markerLength = 6
        completed = false
      } else if trimmed.lowercased().hasPrefix("- [x] ") {
        markerLength = 6
        completed = true
      } else {
        return nil
      }
      return CanvasNoteTask(
        notePath: relativePath,
        noteTitle: title,
        lineNumber: offset + 1,
        text: String(trimmed.dropFirst(markerLength)),
        isCompleted: completed
      )
    }
  }

  private func createSafeDirectories(components: [String]) throws {
    var current = URL(fileURLWithPath: rootPath, isDirectory: true)
    for component in components {
      current.appendPathComponent(component, isDirectory: true)
      if FileManager.default.fileExists(atPath: current.path) {
        guard isInsideRoot(current.resolvingSymlinksInPath()) else {
          throw DocumentStoreError.unsafePath(current.path)
        }
      } else {
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
      }
    }
  }

  private func isInsideRoot(_ url: URL) -> Bool {
    url.path == rootPath || url.path.hasPrefix(rootPath + "/")
  }
}

private final class DocumentWatchToken: @unchecked Sendable {
  private let source: DispatchSourceFileSystemObject
  private let lock = NSLock()
  private var cancelled = false

  init(source: DispatchSourceFileSystemObject, descriptor: Int32) {
    self.source = source
  }

  func cancel() {
    lock.withLock {
      guard !cancelled else { return }
      cancelled = true
      source.cancel()
    }
  }

  deinit { cancel() }
}

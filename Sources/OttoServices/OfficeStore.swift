#if canImport(AppKit)
  import AppKit
#endif
#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels

/// Documents, spreadsheets and presentations a person writes with their agents. They are real
/// files in the space's `Documents` folder: Word documents (.docx), Otto sheets and Otto slides,
/// so they stay visible in Finder and export to Office formats.
public enum OfficeKind: String, Codable, Sendable, CaseIterable, Identifiable {
  case document, spreadsheet, presentation

  public var id: String { rawValue }
  public var fileExtension: String {
    switch self {
    case .document: "docx"
    case .spreadsheet: "ottosheet"
    case .presentation: "ottoslides"
    }
  }

  /// Extensions this kind opens: the current one plus `.musesheet` / `.museslides` files
  /// created before the rename. New files always use `fileExtension`.
  public var readableFileExtensions: Set<String> {
    switch self {
    case .document: ["docx"]
    case .spreadsheet: ["ottosheet", "musesheet"]
    case .presentation: ["ottoslides", "museslides"]
    }
  }
  public var displayName: String {
    switch self {
    case .document: "Document"
    case .spreadsheet: "Spreadsheet"
    case .presentation: "Presentation"
    }
  }
  public var symbol: String {
    switch self {
    case .document: "doc.richtext"
    case .spreadsheet: "tablecells"
    case .presentation: "rectangle.on.rectangle.angled"
    }
  }

  public init?(fileExtension: String) {
    let value = fileExtension.lowercased()
    guard let kind = Self.allCases.first(where: { $0.readableFileExtensions.contains(value) })
    else { return nil }
    self = kind
  }

  /// Accepts "doc", "sheet", "slides", "deck" and the like from agents.
  public init?(loose: String) {
    switch loose.lowercased().trimmingCharacters(in: .whitespaces) {
    case "document", "doc", "docs", "word", "docx", "text": self = .document
    case "spreadsheet", "sheet", "sheets", "excel", "xlsx", "table": self = .spreadsheet
    case "presentation", "slides", "slide", "deck", "powerpoint", "pptx": self = .presentation
    default: return nil
    }
  }
}

public struct OfficeFile: Identifiable, Hashable, Sendable {
  /// Path relative to the space folder, e.g. "Documents/Plan.docx".
  public var path: String
  public var kind: OfficeKind
  public var title: String
  public var modifiedAt: Date
  public var id: String { path }
}

/// A change an agent proposes to a document. The person accepts or rejects it.
public struct DocSuggestion: Codable, Sendable, Equatable, Identifiable {
  public enum Change: Codable, Sendable, Equatable {
    /// Replace the first occurrence of `find` with `replace`.
    case replace(find: String, replace: String)
    /// Add text at the end.
    case append(String)
    /// Replace the whole document.
    case replaceAll(String)
  }

  public var id: UUID
  public var path: String
  public var change: Change
  public var note: String?
  public var author: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(), path: String, change: Change, note: String?, author: String,
    createdAt: Date = .now
  ) {
    self.id = id
    self.path = path
    self.change = change
    self.note = note
    self.author = author
    self.createdAt = createdAt
  }

  /// The text being replaced, if any, so the editor can highlight it.
  public var target: String? {
    if case .replace(let find, _) = change { return find }
    return nil
  }

  public var proposed: String {
    switch change {
    case .replace(_, let replace): replace
    case .append(let text), .replaceAll(let text): text
    }
  }
}

/// An open editor registers itself so agent changes land in the live text, with undo, instead
/// of fighting it on disk.
@MainActor
public protocol LiveOfficeDocument: AnyObject {
  /// The editor's current words, or nil once its text view has gone away.
  var plainText: String? { get }
  /// Applies a change in the editor. Returns false when the target text is no longer there.
  func apply(_ change: DocSuggestion.Change) -> Bool
}

@MainActor
public final class OfficeStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var suggestions: [DocSuggestion] = []
    /// The side-chat agent for each file.
    var sessions: [String: UUID] = [:]
  }

  public enum OfficeError: Error, LocalizedError {
    case emptyTitle
    case unknownFile(String)
    case unreadable(String)
    case notFound(String)
    case wrongKind(String, OfficeKind)
    public var errorDescription: String? {
      switch self {
      case .emptyTitle: "Give it a name."
      case .unknownFile(let name): "There is no document called \"\(name)\"."
      case .unreadable(let name): "Otto could not open \"\(name)\"."
      case .notFound(let text):
        "That text is not in the document any more: \"\(String(text.prefix(60)))\""
      case .wrongKind(let name, let kind):
        "\"\(name)\" is not a \(kind.displayName.lowercased())."
      }
    }
  }

  public let workspaceURL: URL
  public let folderURL: URL
  @Published public private(set) var files: [OfficeFile] = []
  @Published private var state = State()
  /// Cells, slide ids or other marks agents changed recently, per file, for highlighting.
  @Published public private(set) var agentTouched: [String: Set<String>] = [:]
  /// Bumped whenever a sheet or deck changes on disk so open editors reload.
  @Published public private(set) var revisions: [String: Int] = [:]
  @Published public private(set) var persistenceError: String?
  private var live: [String: any LiveOfficeDocument] = [:]
  private let stateURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    workspaceURL = URL(fileURLWithPath: workspacePath)
    folderURL = workspaceURL.appending(path: "Documents")
    stateURL = workspaceURL.appending(path: ".otto/office.json")
    do {
      if let saved = try WorkspaceJSONFile.load(
        State.self, from: stateURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
    refresh()
  }

  // MARK: Files

  public func refresh() {
    let urls =
      (try? fileManager.contentsOfDirectory(
        at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []
    files =
      urls.compactMap { url -> OfficeFile? in
        guard let kind = OfficeKind(fileExtension: url.pathExtension) else { return nil }
        let modified =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return OfficeFile(
          path: "Documents/" + url.lastPathComponent, kind: kind,
          title: url.deletingPathExtension().lastPathComponent, modifiedAt: modified)
      }
      .sorted { $0.modifiedAt > $1.modifiedAt }
  }

  public func url(for path: String) -> URL { workspaceURL.appending(path: path) }

  public func file(path: String) -> OfficeFile? { files.first { $0.path == path } }

  /// Finds a file by path, exact title or a clearly matching title.
  public func file(named reference: String, kind: OfficeKind? = nil) -> OfficeFile? {
    refresh()
    let key = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    let pool = files.filter { kind == nil || $0.kind == kind }
    if let byPath = pool.first(where: { $0.path == key || $0.path == "Documents/" + key }) {
      return byPath
    }
    if let exact = pool.first(where: { $0.title.caseInsensitiveCompare(key) == .orderedSame }) {
      return exact
    }
    let close = pool.filter { HomeCard.titleSimilarity($0.title, key) >= 0.99 }
    return close.count == 1 ? close[0] : nil
  }

  @discardableResult
  public func create(_ kind: OfficeKind, title: String) throws -> OfficeFile {
    let name = Self.safeFileName(title)
    guard !name.isEmpty else { throw OfficeError.emptyTitle }
    try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
    var candidate = name
    var counter = 2
    // A pre-rename `.musesheet`/`.museslides` file with the same title counts as taken too.
    while kind.readableFileExtensions.contains(where: {
      fileManager.fileExists(atPath: folderURL.appending(path: "\(candidate).\($0)").path)
    }) {
      candidate = "\(name) \(counter)"
      counter += 1
    }
    let path = "Documents/\(candidate).\(kind.fileExtension)"
    switch kind {
    case .document: try saveDocument(NSAttributedString(string: ""), path: path)
    case .spreadsheet: try saveSheet(Spreadsheet(), path: path)
    case .presentation:
      try saveDeck(
        Presentation(slides: [Slide(title: candidate, layout: .title)]), path: path)
    }
    refresh()
    return file(path: path)
      ?? OfficeFile(path: path, kind: kind, title: candidate, modifiedAt: .now)
  }

  /// Renames a file on disk and carries its suggestions and side chat over.
  @discardableResult
  public func rename(path: String, to title: String) throws -> String {
    guard let file = file(path: path) else { throw OfficeError.unknownFile(path) }
    let name = Self.safeFileName(title)
    guard !name.isEmpty else { throw OfficeError.emptyTitle }
    guard name != file.title else { return path }
    let newPath = "Documents/\(name).\(file.kind.fileExtension)"
    guard !fileManager.fileExists(atPath: url(for: newPath).path) else { return path }
    try fileManager.moveItem(at: url(for: path), to: url(for: newPath))
    var next = state
    next.suggestions = next.suggestions.map {
      var suggestion = $0
      if suggestion.path == path { suggestion.path = newPath }
      return suggestion
    }
    if let session = next.sessions.removeValue(forKey: path) { next.sessions[newPath] = session }
    try persist(next)
    if let editor = live.removeValue(forKey: path) { live[newPath] = editor }
    refresh()
    return newPath
  }

  /// Moves a file to the Trash, so it can be put back from Finder.
  public func trash(path: String) throws {
    #if canImport(AppKit)
      try fileManager.trashItem(at: url(for: path), resultingItemURL: nil)
    #else
      // No system Trash API here: keep the file recoverable beside the documents.
      let trash = workspaceURL.appending(path: ".trash", directoryHint: .isDirectory)
      try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
      let source = url(for: path)
      try fileManager.moveItem(
        at: source,
        to: trash.appending(path: "\(Int(Date().timeIntervalSince1970))-\(source.lastPathComponent)"))
    #endif
    var next = state
    next.suggestions.removeAll { $0.path == path }
    next.sessions[path] = nil
    try persist(next)
    refresh()
  }

  /// Brings a Word document or CSV into the Documents folder.
  @discardableResult
  public func importFile(_ source: URL) throws -> OfficeFile {
    let title = source.deletingPathExtension().lastPathComponent
    switch source.pathExtension.lowercased() {
    case "docx", "doc", "rtf", "txt", "md", "odt":
      let text = try Self.readAttributed(source)
      let file = try create(.document, title: title)
      try saveDocument(text, path: file.path)
      return file
    case "csv", "tsv":
      let raw = try String(contentsOf: source, encoding: .utf8)
      let csv =
        source.pathExtension.lowercased() == "tsv"
        ? raw.replacingOccurrences(of: "\t", with: ",") : raw
      let file = try create(.spreadsheet, title: title)
      try saveSheet(SpreadsheetCSV.decode(csv), path: file.path)
      return file
    default:
      throw OfficeError.unreadable(source.lastPathComponent)
    }
  }

  // MARK: Documents

  public func loadDocument(path: String) throws -> NSAttributedString {
    try Self.readAttributed(url(for: path))
  }

  public func saveDocument(_ text: NSAttributedString, path: String) throws {
    #if canImport(AppKit)
      let data = try text.data(
        from: NSRange(location: 0, length: text.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    #else
      // Without AppKit's Word exporter, write the words as plain Word paragraphs.
      let paragraphs = text.string.components(separatedBy: "\n").map {
        DocxDocument.Paragraph(runs: [DocxDocument.Run(text: $0)])
      }
      let data = DocxWriter.data(DocxDocument(paragraphs: paragraphs))
    #endif
    try data.write(to: url(for: path), options: .atomic)
  }

  /// The document's words: from the open editor when there is one, else from disk.
  public func documentText(path: String) throws -> String {
    if let editor = live[path], let text = editor.plainText { return text }
    return try loadDocument(path: path).string
  }

  public func register(_ editor: any LiveOfficeDocument, path: String) { live[path] = editor }

  public func unregister(_ editor: any LiveOfficeDocument, path: String) {
    if live[path] === editor { live[path] = nil }
  }

  public func suggestions(path: String) -> [DocSuggestion] {
    state.suggestions.filter { $0.path == path }
  }

  public var allSuggestions: [DocSuggestion] { state.suggestions }

  /// Applies a change now: through the open editor if any, otherwise on disk.
  public func applyNow(_ change: DocSuggestion.Change, path: String) throws {
    if let editor = live[path], editor.plainText != nil {
      guard editor.apply(change) else {
        if case .replace(let find, _) = change { throw OfficeError.notFound(find) }
        return
      }
      return
    }
    let current = NSMutableAttributedString(attributedString: try loadDocument(path: path))
    guard Self.apply(change, to: current) else {
      if case .replace(let find, _) = change { throw OfficeError.notFound(find) }
      return
    }
    try saveDocument(current, path: path)
    refresh()
  }

  @discardableResult
  public func suggest(_ suggestion: DocSuggestion) throws -> DocSuggestion {
    var next = state
    next.suggestions.append(suggestion)
    try persist(next)
    return suggestion
  }

  public func accept(_ id: UUID) throws {
    guard let suggestion = state.suggestions.first(where: { $0.id == id }) else { return }
    defer { try? dismiss(id) }
    try applyNow(suggestion.change, path: suggestion.path)
  }

  public func dismiss(_ id: UUID) throws {
    var next = state
    next.suggestions.removeAll { $0.id == id }
    try persist(next)
  }

  // MARK: Sheets and decks

  /// Every tab of a spreadsheet. Files saved before tabs existed open as one tab.
  public func loadWorkbook(path: String) throws -> SpreadsheetWorkbook {
    try JSONDecoder().decode(SpreadsheetWorkbook.self, from: Data(contentsOf: url(for: path)))
  }

  /// Saves every tab. `touched` holds tab-qualified cells ("Sales!B2") an agent changed.
  public func saveWorkbook(
    _ book: SpreadsheetWorkbook, path: String, touched: Set<String>? = nil
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(book).write(to: url(for: path), options: .atomic)
    if let touched {
      agentTouched[path, default: []].formUnion(touched)
      revisions[path, default: 0] += 1
    }
  }

  /// One tab by name, or the first tab.
  public func loadSheet(path: String, tab: String? = nil) throws -> Spreadsheet {
    let book = try loadWorkbook(path: path)
    guard let tab else { return book.tabs[0].sheet }
    guard let found = book.tab(named: tab) else {
      throw SpreadsheetWorkbook.TabError.unknownTab(tab)
    }
    return found.sheet
  }

  /// Replaces one tab (the first when `tab` is nil), adding it when a new name is given. Other
  /// tabs are kept. `touched` holds plain cell addresses on that tab.
  public func saveSheet(
    _ sheet: Spreadsheet, path: String, tab: String? = nil, touched: Set<String>? = nil
  ) throws {
    var book =
      fileManager.fileExists(atPath: url(for: path).path)
      ? try loadWorkbook(path: path) : SpreadsheetWorkbook()
    var target = book.tabs[0]
    if let tab {
      target = try book.tab(named: tab) ?? book.addTab(named: tab)
    }
    book.setSheet(sheet, for: target.id)
    let name = book.tabs[book.index(of: target.id) ?? 0].name
    try saveWorkbook(
      book, path: path, touched: touched.map { Set($0.map { "\(name)!\($0)" }) })
  }

  public func loadDeck(path: String) throws -> Presentation {
    try JSONDecoder().decode(Presentation.self, from: Data(contentsOf: url(for: path)))
  }

  public func saveDeck(_ deck: Presentation, path: String, touched: Set<String>? = nil) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(deck).write(to: url(for: path), options: .atomic)
    if let touched {
      agentTouched[path, default: []].formUnion(touched)
      revisions[path, default: 0] += 1
    }
  }

  public func clearTouched(path: String) { agentTouched[path] = nil }

  // MARK: Helper chats

  /// The helper agent bound to a file path or another work key such as "dashboard:<id>".
  public func session(path: String) -> UUID? { state.sessions[path] }

  public func setSession(_ nodeID: UUID?, path: String) {
    var next = state
    next.sessions[path] = nodeID
    try? persist(next)
  }

  /// Every agent bound to a document or dashboard. Chat keeps these out of its session list.
  public var boundSessionIDs: Set<UUID> { Set(state.sessions.values) }

  /// What a helper agent is bound to, if anything.
  public func binding(of nodeID: UUID) -> String? {
    state.sessions.first { $0.value == nodeID }?.key
  }

  public static func dashboardKey(_ id: UUID) -> String { "dashboard:\(id.uuidString)" }

  /// The agent that last ran a card's update automation. It belongs to the card, so it stays
  /// out of Chat like any other bound helper.
  public static func cardRunKey(_ cardID: UUID) -> String { "card-run:\(cardID.uuidString)" }
  public static func automationRunKey(_ routineID: UUID) -> String {
    "automation-run:\(routineID.uuidString)"
  }

  /// Agents doing a card's background update. They are never shown as sessions.
  public var cardRunNodeIDs: Set<UUID> {
    Set(state.sessions.filter { $0.key.hasPrefix("card-run:") }.values)
  }

  // MARK: Helpers

  private func persist(_ next: State) throws {
    try WorkspaceJSONFile.save(next, to: stateURL, fileManager: fileManager)
    state = next
    persistenceError = nil
  }

  static func safeFileName(_ title: String) -> String {
    let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
    return String(
      title.components(separatedBy: banned).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        .prefix(80))
  }

  static func readAttributed(_ url: URL) throws -> NSAttributedString {
    let data = try Data(contentsOf: url)
    if data.isEmpty { return NSAttributedString(string: "") }
    #if !canImport(AppKit)
      switch url.pathExtension.lowercased() {
      case "txt", "md": return NSAttributedString(string: String(decoding: data, as: UTF8.self))
      case "docx":
        guard let paragraphs = DocxDocument.plainParagraphs(fromDocx: data) else {
          throw OfficeError.unreadable(url.lastPathComponent)
        }
        return NSAttributedString(string: paragraphs.joined(separator: "\n"))
      default: throw OfficeError.unreadable(url.lastPathComponent)
      }
    #else
    let type: NSAttributedString.DocumentType? =
      switch url.pathExtension.lowercased() {
      case "docx": .officeOpenXML
      case "doc": .docFormat
      case "rtf": .rtf
      case "odt": .openDocument
      case "txt", "md": .plain
      default: nil
      }
    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
    if let type { options[.documentType] = type }
    if type == .plain {
      return OfficeRichText.attributed(markdown: String(decoding: data, as: UTF8.self))
    }
    do {
      return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    } catch {
      throw OfficeError.unreadable(url.lastPathComponent)
    }
    #endif
  }

  /// Applies a change to attributed text, keeping the surrounding formatting.
  @discardableResult
  public static func apply(_ change: DocSuggestion.Change, to text: NSMutableAttributedString)
    -> Bool
  {
    #if !canImport(AppKit)
      // Plain text edits; rich formatting needs AppKit's text system.
      switch change {
      case .replace(let find, let replace):
        let range = (text.string as NSString).range(of: find)
        guard range.location != NSNotFound else { return false }
        text.replaceCharacters(in: range, with: replace)
      case .append(let addition):
        if text.length > 0 && !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n")) }
        text.append(NSAttributedString(string: addition))
      case .replaceAll(let replacement):
        text.setAttributedString(NSAttributedString(string: replacement))
      }
      return true
    #else
    switch change {
    case .replace(let find, let replace):
      let range = (text.string as NSString).range(of: find)
      guard range.location != NSNotFound else { return false }
      let base =
        range.length > 0
        ? text.attributes(at: range.location, effectiveRange: nil)
        : OfficeRichText.bodyAttributes
      text.replaceCharacters(
        in: range, with: OfficeRichText.inline(replace, attributes: base))
      return true
    case .append(let addition):
      let needsBreak = text.length > 0 && !text.string.hasSuffix("\n")
      if needsBreak {
        text.append(NSAttributedString(string: "\n", attributes: OfficeRichText.bodyAttributes))
      }
      text.append(OfficeRichText.attributed(markdown: addition))
      return true
    case .replaceAll(let replacement):
      text.setAttributedString(OfficeRichText.attributed(markdown: replacement))
      return true
    }
    #endif
  }
}

#if canImport(AppKit)
/// Turns the light Markdown agents write into Word-style formatting: headings, bullets, bold
/// and italics in Helvetica Neue, which exports cleanly to .docx.
public enum OfficeRichText {
  public static let bodySize: CGFloat = 14

  public static var bodyFont: NSFont {
    NSFont(name: "Helvetica Neue", size: bodySize) ?? .systemFont(ofSize: bodySize)
  }

  public static var bodyParagraph: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 3
    style.paragraphSpacing = 8
    return style
  }

  public static var bodyAttributes: [NSAttributedString.Key: Any] {
    [.font: bodyFont, .paragraphStyle: bodyParagraph, .foregroundColor: NSColor.black]
  }

  public static func headingFont(level: Int) -> NSFont {
    let size: CGFloat = [26, 20, 16][min(max(level, 1), 3) - 1]
    return NSFont(name: "Helvetica Neue Bold", size: size) ?? .boldSystemFont(ofSize: size)
  }

  public static func attributed(markdown: String) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    for (index, rawLine) in lines.enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      var attributes = bodyAttributes
      var content = line
      let hashes = line.prefix(while: { $0 == "#" }).count
      if hashes > 0, hashes <= 3, line.dropFirst(hashes).hasPrefix(" ") {
        content = String(line.dropFirst(hashes + 1))
        attributes[.font] = headingFont(level: hashes)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = hashes == 1 ? 6 : 10
        style.paragraphSpacing = 6
        attributes[.paragraphStyle] = style
      } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
        content = "•\t" + String(line.dropFirst(2))
        let style = NSMutableParagraphStyle()
        style.headIndent = 18
        style.firstLineHeadIndent = 4
        style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
        style.paragraphSpacing = 4
        style.lineSpacing = 2
        attributes[.paragraphStyle] = style
      } else if let match = line.firstMatch(of: /^(\d+)[.)] (.*)$/) {
        content = "\(match.1).\t\(match.2)"
        let style = NSMutableParagraphStyle()
        style.headIndent = 22
        style.firstLineHeadIndent = 2
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        style.paragraphSpacing = 4
        attributes[.paragraphStyle] = style
      }
      output.append(inline(content, attributes: attributes))
      if index < lines.count - 1 {
        output.append(NSAttributedString(string: "\n", attributes: attributes))
      }
    }
    return output
  }

  /// **bold**, *italic* and `code` within one line, on top of the given attributes.
  public static func inline(_ text: String, attributes: [NSAttributedString.Key: Any])
    -> NSAttributedString
  {
    let output = NSMutableAttributedString()
    let base = (attributes[.font] as? NSFont) ?? bodyFont
    var remaining = Substring(text)
    while !remaining.isEmpty {
      if let match = remaining.prefixMatch(of: /\*\*(.+?)\*\*/) {
        var bold = attributes
        bold[.font] = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        output.append(NSAttributedString(string: String(match.1), attributes: bold))
        remaining = remaining[match.range.upperBound...]
      } else if let match = remaining.prefixMatch(of: /\*(.+?)\*/) {
        var italic = attributes
        italic[.font] = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        output.append(NSAttributedString(string: String(match.1), attributes: italic))
        remaining = remaining[match.range.upperBound...]
      } else {
        let next = remaining.dropFirst().firstIndex(of: "*") ?? remaining.endIndex
        output.append(
          NSAttributedString(string: String(remaining[..<next]), attributes: attributes))
        remaining = remaining[next...]
      }
    }
    return output
  }
}

extension OfficeRichText {
  /// Turns the editor's formatted text into Word paragraphs with real heading styles and lists,
  /// which is what Word and Google Docs need to show an outline and proper bullets.
  public static func docx(_ text: NSAttributedString, title: String) -> DocxDocument {
    var paragraphs: [DocxDocument.Paragraph] = []
    let string = text.string as NSString
    string.enumerateSubstrings(
      in: NSRange(location: 0, length: string.length),
      options: [.byParagraphs, .substringNotRequired]
    ) { _, range, _, _ in
      paragraphs.append(paragraph(text, range: range))
    }
    return DocxDocument(paragraphs: paragraphs, title: title)
  }

  private static func paragraph(_ text: NSAttributedString, range: NSRange)
    -> DocxDocument.Paragraph
  {
    let plain = (text.string as NSString).substring(with: range)
    var style = DocxDocument.Style.body
    var skip = 0
    if plain.hasPrefix("•\t") || plain.hasPrefix("• ") {
      style = .bullet
      skip = 2
    } else if let match = plain.firstMatch(of: /^(\d+)[.)]\s/) {
      style = .number
      skip = match.output.0.count
    } else if range.length > 0,
      let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    {
      style =
        font.pointSize >= 23
        ? .heading1
        : font.pointSize >= 18
          ? .heading2
          : font.pointSize >= 15.5 && NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            ? .heading3 : .body
    }
    var alignment = DocxDocument.Alignment.left
    if range.length > 0,
      let paragraphStyle = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
    {
      switch paragraphStyle.alignment {
      case .center: alignment = .center
      case .right: alignment = .right
      case .justified: alignment = .both
      default: break
      }
    }
    let body = NSRange(location: range.location + skip, length: max(0, range.length - skip))
    var runs: [DocxDocument.Run] = []
    if body.length > 0 {
      text.enumerateAttributes(in: body) { attributes, runRange, _ in
        let chunk = (text.string as NSString).substring(with: runRange)
        let font = attributes[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        var color: String?
        if let value = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB),
          value.redComponent + value.greenComponent + value.blueComponent > 0.3
        {
          color = String(
            format: "%02X%02X%02X", Int(value.redComponent * 255),
            Int(value.greenComponent * 255), Int(value.blueComponent * 255))
        }
        runs.append(
          DocxDocument.Run(
            // Headings are bold through their style already.
            text: chunk,
            bold: traits.contains(.boldFontMask)
              && ![.heading1, .heading2, .heading3, .title].contains(style),
            italic: traits.contains(.italicFontMask),
            underline: (attributes[.underlineStyle] as? Int ?? 0) != 0, color: color))
      }
    }
    return DocxDocument.Paragraph(style: style, alignment: alignment, runs: runs)
  }
}
#endif

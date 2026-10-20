import AppKit
import OttoModels
import OttoServices
import SwiftUI
import UniformTypeIdentifiers

/// What the person asked the helper to do from inside a file.
struct OfficeAsk: Equatable {
  /// The selected text, cells or slide the request is about, if any.
  var quote: String?
  /// A ready-made request ("Make this shorter"); nil opens the box so they can type one.
  var request: String?
  /// A specific bot picked from the right-click menu.
  var bot: UUID?
}

/// Drives the AppKit text view from SwiftUI: formatting commands, agent changes with undo, and
/// highlighting text that has a pending suggestion.
@MainActor
final class DocEditorController: ObservableObject, LiveOfficeDocument {
  weak var textView: NSTextView?
  @Published var selection = ""
  @Published var wordCount = 0
  @Published var saveError: String?
  var onAsk: (OfficeAsk) -> Void = { _ in }
  var bots: () -> [(id: UUID, name: String)] = { [] }
  /// Writes the document to disk. The controller owns saving so a change is never lost when
  /// the view around it is rebuilt.
  var save: (NSAttributedString) throws -> Void = { _ in }
  private var saveTask: Task<Void, Never>?

  var plainText: String? { textView?.string }

  func changed() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      self?.saveNow()
    }
  }

  /// Saves straight away, e.g. before an agent reads the file.
  func saveNow() {
    do {
      try saveForExport()
    } catch {
      saveError = "Not saved: \(error.localizedDescription)"
    }
  }

  /// Export must stop on a save failure rather than reading an older file from disk.
  func saveForExport() throws {
    saveTask?.cancel()
    guard textView != nil else { return }
    try save(attributedText)
    saveError = nil
  }

  var attributedText: NSAttributedString {
    textView?.textStorage.map { NSAttributedString(attributedString: $0) }
      ?? NSAttributedString()
  }

  func apply(_ change: DocSuggestion.Change) -> Bool {
    guard let textView, let storage = textView.textStorage else { return false }
    let updated = NSMutableAttributedString(attributedString: storage)
    guard OfficeStore.apply(change, to: updated) else { return false }
    // One undoable step that swaps the whole text, so Cmd-Z takes an accepted change back.
    let full = NSRange(location: 0, length: storage.length)
    guard textView.shouldChangeText(in: full, replacementString: updated.string) else {
      return false
    }
    storage.setAttributedString(updated)
    textView.didChangeText()
    textView.undoManager?.setActionName("AI edit")
    return true
  }

  func highlight(_ suggestions: [DocSuggestion]) {
    guard let textView, let layout = textView.layoutManager else { return }
    let text = textView.string as NSString
    let all = NSRange(location: 0, length: text.length)
    layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
    layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
    for target in suggestions.compactMap(\.target) where !target.isEmpty {
      let range = text.range(of: target)
      guard range.location != NSNotFound else { continue }
      layout.addTemporaryAttributes(
        [
          .backgroundColor: NSColor.systemYellow.withAlphaComponent(0.32),
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], forCharacterRange: range)
    }
  }

  // MARK: Formatting

  enum TextStyle: String, CaseIterable, Identifiable {
    case title = "Title"
    case heading = "Heading"
    case subheading = "Subheading"
    case body = "Body"
    var id: String { rawValue }
  }

  func setStyle(_ style: TextStyle) {
    guard let textView, let storage = textView.textStorage else { return }
    let range = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
    let font: NSFont =
      switch style {
      case .title: OfficeRichText.headingFont(level: 1)
      case .heading: OfficeRichText.headingFont(level: 2)
      case .subheading: OfficeRichText.headingFont(level: 3)
      case .body: OfficeRichText.bodyFont
      }
    change(range) { storage in
      storage.addAttribute(.font, value: font, range: range)
    }
  }

  func toggleTrait(_ trait: NSFontTraitMask) {
    guard let textView, let storage = textView.textStorage else { return }
    let range = textView.selectedRange()
    guard range.length > 0 else {
      var typing = textView.typingAttributes
      let font = (typing[.font] as? NSFont) ?? OfficeRichText.bodyFont
      typing[.font] = Self.font(font, toggling: trait)
      textView.typingAttributes = typing
      return
    }
    let first = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    let adding = !(first.map { NSFontManager.shared.traits(of: $0).contains(trait) } ?? false)
    change(range) { storage in
      storage.enumerateAttribute(.font, in: range) { value, run, _ in
        let font = (value as? NSFont) ?? OfficeRichText.bodyFont
        let converted =
          adding
          ? NSFontManager.shared.convert(font, toHaveTrait: trait)
          : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
        storage.addAttribute(.font, value: converted, range: run)
      }
    }
  }

  func toggleUnderline() {
    guard let textView, let storage = textView.textStorage else { return }
    let range = textView.selectedRange()
    guard range.length > 0 else { return }
    let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil)
    let on = (current as? Int ?? 0) != 0
    change(range) { storage in
      if on {
        storage.removeAttribute(.underlineStyle, range: range)
      } else {
        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
      }
    }
  }

  /// Turns the selected paragraphs into a bulleted list, or back into plain paragraphs.
  func toggleBullets() {
    guard let textView, let storage = textView.textStorage else { return }
    let text = storage.string as NSString
    let range = text.paragraphRange(for: textView.selectedRange())
    let paragraphs = text.substring(with: range).components(separatedBy: "\n")
    let bulleted = paragraphs.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("•\t") }
    let replacement = NSMutableAttributedString()
    for (index, line) in paragraphs.enumerated() {
      let stripped = line.hasPrefix("•\t") ? String(line.dropFirst(2)) : line
      let markdown = bulleted || line.isEmpty ? stripped : "- " + stripped
      replacement.append(
        bulleted || line.isEmpty
          ? NSAttributedString(string: markdown, attributes: OfficeRichText.bodyAttributes)
          : OfficeRichText.attributed(markdown: markdown))
      if index < paragraphs.count - 1 {
        replacement.append(
          NSAttributedString(string: "\n", attributes: OfficeRichText.bodyAttributes))
      }
    }
    change(range) { storage in storage.replaceCharacters(in: range, with: replacement) }
  }

  func align(_ alignment: NSTextAlignment) {
    guard let textView, let storage = textView.textStorage else { return }
    let range = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
    change(range) { storage in
      storage.enumerateAttribute(.paragraphStyle, in: range) { value, run, _ in
        let style =
          ((value as? NSParagraphStyle) ?? OfficeRichText.bodyParagraph).mutableCopy()
          as! NSMutableParagraphStyle
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: run)
      }
    }
  }

  private func change(_ range: NSRange, _ edit: (NSTextStorage) -> Void) {
    guard let textView, let storage = textView.textStorage,
      textView.shouldChangeText(in: range, replacementString: nil)
    else { return }
    storage.beginEditing()
    edit(storage)
    storage.endEditing()
    textView.didChangeText()
  }

  static func font(_ font: NSFont, toggling trait: NSFontTraitMask) -> NSFont {
    NSFontManager.shared.traits(of: font).contains(trait)
      ? NSFontManager.shared.convert(font, toNotHaveTrait: trait)
      : NSFontManager.shared.convert(font, toHaveTrait: trait)
  }

  // MARK: Export

  /// Paginated US Letter / A4 PDF, the way the text would print.
  func pdfData() -> Data? {
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.topMargin = 54
    info.bottomMargin = 54
    info.leftMargin = 64
    info.rightMargin = 64
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let printView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    printView.textStorage?.setAttributedString(attributedText)
    printView.sizeToFit()
    let url = FileManager.default.temporaryDirectory.appending(path: "otto-\(UUID()).pdf")
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    let operation = NSPrintOperation(view: printView, printInfo: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    guard operation.run() else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    return try? Data(contentsOf: url)
  }
}

/// The page: an NSTextView with Word-like defaults, a right-click "Ask AI" menu, and autosave.
struct RichTextEditor: NSViewRepresentable {
  let initial: NSAttributedString
  let controller: DocEditorController

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = true
    scroll.backgroundColor = .white
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    // TextKit 1, so suggestions can be highlighted with temporary attributes.
    let textView = OttoDocTextView(usingTextLayoutManager: false)
    textView.controller = controller
    textView.isRichText = true
    textView.allowsUndo = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.isContinuousSpellCheckingEnabled = true
    textView.isAutomaticQuoteSubstitutionEnabled = true
    textView.isAutomaticDashSubstitutionEnabled = true
    textView.drawsBackground = true
    textView.backgroundColor = .white
    textView.textColor = .black
    textView.insertionPointColor = .black
    textView.textContainerInset = NSSize(width: 64, height: 56)
    textView.typingAttributes = OfficeRichText.bodyAttributes
    textView.selectedTextAttributes = [
      .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5)
    ]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textStorage?.setAttributedString(initial)
    textView.delegate = context.coordinator
    scroll.documentView = textView
    controller.textView = textView
    context.coordinator.updateCounts(textView)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    let controller: DocEditorController
    init(controller: DocEditorController) { self.controller = controller }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      updateCounts(textView)
      controller.changed()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      let range = textView.selectedRange()
      controller.selection =
        range.length > 0 ? (textView.string as NSString).substring(with: range) : ""
    }

    func updateCounts(_ textView: NSTextView) {
      controller.wordCount = textView.string.split { $0.isWhitespace || $0.isNewline }.count
    }
  }
}

/// Adds the agent actions to the text view's right-click menu.
final class OttoDocTextView: NSTextView {
  weak var controller: DocEditorController?

  /// Keeps the writing column a comfortable reading width, centred on the white page.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let column: CGFloat = 700
    let side = max(40, ((newSize.width - column) / 2).rounded())
    if abs(textContainerInset.width - side) > 0.5 {
      textContainerInset = NSSize(width: side, height: 56)
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    guard let controller else { return menu }
    let selected = (string as NSString).substring(with: selectedRange())
    let quote = selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : selected
    var items: [NSMenuItem] = []
    let ask = NSMenuItem(
      title: quote == nil ? "Ask AI…" : "Ask AI to edit this…", action: #selector(askAI(_:)),
      keyEquivalent: "")
    ask.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    ask.target = self
    ask.representedObject = quote
    items.append(ask)
    if quote != nil {
      for (title, request) in [
        ("Make it shorter", "Make this shorter and tighter, keeping the meaning."),
        ("Make it clearer", "Rewrite this to be clearer and easier to read."),
        ("Make it more formal", "Rewrite this in a more formal, professional tone."),
        ("Fix spelling and grammar", "Fix spelling, grammar and punctuation only."),
      ] {
        let item = NSMenuItem(title: title, action: #selector(quickAsk(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [quote ?? "", request]
        item.indentationLevel = 1
        items.append(item)
      }
    }
    let bots = controller.bots()
    if !bots.isEmpty {
      let tag = NSMenuItem(title: "Ask a bot", action: nil, keyEquivalent: "")
      tag.image = NSImage(systemSymbolName: "at", accessibilityDescription: nil)
      let submenu = NSMenu()
      for bot in bots {
        let item = NSMenuItem(title: bot.name, action: #selector(askBot(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [quote ?? "", bot.id.uuidString]
        submenu.addItem(item)
      }
      tag.submenu = submenu
      items.append(tag)
    }
    items.append(.separator())
    for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    return menu
  }

  @objc private func askAI(_ sender: NSMenuItem) {
    controller?.onAsk(OfficeAsk(quote: sender.representedObject as? String))
  }

  @objc private func quickAsk(_ sender: NSMenuItem) {
    guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
    controller?.onAsk(OfficeAsk(quote: pair[0], request: pair[1]))
  }

  @objc private func askBot(_ sender: NSMenuItem) {
    guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
    controller?.onAsk(
      OfficeAsk(quote: pair[0].isEmpty ? nil : pair[0], bot: UUID(uuidString: pair[1])))
  }
}

/// A Word-style page with a formatting bar. Agent edits arrive as suggestions in the side panel.
struct DocEditorView: View {
  @ObservedObject var office: OfficeStore
  let file: OfficeFile
  @ObservedObject var controller: DocEditorController
  let initial: NSAttributedString
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().overlay(palette.paper.opacity(0.08))
      RichTextEditor(initial: initial, controller: controller)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      footer
    }
    .onAppear {
      office.register(controller, path: file.path)
      controller.highlight(office.suggestions(path: file.path))
    }
    .onDisappear {
      controller.saveNow()
      office.unregister(controller, path: file.path)
    }
    .onReceive(office.objectWillChange) { _ in
      DispatchQueue.main.async { controller.highlight(office.suggestions(path: file.path)) }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      Menu {
        ForEach(DocEditorController.TextStyle.allCases) { style in
          Button(style.rawValue) { controller.setStyle(style) }
        }
      } label: {
        Text("Style").font(.ottoDisplay(12))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .padding(.trailing, 6)
      toolButton("bold", "Bold (⌘B)") { controller.toggleTrait(.boldFontMask) }
        .keyboardShortcut("b", modifiers: .command)
      toolButton("italic", "Italic (⌘I)") { controller.toggleTrait(.italicFontMask) }
        .keyboardShortcut("i", modifiers: .command)
      toolButton("underline", "Underline (⌘U)") { controller.toggleUnderline() }
        .keyboardShortcut("u", modifiers: .command)
      divider
      toolButton("list.bullet", "Bulleted list") { controller.toggleBullets() }
      divider
      toolButton("text.alignleft", "Align left") { controller.align(.left) }
      toolButton("text.aligncenter", "Centre") { controller.align(.center) }
      toolButton("text.alignright", "Align right") { controller.align(.right) }
      Spacer()
    }
    .padding(.horizontal, 14)
    .frame(height: 40)
  }

  private var divider: some View {
    Rectangle().fill(palette.paper.opacity(0.12)).frame(width: 1, height: 16).padding(
      .horizontal, 6)
  }

  private func toolButton(_ symbol: String, _ help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        .frame(width: 28, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(palette.paper.opacity(0.85))
    .help(help)
    .accessibilityLabel(help)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text("\(controller.wordCount) WORDS").font(.ottoMicro).tracking(1.4)
      if let saveError = controller.saveError {
        Text(saveError).font(.ottoDisplay(11)).foregroundStyle(palette.red).lineLimit(1)
      } else {
        Text("SAVED AS WORD (.DOCX)").font(.ottoMicro).tracking(1.4)
      }
      Spacer()
      Text("RIGHT-CLICK TEXT TO ASK AI").font(.ottoMicro).tracking(1.4)
    }
    .foregroundStyle(palette.muted)
    .padding(.horizontal, 16)
    .frame(height: 28)
  }
}

/// Pending agent suggestions with Accept and Reject, newest last.
struct DocSuggestionsList: View {
  @ObservedObject var office: OfficeStore
  let path: String
  @Environment(\.ottoPalette) private var palette
  @State private var error: String?

  var body: some View {
    let suggestions = office.suggestions(path: path)
    if !suggestions.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text("SUGGESTIONS · \(suggestions.count)").font(.ottoMicro).tracking(1.6)
            .foregroundStyle(palette.muted)
          Spacer()
          if suggestions.count > 1 {
            Button("Accept all") {
              for suggestion in suggestions { act { try office.accept(suggestion.id) } }
            }
            .buttonStyle(.plain)
            .font(.ottoDisplay(11).weight(.medium))
            .foregroundStyle(palette.signal)
          }
        }
        ScrollView {
          VStack(spacing: 8) {
            ForEach(suggestions) { suggestion in card(suggestion) }
          }
        }
        .frame(maxHeight: 300)
        if let error {
          Text(error).font(.ottoDisplay(11)).foregroundStyle(palette.red)
        }
      }
      .padding(14)
    }
  }

  private func card(_ suggestion: DocSuggestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(palette.signal)
        Text(suggestion.author).font(.ottoDisplay(11.5).weight(.semibold))
        Spacer()
        Text(label(suggestion)).font(.ottoMicro).tracking(1.2).foregroundStyle(palette.muted)
      }
      if let note = suggestion.note, !note.isEmpty {
        Text(note).font(.ottoDisplay(12)).foregroundStyle(palette.paper.opacity(0.85))
      }
      if let target = suggestion.target {
        Text(target).strikethrough().font(.ottoDisplay(12))
          .foregroundStyle(palette.red.opacity(0.9)).lineLimit(4)
      }
      Text(suggestion.proposed.isEmpty ? "(delete)" : suggestion.proposed)
        .font(.ottoDisplay(12)).foregroundStyle(palette.cyan).lineLimit(8)
      HStack(spacing: 8) {
        Button {
          act { try office.accept(suggestion.id) }
        } label: {
          Text("Accept").font(.ottoDisplay(11.5).weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 3)
        }
        .buttonStyle(.ottoPrimary(cornerRadius: 6))
        Button("Reject") { act { try office.dismiss(suggestion.id) } }
          .controlSize(.small)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.paper.opacity(0.08)))
  }

  private func label(_ suggestion: DocSuggestion) -> String {
    switch suggestion.change {
    case .replace: "EDIT"
    case .append: "ADD AT END"
    case .replaceAll: "REWRITE ALL"
    }
  }

  private func act(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

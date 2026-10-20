import AppKit
import OttoModels
import SwiftUI

/// Everything about a spreadsheet the grid and the formula bar share: the cells, the
/// selection, the cell being typed into, undo, the clipboard and formula help.
@MainActor
final class SheetModel: ObservableObject {
  @Published private(set) var sheet: Spreadsheet
  private(set) var evaluator: SpreadsheetEvaluator
  @Published private(set) var anchor = CellAddress(column: 0, row: 0)
  @Published private(set) var focus = CellAddress(column: 0, row: 0)
  @Published private(set) var editing = false
  /// What is being typed into the focused cell, shown live in the cell and the formula bar.
  @Published var editText = "" {
    didSet { if editing { editTextChanged() } }
  }
  /// Typing straight onto a cell (Excel's "enter" mode): arrows commit and move. Editing an
  /// existing value (double-click, Return) keeps arrows for the caret.
  private(set) var enterMode = false
  /// Caret position inside `editText`, kept by the in-cell editor.
  var caret: Int = 0
  /// Set when Otto moved the caret itself (a suggestion or reference went in), so the editor
  /// follows; otherwise the editor owns its caret and selection.
  var caretNeedsSync = false
  /// Typing in the formula bar rather than the cell: the cell shows the text but the bar keeps
  /// the keyboard.
  var editingInBar = false
  @Published private(set) var suggestions: [SpreadsheetFunction] = []
  @Published var suggestionIndex = 0
  @Published private(set) var hint: SpreadsheetFunction?
  @Published private(set) var copyMarquee: (CellAddress, CellAddress)?
  var touched: Set<String> = []
  /// The open tab's name and the other tabs, so formulas like `Sales!B2` can read them.
  private(set) var tabName = ""
  private(set) var otherTabs: [String: Spreadsheet] = [:]
  /// A reference being placed with the arrow keys or the mouse while writing a formula.
  var pointing: (range: NSRange, start: CellAddress, end: CellAddress)?

  var save: (Spreadsheet) -> Void = { _ in }
  var redraw: () -> Void = {}
  var onAsk: (String) -> Void = { _ in }

  private var undoStack: [Spreadsheet] = []
  private var redoStack: [Spreadsheet] = []
  private var clipboard: (origin: CellAddress, raws: [[String]], text: String)?

  static let rowHeight: CGFloat = 26
  static let maximumRowHeight: CGFloat = 640
  /// The cell font, shared by drawing and by fitting rows to their text.
  static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
  static let defaultWidth: CGFloat = 112
  static let minimumWidth: CGFloat = 36

  init(sheet: Spreadsheet) {
    self.sheet = sheet
    evaluator = SpreadsheetEvaluator(sheet)
  }

  private func makeEvaluator(_ sheet: Spreadsheet) -> SpreadsheetEvaluator {
    SpreadsheetEvaluator(sheet, named: tabName, in: otherTabs)
  }

  /// Shows another tab. Undo history belongs to one tab, so it starts fresh.
  func show(
    _ next: Spreadsheet, tab name: String, others: [String: Spreadsheet], switching: Bool
  ) {
    tabName = name
    otherTabs = others
    if switching {
      if editing { cancelEditing() }
      undoStack.removeAll()
      redoStack.removeAll()
      copyMarquee = nil
      anchor = CellAddress(column: 0, row: 0)
      focus = anchor
    }
    sheet = next
    evaluator = makeEvaluator(next)
    redraw()
  }

  /// A reference typed into a formula that points at this tab, so it can be outlined.
  func isOnThisTab(_ reference: SpreadsheetFormula.Reference) -> Bool {
    reference.sheet.map { $0.caseInsensitiveCompare(tabName) == .orderedSame } ?? true
  }

  var columnCount: Int { min(702, max(sheet.usedSize.columns + 6, 26)) }
  var rowCount: Int { min(100_000, max(sheet.usedSize.rows + 80, 200)) }

  func width(_ column: Int) -> CGFloat {
    sheet.columnWidths[column].map { CGFloat($0) } ?? Self.defaultWidth
  }

  func x(of column: Int) -> CGFloat {
    (0..<column).reduce(0) { $0 + width($1) }
  }

  func height(_ row: Int) -> CGFloat {
    sheet.rowHeights[row].map { CGFloat($0) } ?? Self.rowHeight
  }

  /// A row taller than the default wraps its text, so long text can be read in place.
  func wraps(_ row: Int) -> Bool { height(row) > Self.rowHeight }

  /// Rows taller than the default, in order; every other row has the default height.
  private var tallRows: [(row: Int, height: CGFloat)] {
    if sheet.rowHeights != tallRowsSource {
      tallRowsSource = sheet.rowHeights
      tallRowsCache = sheet.rowHeights.map { ($0.key, CGFloat($0.value)) }.sorted {
        $0.row < $1.row
      }
    }
    return tallRowsCache
  }
  private var tallRowsSource: [Int: Double] = [:]
  private var tallRowsCache: [(row: Int, height: CGFloat)] = []

  func y(of row: Int) -> CGFloat {
    tallRows.reduce(CGFloat(row) * Self.rowHeight) { total, tall in
      tall.row < row ? total + tall.height - Self.rowHeight : total
    }
  }

  func row(at y: CGFloat) -> Int {
    var top: CGFloat = 0
    var row = 0
    for tall in tallRows {
      // Default-height rows before this tall one.
      let gap = CGFloat(tall.row - row) * Self.rowHeight
      if y < top + gap { return min(rowCount - 1, row + max(0, Int((y - top) / Self.rowHeight))) }
      top += gap
      if y < top + tall.height { return min(rowCount - 1, tall.row) }
      top += tall.height
      row = tall.row + 1
    }
    return min(rowCount - 1, row + max(0, Int((y - top) / Self.rowHeight)))
  }

  var totalHeight: CGFloat { y(of: rowCount) }

  func column(at x: CGFloat) -> Int {
    var edge: CGFloat = 0
    for column in 0..<columnCount {
      edge += width(column)
      if x < edge { return column }
    }
    return columnCount - 1
  }

  var selection: (start: CellAddress, end: CellAddress) {
    (
      CellAddress(column: min(anchor.column, focus.column), row: min(anchor.row, focus.row)),
      CellAddress(column: max(anchor.column, focus.column), row: max(anchor.row, focus.row))
    )
  }

  var selectionLabel: String {
    let (start, end) = selection
    return start == end ? start.a1 : "\(start.a1):\(end.a1)"
  }

  func raw(_ address: CellAddress) -> String { sheet.raw(address.a1) }

  func value(_ address: CellAddress) -> CellValue {
    sheet.raw(address.a1).isEmpty ? .empty : evaluator.value(at: address.a1)
  }

  /// Replaces the sheet from disk (an agent changed it), keeping the selection.
  func reload(_ next: Spreadsheet) {
    guard next != sheet else { return }
    sheet = next
    evaluator = makeEvaluator(next)
    redraw()
  }

  // MARK: Selection

  func select(_ address: CellAddress, extend: Bool = false) {
    focus = clamp(address)
    if !extend { anchor = focus }
    redraw()
  }

  func select(from start: CellAddress, to end: CellAddress) {
    anchor = clamp(start)
    focus = clamp(end)
    redraw()
  }

  func selectAll() {
    select(
      from: CellAddress(column: 0, row: 0),
      to: CellAddress(
        column: max(0, sheet.usedSize.columns - 1), row: max(0, sheet.usedSize.rows - 1)))
  }

  func move(_ dx: Int, _ dy: Int, extend: Bool, jump: Bool) {
    var target = focus
    if jump {
      target = edge(from: focus, dx: dx, dy: dy)
    } else {
      target = CellAddress(column: focus.column + dx, row: focus.row + dy)
    }
    select(target, extend: extend)
  }

  /// Cmd-arrow: to the edge of the current block of data, like Excel.
  private func edge(from start: CellAddress, dx: Int, dy: Int) -> CellAddress {
    func filled(_ a: CellAddress) -> Bool { !raw(a).isEmpty }
    func step(_ a: CellAddress) -> CellAddress? {
      let next = CellAddress(column: a.column + dx, row: a.row + dy)
      guard next.column >= 0, next.row >= 0, next.column < columnCount, next.row < rowCount
      else { return nil }
      return next
    }
    guard var current = step(start) else { return start }
    if filled(start) && filled(current) {
      while let next = step(current), filled(next) { current = next }
      return current
    }
    while !filled(current), let next = step(current) { current = next }
    return current
  }

  private func clamp(_ a: CellAddress) -> CellAddress {
    CellAddress(
      column: min(max(0, a.column), columnCount - 1), row: min(max(0, a.row), rowCount - 1))
  }

  // MARK: Editing

  func beginEditing(with text: String? = nil) {
    editing = true
    enterMode = text != nil
    pointing = nil
    editText = text ?? raw(focus)
    caret = editText.utf16.count
    caretNeedsSync = true
    editTextChanged()
    redraw()
  }

  /// Typing in the formula bar: the cell shows the same text as it changes.
  func beginEditingInBar() {
    editing = true
    editingInBar = true
    enterMode = false
    pointing = nil
    editText = raw(focus)
    caret = editText.utf16.count
  }

  /// Saves what was typed and moves like Excel/Sheets (Return down, Tab right).
  func commit(move: (Int, Int)? = nil) {
    guard editing else {
      if let move { self.move(move.0, move.1, extend: false, jump: false) }
      return
    }
    editing = false
    editingInBar = false
    suggestions = []
    hint = nil
    pointing = nil
    var text = editText
    // Close brackets people leave open, as spreadsheets do.
    if text.hasPrefix("=") {
      let open = text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
      if open > 0 { text += String(repeating: ")", count: open) }
    }
    if text != raw(focus) { apply([focus.a1: text]) }
    if let move {
      let target = CellAddress(column: focus.column + move.0, row: focus.row + move.1)
      select(target)
    } else {
      redraw()
    }
  }

  func cancelEditing() {
    editing = false
    editingInBar = false
    suggestions = []
    hint = nil
    pointing = nil
    redraw()
  }

  private func editTextChanged() {
    let text = editText
    guard text.hasPrefix("=") else {
      suggestions = []
      hint = nil
      return
    }
    let caretIndex = index(caret, in: text)
    // The word being typed right before the caret, if it looks like a function name.
    let before = text[..<caretIndex]
    let word = before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "." }
    let token = String(word.reversed())
    if let first = token.first, first.isLetter, !token.isEmpty,
      CellAddress(token) == nil || token.count <= 1
    {
      suggestions = Array(SpreadsheetFunctions.matching(prefix: token).prefix(7))
    } else {
      suggestions = []
    }
    suggestionIndex = 0
    hint = SpreadsheetFormula.enclosingFunction(text, caret: caretIndex).flatMap { name in
      SpreadsheetFunctions.all.first { $0.name == name }
    }
    redraw()
  }

  private func index(_ utf16Offset: Int, in text: String) -> String.Index {
    String.Index(utf16Offset: min(max(0, utf16Offset), text.utf16.count), in: text)
  }

  /// Puts the chosen function in, e.g. "=SU" → "=SUM(".
  func acceptSuggestion(_ chosen: SpreadsheetFunction? = nil) {
    guard let function = chosen ?? suggestions[safe: suggestionIndex] else { return }
    let text = editText
    let caretIndex = index(caret, in: text)
    var start = caretIndex
    while start > text.startIndex {
      let previous = text.index(before: start)
      guard text[previous].isLetter || text[previous].isNumber || text[previous] == "." else {
        break
      }
      start = previous
    }
    let next = text.replacingCharacters(in: start..<caretIndex, with: function.name + "(")
    caret = text[..<start].utf16.count + function.name.utf16.count + 1
    caretNeedsSync = true
    editText = next
    suggestions = []
  }

  /// While writing a formula, clicking or arrowing to a cell types its reference.
  var acceptsReference: Bool {
    guard editing, editText.hasPrefix("=") else { return false }
    if pointing != nil { return true }
    return SpreadsheetFormula.acceptsReference(editText, caret: index(caret, in: editText))
  }

  func point(to start: CellAddress, _ end: CellAddress? = nil) {
    let end = end ?? start
    let lo = CellAddress(column: min(start.column, end.column), row: min(start.row, end.row))
    let hi = CellAddress(column: max(start.column, end.column), row: max(start.row, end.row))
    let reference = lo == hi ? lo.a1 : "\(lo.a1):\(hi.a1)"
    var text = editText as NSString
    let range = pointing?.range ?? NSRange(location: min(caret, text.length), length: 0)
    text = text.replacingCharacters(in: range, with: reference) as NSString
    pointing = (NSRange(location: range.location, length: reference.utf16.count), start, end)
    caret = range.location + reference.utf16.count
    caretNeedsSync = true
    editText = text as String
    redraw()
  }

  /// Arrow keys move the reference being placed.
  func movePointer(_ dx: Int, _ dy: Int, extend: Bool) {
    let base = pointing?.end ?? focus
    let moved = clamp(CellAddress(column: base.column + dx, row: base.row + dy))
    point(to: extend ? (pointing?.start ?? focus) : moved, moved)
  }

  /// Colour-coded references in the formula being typed.
  var references: [SpreadsheetFormula.Reference] {
    guard editing, editText.hasPrefix("=") else { return [] }
    return SpreadsheetFormula.references(in: editText)
  }

  // MARK: Changes

  func apply(_ changes: [String: String]) {
    guard !changes.isEmpty else { return }
    undoStack.append(sheet)
    if undoStack.count > 200 { undoStack.removeFirst() }
    redoStack.removeAll()
    var next = sheet
    for (key, value) in changes { next.set(key, value) }
    commitSheet(next)
  }

  private func commitSheet(_ next: Spreadsheet) {
    sheet = next
    evaluator = makeEvaluator(next)
    save(next)
    redraw()
  }

  func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(sheet)
    commitSheet(previous)
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(sheet)
    commitSheet(next)
  }

  var canUndo: Bool { !undoStack.isEmpty }

  private var selectedAddresses: [CellAddress] {
    let (start, end) = selection
    return (start.row...end.row).flatMap { row in
      (start.column...end.column).map { CellAddress(column: $0, row: row) }
    }
  }

  func clearSelection() {
    apply(Dictionary(uniqueKeysWithValues: selectedAddresses.map { ($0.a1, "") }))
  }

  func setWidth(_ column: Int, _ width: CGFloat) {
    var next = sheet
    next.columnWidths[column] = Double(max(Self.minimumWidth, width.rounded()))
    sheet = next
    redraw()
  }

  func finishResize() { save(sheet) }

  /// Drag-resizing a row. Back to the default height, the row stops wrapping.
  func setHeight(_ row: Int, _ height: CGFloat) {
    var next = sheet
    let clamped = min(Self.maximumRowHeight, max(Self.rowHeight, height.rounded()))
    next.rowHeights[row] = clamped <= Self.rowHeight ? nil : Double(clamped)
    sheet = next
    redraw()
  }

  /// Makes each row just tall enough to show all of its text wrapped, as Excel's AutoFit does.
  /// Rows whose text fits on one line go back to the default height. Undoable.
  func fitRows(_ rows: ClosedRange<Int>) {
    var next = sheet
    for row in rows {
      var needed = Self.rowHeight
      for column in 0..<columnCount {
        let address = CellAddress(column: column, row: row)
        let raw = sheet.raw(address.a1)
        guard !raw.isEmpty else { continue }
        let text = value(address).display as NSString
        let bounds = text.boundingRect(
          with: NSSize(width: max(1, width(column) - 12), height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin], attributes: [.font: Self.cellFont])
        needed = max(needed, ceil(bounds.height) + 12)
      }
      let fitted = min(Self.maximumRowHeight, needed)
      // One line of text fits the default row; only longer text makes it taller.
      let oneLine = ceil(Self.cellFont.boundingRectForFont.height) + 12
      next.rowHeights[row] = fitted <= max(Self.rowHeight, oneLine) ? nil : Double(fitted)
    }
    guard next != sheet else { return }
    undoStack.append(sheet)
    redoStack.removeAll()
    commitSheet(next)
  }

  /// Puts rows back to the default height. Undoable.
  func resetRows(_ rows: ClosedRange<Int>) {
    var next = sheet
    for row in rows { next.rowHeights[row] = nil }
    guard next != sheet else { return }
    undoStack.append(sheet)
    redoStack.removeAll()
    commitSheet(next)
  }

  var selectedRows: ClosedRange<Int> { selection.start.row...selection.end.row }

  // MARK: Clipboard

  func copy(cut: Bool = false) {
    let (start, end) = selection
    var raws: [[String]] = []
    var lines: [String] = []
    for row in start.row...end.row {
      var rawRow: [String] = []
      var shown: [String] = []
      for column in start.column...end.column {
        let address = CellAddress(column: column, row: row)
        rawRow.append(raw(address))
        shown.append(value(address).display)
      }
      raws.append(rawRow)
      lines.append(shown.joined(separator: "\t"))
    }
    let text = lines.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    clipboard = (start, raws, text)
    copyMarquee = (start, end)
    if cut { clearSelection() }
    redraw()
  }

  /// Pastes at the selection. Copies made here keep their formulas, shifted Excel-style;
  /// anything else (Excel, Sheets, a web table) pastes as tab-separated values.
  func paste() {
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
    let target = selection.start
    var changes: [String: String] = [:]
    if let clipboard, clipboard.text == text {
      let dy = target.row - clipboard.origin.row
      let dx = target.column - clipboard.origin.column
      for (r, row) in clipboard.raws.enumerated() {
        for (c, raw) in row.enumerated() {
          changes[CellAddress(column: target.column + c, row: target.row + r).a1] =
            SpreadsheetFormula.shifted(raw, rows: dy, columns: dx)
        }
      }
      select(
        from: target,
        to: CellAddress(
          column: target.column + (clipboard.raws.first?.count ?? 1) - 1,
          row: target.row + clipboard.raws.count - 1))
    } else {
      let rows = text.replacingOccurrences(of: "\r\n", with: "\n").split(
        separator: "\n", omittingEmptySubsequences: false)
      let trimmed = rows.last?.isEmpty == true ? rows.dropLast() : rows[...]
      for (r, line) in trimmed.enumerated() {
        for (c, value) in line.split(separator: "\t", omittingEmptySubsequences: false).enumerated()
        {
          changes[CellAddress(column: target.column + c, row: target.row + r).a1] = String(value)
        }
      }
    }
    copyMarquee = nil
    apply(changes)
  }

  // MARK: Fill

  /// Cmd-D: copy the top row of the selection down it (or the cell above, for one cell).
  func fillDown() {
    let (start, end) = selection
    let sourceRow = start.row == end.row ? start.row - 1 : start.row
    guard sourceRow >= 0 else { return }
    var changes: [String: String] = [:]
    for column in start.column...end.column {
      let source = raw(CellAddress(column: column, row: sourceRow))
      for row in max(sourceRow + 1, start.row)...end.row {
        changes[CellAddress(column: column, row: row).a1] =
          SpreadsheetFormula.shifted(source, rows: row - sourceRow, columns: 0)
      }
    }
    apply(changes)
  }

  /// Cmd-R: copy the left column of the selection across it.
  func fillRight() {
    let (start, end) = selection
    let sourceColumn = start.column == end.column ? start.column - 1 : start.column
    guard sourceColumn >= 0 else { return }
    var changes: [String: String] = [:]
    for row in start.row...end.row {
      let source = raw(CellAddress(column: sourceColumn, row: row))
      for column in max(sourceColumn + 1, start.column)...end.column {
        changes[CellAddress(column: column, row: row).a1] =
          SpreadsheetFormula.shifted(source, rows: 0, columns: column - sourceColumn)
      }
    }
    apply(changes)
  }

  /// Dragging the fill handle: continues number series (1, 2 → 3, 4) and copies formulas with
  /// their references moved along.
  func fill(to target: CellAddress) {
    let (start, end) = selection
    let down = target.row > end.row
    let right = !down && target.column > end.column
    guard down || right else { return }
    var changes: [String: String] = [:]
    if down {
      for column in start.column...end.column {
        let source = (start.row...end.row).map { raw(CellAddress(column: column, row: $0)) }
        let numbers = source.compactMap { Double($0) }
        let series = numbers.count == source.count && numbers.count >= 2
        let step = series ? numbers[numbers.count - 1] - numbers[numbers.count - 2] : 0
        for row in (end.row + 1)...target.row {
          let offset = row - start.row
          let key = CellAddress(column: column, row: row).a1
          if series, let last = numbers.last {
            let value = last + step * Double(row - end.row)
            changes[key] = value.rounded() == value ? String(Int(value)) : String(value)
          } else {
            let from = source[offset % source.count]
            changes[key] = SpreadsheetFormula.shifted(
              from, rows: row - (start.row + offset % source.count), columns: 0)
          }
        }
      }
      select(from: start, to: CellAddress(column: end.column, row: target.row))
    } else {
      for row in start.row...end.row {
        let source = (start.column...end.column).map { raw(CellAddress(column: $0, row: row)) }
        let numbers = source.compactMap { Double($0) }
        let series = numbers.count == source.count && numbers.count >= 2
        let step = series ? numbers[numbers.count - 1] - numbers[numbers.count - 2] : 0
        for column in (end.column + 1)...target.column {
          let offset = column - start.column
          let key = CellAddress(column: column, row: row).a1
          if series, let last = numbers.last {
            let value = last + step * Double(column - end.column)
            changes[key] = value.rounded() == value ? String(Int(value)) : String(value)
          } else {
            let from = source[offset % source.count]
            changes[key] = SpreadsheetFormula.shifted(
              from, rows: 0, columns: column - (start.column + offset % source.count))
          }
        }
      }
      select(from: start, to: CellAddress(column: target.column, row: end.row))
    }
    apply(changes)
  }

  /// Sum, average and count of the numbers selected, for the status bar.
  var selectionStats: (sum: Double, count: Int)? {
    let numbers = selectedAddresses.compactMap { address -> Double? in
      if case .number(let value) = value(address) { return value }
      return nil
    }
    guard numbers.count > 1 else { return nil }
    return (numbers.reduce(0, +), numbers.count)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// Colours the grid draws with, from the Otto palette.
struct SheetColors {
  var background: NSColor
  var header: NSColor
  var text: NSColor
  var muted: NSColor
  var grid: NSColor
  var accent: NSColor
  var error: NSColor

  static let referencePalette: [NSColor] = [
    NSColor(srgbRed: 0.27, green: 0.55, blue: 1, alpha: 1),
    NSColor(srgbRed: 0.93, green: 0.36, blue: 0.36, alpha: 1),
    NSColor(srgbRed: 0.6, green: 0.4, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.2, green: 0.75, blue: 0.5, alpha: 1),
    NSColor(srgbRed: 0.95, green: 0.6, blue: 0.2, alpha: 1),
  ]
}

/// The cells: one view that draws only what is on screen, so clicking and scrolling stay
/// instant however big the sheet gets.
final class SheetCellsView: NSView, NSTextFieldDelegate {
  let model: SheetModel
  var colors: SheetColors
  private let editor = CellEditorField()
  private var dragOrigin: CellAddress?
  private var filling = false
  private var fillTarget: CellAddress?
  var menuBuilder: (() -> NSMenu)?

  init(model: SheetModel, colors: SheetColors) {
    self.model = model
    self.colors = colors
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    editor.delegate = self
    editor.isHidden = true
    editor.cellView = self
    addSubview(editor)
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }
  /// While a cell is being typed into, clicking the grid (to pick a reference for a formula)
  /// must not take the keyboard away from that cell.
  override var acceptsFirstResponder: Bool { !model.editing }
  override var isOpaque: Bool { true }

  func contentSize() -> NSSize {
    NSSize(width: model.x(of: model.columnCount), height: model.totalHeight)
  }

  func rect(for address: CellAddress) -> NSRect {
    NSRect(
      x: model.x(of: address.column), y: model.y(of: address.row),
      width: model.width(address.column), height: model.height(address.row))
  }

  func address(at point: NSPoint) -> CellAddress {
    CellAddress(
      column: model.column(at: point.x),
      row: model.row(at: max(0, point.y)))
  }

  private func rangeRect(_ start: CellAddress, _ end: CellAddress) -> NSRect {
    let lo = CellAddress(column: min(start.column, end.column), row: min(start.row, end.row))
    let hi = CellAddress(column: max(start.column, end.column), row: max(start.row, end.row))
    return rect(for: lo).union(rect(for: hi))
  }

  // MARK: Drawing

  private lazy var textAttributes: [NSAttributedString.Key: Any] = {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    return [.font: SheetModel.cellFont, .paragraphStyle: style]
  }()

  override func draw(_ dirtyRect: NSRect) {
    colors.background.setFill()
    dirtyRect.fill()
    let firstRow = model.row(at: max(0, dirtyRect.minY))
    let lastRow = model.row(at: dirtyRect.maxY)
    let firstColumn = model.column(at: dirtyRect.minX)
    let lastColumn = model.column(at: dirtyRect.maxX)
    let (selStart, selEnd) = model.selection

    // Selection wash and agent highlights.
    let selectionRect = rangeRect(selStart, selEnd)
    colors.accent.withAlphaComponent(0.10).setFill()
    selectionRect.fill()
    if !model.touched.isEmpty {
      colors.accent.withAlphaComponent(0.2).setFill()
      for key in model.touched {
        guard let address = CellAddress(key) else { continue }
        let cell = rect(for: address)
        if cell.intersects(dirtyRect) { cell.fill() }
      }
    }

    // Grid lines.
    colors.grid.setFill()
    for row in firstRow...lastRow {
      NSRect(
        x: dirtyRect.minX, y: model.y(of: row + 1) - 1, width: dirtyRect.width, height: 1
      ).fill()
    }
    for column in firstColumn...lastColumn {
      let x = model.x(of: column + 1) - 1
      NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    // Values. Text from a few columns to the left can spill into view, so start there.
    let overflowStart = max(0, firstColumn - 8)
    for row in firstRow...lastRow {
      let wraps = model.wraps(row)
      for column in overflowStart...lastColumn {
        let address = CellAddress(column: column, row: row)
        if model.editing && address == model.focus { continue }
        let raw = model.raw(address)
        guard !raw.isEmpty else { continue }
        let value = model.value(address)
        var attributes = textAttributes
        let isNumber: Bool
        switch value {
        case .number, .bool:
          isNumber = true
          attributes[.foregroundColor] = colors.text
        case .error:
          isNumber = false
          attributes[.foregroundColor] = colors.error
        default:
          isNumber = false
          attributes[.foregroundColor] = colors.text
        }
        if isNumber,
          let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle
        {
          style.alignment = .right
          attributes[.paragraphStyle] = style
        }
        var cell = rect(for: address).insetBy(dx: 6, dy: 0)
        let text = value.display as NSString
        if wraps {
          // A tall row wraps its text from the top, like Excel's Wrap Text.
          if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle
          {
            style.lineBreakMode = .byWordWrapping
            attributes[.paragraphStyle] = style
          }
          text.draw(
            with: cell.insetBy(dx: 0, dy: 6),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
          continue
        }
        // Text runs on into empty cells to its right instead of being cut off, as in Excel.
        let fullWidth = text.size(withAttributes: attributes).width
        if !isNumber, fullWidth > cell.width {
          var next = column + 1
          while next < model.columnCount, cell.width < fullWidth,
            model.raw(CellAddress(column: next, row: row)).isEmpty,
            !(model.editing && model.focus == CellAddress(column: next, row: row))
          {
            cell.size.width += model.width(next)
            next += 1
          }
        }
        guard cell.maxX >= dirtyRect.minX else { continue }
        // Clear the grid lines the text runs over, keeping the row's bottom line.
        let own = rect(for: address)
        if cell.maxX > own.maxX + 6 {
          colors.background.setFill()
          NSRect(
            x: own.maxX - 1, y: own.minY, width: cell.maxX + 6 - own.maxX, height: own.height - 1
          ).fill()
        }
        let height = text.size(withAttributes: attributes).height
        text.draw(
          with: NSRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height),
          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
      }
    }

    // References in the formula being typed, colour-coded like Excel.
    for (index, reference) in model.references.enumerated() where model.isOnThisTab(reference) {
      let color = SheetColors.referencePalette[index % SheetColors.referencePalette.count]
      let box = rangeRect(reference.start, reference.end).insetBy(dx: 0.5, dy: 0.5)
      color.withAlphaComponent(0.12).setFill()
      box.fill()
      color.setStroke()
      let path = NSBezierPath(rect: box)
      path.lineWidth = 1.5
      path.setLineDash([4, 2], count: 2, phase: 0)
      path.stroke()
    }

    // Copy marquee.
    if let (start, end) = model.copyMarquee {
      colors.accent.setStroke()
      let path = NSBezierPath(rect: rangeRect(start, end).insetBy(dx: 1, dy: 1))
      path.lineWidth = 1.5
      path.setLineDash([5, 3], count: 2, phase: 0)
      path.stroke()
    }

    // Selection outline, focus cell and fill handle.
    colors.accent.setStroke()
    if !(model.editing && selStart == selEnd) {
      let outline = NSBezierPath(rect: selectionRect.insetBy(dx: 1, dy: 1))
      outline.lineWidth = 2
      outline.stroke()
    }
    if let fillTarget, filling {
      let preview = NSBezierPath(rect: rangeRect(selStart, fillTarget).insetBy(dx: 1, dy: 1))
      preview.lineWidth = 1.5
      preview.setLineDash([4, 3], count: 2, phase: 0)
      preview.stroke()
    }
    if !model.editing {
      let handle = fillHandleRect
      colors.background.setFill()
      handle.insetBy(dx: -1.5, dy: -1.5).fill()
      colors.accent.setFill()
      handle.fill()
    }
  }

  private var fillHandleRect: NSRect {
    let (start, end) = model.selection
    let box = rangeRect(start, end)
    return NSRect(x: box.maxX - 4, y: box.maxY - 4, width: 7, height: 7)
  }

  // MARK: Editing in the cell

  func refresh() {
    let size = contentSize()
    if frame.size != size { setFrameSize(size) }
    layoutEditor()
    needsDisplay = true
  }

  private func layoutEditor() {
    guard model.editing else {
      if !editor.isHidden {
        editor.isHidden = true
        if window?.firstResponder === editor.currentEditor() { window?.makeFirstResponder(self) }
      }
      return
    }
    let cell = rect(for: model.focus)
    let textWidth =
      (model.editText as NSString).size(withAttributes: [.font: editor.font as Any]).width + 24
    editor.frame = NSRect(
      x: cell.minX, y: cell.minY, width: max(cell.width, min(textWidth, 640)),
      height: cell.height)
    if editor.stringValue != model.editText { editor.stringValue = model.editText }
    if editor.isHidden {
      editor.isHidden = false
      if !model.editingInBar { window?.makeFirstResponder(editor) }
    }
    if model.caretNeedsSync, let text = editor.currentEditor() {
      model.caretNeedsSync = false
      let caret = min(model.caret, (text.string as NSString).length)
      text.selectedRange = NSRange(location: caret, length: 0)
    }
    editor.textColor = colors.text
    editor.backgroundColor = colors.background
  }

  /// Where the in-cell editor sits, so the suggestion list can appear under it.
  var editorFrame: NSRect { editor.frame }

  func controlTextDidChange(_ notification: Notification) {
    if let text = editor.currentEditor() {
      model.caret = text.selectedRange.location
    }
    model.pointing = nil
    model.editText = editor.stringValue
    layoutEditor()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    model.caret = textView.selectedRange.location
    let shift = NSEvent.modifierFlags.contains(.shift)
    switch selector {
    case #selector(NSResponder.insertNewline(_:)):
      if !model.suggestions.isEmpty {
        model.acceptSuggestion()
        return true
      }
      model.commit(move: (0, shift ? -1 : 1))
      return true
    case #selector(NSResponder.insertTab(_:)):
      if !model.suggestions.isEmpty {
        model.acceptSuggestion()
        return true
      }
      model.commit(move: (1, 0))
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      model.commit(move: (-1, 0))
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      if !model.suggestions.isEmpty {
        model.editText = model.editText  // keeps text, hides the list on next change
      }
      model.cancelEditing()
      return true
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
      #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveRight(_:)),
      #selector(NSResponder.moveUpAndModifySelection(_:)),
      #selector(NSResponder.moveDownAndModifySelection(_:)),
      #selector(NSResponder.moveLeftAndModifySelection(_:)),
      #selector(NSResponder.moveRightAndModifySelection(_:)):
      let (dx, dy) = Self.direction(selector)
      if !model.suggestions.isEmpty, dx == 0 {
        model.suggestionIndex = max(
          0, min(model.suggestions.count - 1, model.suggestionIndex + dy))
        return true
      }
      if model.acceptsReference {
        model.movePointer(dx, dy, extend: shift)
        return true
      }
      if model.enterMode {
        model.commit(move: (dx, dy))
        return true
      }
      return false
    default:
      return false
    }
  }

  private static func direction(_ selector: Selector) -> (Int, Int) {
    switch selector {
    case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
      (0, -1)
    case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
      (0, 1)
    case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveLeftAndModifySelection(_:)):
      (-1, 0)
    default: (1, 0)
    }
  }

  /// Clicking the grid while the editor is open: build a reference, or finish the edit.
  func editorLostClick(at address: CellAddress, extending: Bool) -> Bool {
    if model.acceptsReference {
      model.point(to: extending ? (model.pointing?.start ?? address) : address, address)
      return true
    }
    model.commit()
    return false
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let address = address(at: point)
    if model.editing {
      if editorLostClick(at: address, extending: event.modifierFlags.contains(.shift)) {
        dragOrigin = nil
        if !model.editingInBar, window?.firstResponder !== editor.currentEditor() {
          window?.makeFirstResponder(editor)
          model.caretNeedsSync = true
          layoutEditor()
        }
        return
      }
    }
    window?.makeFirstResponder(self)
    if !model.editing, fillHandleRect.insetBy(dx: -4, dy: -4).contains(point) {
      filling = true
      fillTarget = model.selection.end
      return
    }
    if event.clickCount == 2 {
      model.select(address)
      model.beginEditing()
      refresh()
      return
    }
    model.select(address, extend: event.modifierFlags.contains(.shift))
    dragOrigin = event.modifierFlags.contains(.shift) ? model.selection.start : address
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    autoscroll(with: event)
    let address = address(at: point)
    if filling {
      let (_, end) = model.selection
      // Fill goes down or right, whichever the drag favours.
      let down = address.row - end.row >= address.column - end.column
      fillTarget =
        down
        ? CellAddress(column: end.column, row: max(end.row, address.row))
        : CellAddress(column: max(end.column, address.column), row: end.row)
      needsDisplay = true
      return
    }
    if model.editing, model.pointing != nil {
      model.point(to: model.pointing!.start, address)
      return
    }
    if let dragOrigin { model.select(from: dragOrigin, to: address) }
  }

  override func mouseUp(with event: NSEvent) {
    if filling, let fillTarget {
      model.fill(to: fillTarget)
    }
    filling = false
    fillTarget = nil
    dragOrigin = nil
    needsDisplay = true
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let address = address(at: point)
    let (start, end) = model.selection
    let inside =
      (start.column...end.column).contains(address.column)
      && (start.row...end.row).contains(address.row)
    if !inside { model.select(address) }
    return menuBuilder?()
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    // Mid-edit, keys belong to the cell being typed into: hand them back to it so "=A1" then
    // "+" carries on the formula instead of starting a new value.
    if model.editing {
      resumeEditing(with: event)
      return
    }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let command = flags.contains(.command)
    let shift = flags.contains(.shift)
    switch event.keyCode {
    case 126: model.move(0, -1, extend: shift, jump: command)
    case 125: model.move(0, 1, extend: shift, jump: command)
    case 123: model.move(-1, 0, extend: shift, jump: command)
    case 124: model.move(1, 0, extend: shift, jump: command)
    case 36, 76:  // Return: edit the cell, like Google Sheets.
      if shift {
        model.move(0, -1, extend: false, jump: false)
      } else {
        model.beginEditing()
      }
    case 48: model.move(shift ? -1 : 1, 0, extend: false, jump: false)
    case 51, 117: model.clearSelection()
    case 53: model.select(model.focus)
    case 120: model.beginEditing()  // F2
    default:
      if command {
        super.keyDown(with: event)
        return
      }
      guard let characters = event.characters, let first = characters.unicodeScalars.first,
        !CharacterSet.controlCharacters.contains(first), first.value < 0xF700
      else {
        super.keyDown(with: event)
        return
      }
      // Typing on a cell replaces it, and the letters appear in the cell straight away.
      model.beginEditing(with: characters)
    }
    refresh()
  }

  /// Puts the keyboard back in the cell editor and delivers the key there.
  func resumeEditing(with event: NSEvent) {
    if model.editingInBar { return }
    if editor.isHidden { layoutEditor() }
    window?.makeFirstResponder(editor)
    guard let text = editor.currentEditor() as? NSTextView else { return }
    let caret = min(model.caret, (text.string as NSString).length)
    text.selectedRange = NSRange(location: caret, length: 0)
    text.keyDown(with: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
      let key = event.charactersIgnoringModifiers?.lowercased()
    else { return super.performKeyEquivalent(with: event) }
    let shift = event.modifierFlags.contains(.shift)
    switch key {
    case "c": model.copy()
    case "x": model.copy(cut: true)
    case "v": model.paste()
    case "z": if shift { model.redo() } else { model.undo() }
    case "a": model.selectAll()
    case "d": model.fillDown()
    case "r": model.fillRight()
    default: return super.performKeyEquivalent(with: event)
    }
    refresh()
    return true
  }
}

/// Keeps the typed text vertically centred in the cell, like the values around it.
final class CenteredTextFieldCell: NSTextFieldCell {
  private func centered(_ rect: NSRect) -> NSRect {
    let height = cellSize(forBounds: rect).height
    return NSRect(
      x: rect.minX + 5, y: rect.minY + max(0, (rect.height - height) / 2),
      width: rect.width - 10, height: height)
  }
  override func drawingRect(forBounds rect: NSRect) -> NSRect {
    centered(super.drawingRect(forBounds: rect))
  }
  override func edit(
    withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?
  ) {
    super.edit(
      withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, event: event)
  }
  override func select(
    withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int,
    length: Int
  ) {
    super.select(
      withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, start: start,
      length: length)
  }
}

/// The text field that appears inside a cell while typing.
final class CellEditorField: NSTextField {
  weak var cellView: SheetCellsView?

  override class var cellClass: AnyClass? {
    get { CenteredTextFieldCell.self }
    set {}
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    isBordered = false
    drawsBackground = true
    focusRingType = .none
    font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    cell?.usesSingleLineMode = true
    cell?.wraps = false
    cell?.isScrollable = true
    wantsLayer = true
    layer?.borderWidth = 2
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    layer?.borderColor = NSColor.controlAccentColor.cgColor
  }
}

/// Column letters along the top; drag a border to resize, click to select the column.
final class SheetColumnHeader: NSView {
  let model: SheetModel
  var colors: SheetColors
  var offset: CGFloat = 0 { didSet { needsDisplay = true } }
  private var resizing: (column: Int, startX: CGFloat, startWidth: CGFloat)?
  private var dragStart: Int?

  init(model: SheetModel, colors: SheetColors) {
    self.model = model
    self.colors = colors
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    colors.header.setFill()
    bounds.fill()
    let (start, end) = model.selection
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
      .foregroundColor: colors.muted,
    ]
    var x = -offset
    for column in 0..<model.columnCount {
      let width = model.width(column)
      defer { x += width }
      guard x + width >= 0 else { continue }
      if x > bounds.width { break }
      let cell = NSRect(x: x, y: 0, width: width, height: bounds.height)
      if (start.column...end.column).contains(column) {
        colors.accent.withAlphaComponent(0.16).setFill()
        cell.fill()
      }
      let name = CellAddress.columnName(column) as NSString
      let size = name.size(withAttributes: attributes)
      name.draw(
        at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2),
        withAttributes: attributes)
      colors.grid.setFill()
      NSRect(x: cell.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
    colors.grid.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }

  private func border(near x: CGFloat) -> Int? {
    var edge = -offset
    for column in 0..<model.columnCount {
      edge += model.width(column)
      if abs(edge - x) <= 4 { return column }
      if edge > x + 4 { return nil }
    }
    return nil
  }

  override func resetCursorRects() {
    var edge = -offset
    for column in 0..<model.columnCount {
      edge += model.width(column)
      if edge > bounds.width { break }
      addCursorRect(
        NSRect(x: edge - 3, y: 0, width: 6, height: bounds.height), cursor: .resizeLeftRight)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let x = convert(event.locationInWindow, from: nil).x
    if let column = border(near: x) {
      resizing = (column, x, model.width(column))
      return
    }
    let column = model.column(at: x + offset)
    dragStart = event.modifierFlags.contains(.shift) ? model.selection.start.column : column
    selectColumns(dragStart!, column)
  }

  override func mouseDragged(with event: NSEvent) {
    let x = convert(event.locationInWindow, from: nil).x
    if let resizing {
      model.setWidth(resizing.column, resizing.startWidth + x - resizing.startX)
      return
    }
    if let dragStart { selectColumns(dragStart, model.column(at: x + offset)) }
  }

  override func mouseUp(with event: NSEvent) {
    if resizing != nil { model.finishResize() }
    resizing = nil
    dragStart = nil
    window?.invalidateCursorRects(for: self)
  }

  private func selectColumns(_ a: Int, _ b: Int) {
    if model.editing { model.commit() }
    model.select(
      from: CellAddress(column: a, row: 0), to: CellAddress(column: b, row: model.rowCount - 1))
  }
}

/// Row numbers down the side; click to select the row, drag a row's bottom edge to make it
/// taller (its text then wraps), double-click the edge to fit the row to its text.
final class SheetRowHeader: NSView {
  let model: SheetModel
  var colors: SheetColors
  var offset: CGFloat = 0 { didSet { needsDisplay = true } }
  private var dragStart: Int?
  private var resizing: (row: Int, startY: CGFloat, startHeight: CGFloat)?

  init(model: SheetModel, colors: SheetColors) {
    self.model = model
    self.colors = colors
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    colors.header.setFill()
    bounds.fill()
    let (start, end) = model.selection
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: colors.muted,
    ]
    let first = model.row(at: max(0, offset))
    let last = model.row(at: offset + bounds.height)
    guard first <= last else { return }
    for row in first...last {
      let cell = NSRect(
        x: 0, y: model.y(of: row) - offset, width: bounds.width, height: model.height(row))
      if (start.row...end.row).contains(row) {
        colors.accent.withAlphaComponent(0.16).setFill()
        cell.fill()
      }
      let label = "\(row + 1)" as NSString
      let size = label.size(withAttributes: attributes)
      label.draw(
        at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2),
        withAttributes: attributes)
      colors.grid.setFill()
      NSRect(x: 0, y: cell.maxY - 1, width: bounds.width, height: 1).fill()
    }
    NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
  }

  /// The row whose bottom edge is under `y` (in sheet coordinates), for resizing.
  private func border(near y: CGFloat) -> Int? {
    let row = model.row(at: max(0, y))
    for candidate in [row - 1, row] where candidate >= 0 {
      if abs(model.y(of: candidate + 1) - y) <= 3 { return candidate }
    }
    return nil
  }

  override func resetCursorRects() {
    let first = model.row(at: max(0, offset))
    let last = model.row(at: offset + bounds.height)
    guard first <= last else { return }
    for row in first...last {
      let edge = model.y(of: row + 1) - offset
      addCursorRect(
        NSRect(x: 0, y: edge - 3, width: bounds.width, height: 6), cursor: .resizeUpDown)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y + offset
    if let row = border(near: y) {
      if event.clickCount == 2 {
        // Double-clicking the edge fits the row (or every selected row) to its text.
        let rows = model.selectedRows.contains(row) ? model.selectedRows : row...row
        model.fitRows(rows)
      } else {
        resizing = (row, y, model.height(row))
      }
      return
    }
    let row = model.row(at: max(0, y))
    dragStart = event.modifierFlags.contains(.shift) ? model.selection.start.row : row
    selectRows(dragStart!, row)
  }

  override func mouseDragged(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y + offset
    if let resizing {
      model.setHeight(resizing.row, resizing.startHeight + y - resizing.startY)
      return
    }
    if let dragStart { selectRows(dragStart, model.row(at: max(0, y))) }
  }

  override func mouseUp(with event: NSEvent) {
    if resizing != nil { model.finishResize() }
    resizing = nil
    dragStart = nil
    window?.invalidateCursorRects(for: self)
  }

  private func selectRows(_ a: Int, _ b: Int) {
    if model.editing { model.commit() }
    model.select(
      from: CellAddress(column: 0, row: max(0, a)),
      to: CellAddress(column: model.columnCount - 1, row: max(0, b)))
  }
}

/// Function suggestions under the cell being typed into.
final class SheetSuggestionList: NSView {
  let model: SheetModel
  var colors: SheetColors

  init(model: SheetModel, colors: SheetColors) {
    self.model = model
    self.colors = colors
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    shadow = NSShadow()
    layer?.shadowOpacity = 0.35
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -4)
  }
  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  static let rowHeight: CGFloat = 40

  override func draw(_ dirtyRect: NSRect) {
    layer?.backgroundColor = colors.header.cgColor
    layer?.borderColor = colors.grid.cgColor
    for (index, function) in model.suggestions.enumerated() {
      let row = NSRect(
        x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
      if index == model.suggestionIndex {
        colors.accent.withAlphaComponent(0.18).setFill()
        row.fill()
      }
      (function.signature as NSString).draw(
        at: NSPoint(x: 10, y: row.minY + 5),
        withAttributes: [
          .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
          .foregroundColor: colors.text,
        ])
      (function.summary as NSString).draw(
        with: NSRect(x: 10, y: row.minY + 21, width: bounds.width - 20, height: 16),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: colors.muted])
    }
  }

  override func mouseDown(with event: NSEvent) {
    let y = convert(event.locationInWindow, from: nil).y
    let index = Int(y / Self.rowHeight)
    guard model.suggestions.indices.contains(index) else { return }
    model.acceptSuggestion(model.suggestions[index])
  }
}

/// Headers, the scrolling cells and the suggestion list, laid out together.
final class SheetContainerView: NSView {
  let model: SheetModel
  let cells: SheetCellsView
  let scroll = NSScrollView()
  let columns: SheetColumnHeader
  let rows: SheetRowHeader
  let corner = NSView()
  let suggestions: SheetSuggestionList
  static let headerHeight: CGFloat = 24
  static let rowHeaderWidth: CGFloat = 46

  init(model: SheetModel, colors: SheetColors) {
    self.model = model
    cells = SheetCellsView(model: model, colors: colors)
    columns = SheetColumnHeader(model: model, colors: colors)
    rows = SheetRowHeader(model: model, colors: colors)
    suggestions = SheetSuggestionList(model: model, colors: colors)
    super.init(frame: .zero)
    scroll.documentView = cells
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.contentView.postsBoundsChangedNotifications = true
    corner.wantsLayer = true
    for view in [scroll, columns, rows, corner, suggestions] { addSubview(view) }
    suggestions.isHidden = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
      object: scroll.contentView)
    apply(colors)
    model.redraw = { [weak self] in self?.refresh() }
    cells.refresh()
  }

  required init?(coder: NSCoder) { nil }

  func apply(_ colors: SheetColors) {
    cells.colors = colors
    columns.colors = colors
    rows.colors = colors
    suggestions.colors = colors
    corner.layer?.backgroundColor = colors.header.cgColor
    refresh()
  }

  override func layout() {
    super.layout()
    let h = Self.headerHeight
    let w = Self.rowHeaderWidth
    corner.frame = NSRect(x: 0, y: bounds.height - h, width: w, height: h)
    columns.frame = NSRect(x: w, y: bounds.height - h, width: bounds.width - w, height: h)
    rows.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height - h)
    scroll.frame = NSRect(x: w, y: 0, width: bounds.width - w, height: bounds.height - h)
    scrolled()
  }

  @objc private func scrolled() {
    let origin = scroll.contentView.bounds.origin
    columns.offset = origin.x
    rows.offset = origin.y
    positionSuggestions()
  }

  func refresh() {
    cells.refresh()
    columns.needsDisplay = true
    rows.needsDisplay = true
    positionSuggestions()
    keepFocusVisible()
  }

  private var lastFocus: CellAddress?

  /// Scrolls just enough to keep the focused cell on screen as the selection moves.
  private func keepFocusVisible() {
    guard lastFocus != model.focus else { return }
    lastFocus = model.focus
    cells.scrollToVisible(cells.rect(for: model.focus).insetBy(dx: -2, dy: -2))
  }

  private func positionSuggestions() {
    let list = model.suggestions
    suggestions.isHidden = !model.editing || list.isEmpty
    guard !suggestions.isHidden else { return }
    let editor = cells.convert(cells.editorFrame, to: self)
    let height = CGFloat(list.count) * SheetSuggestionList.rowHeight
    // Below the cell when there is room, otherwise above it (non-flipped container).
    var y = editor.minY - height - 4
    if y < 0 { y = editor.maxY + 4 }
    suggestions.frame = NSRect(x: editor.minX, y: y, width: 460, height: height)
    suggestions.needsDisplay = true
  }

  /// Lets the grid take the keyboard when the sheet opens.
  func focusGrid() { window?.makeFirstResponder(cells) }
}

/// SwiftUI wrapper for the native grid.
struct SheetGrid: NSViewRepresentable {
  let model: SheetModel
  let colors: SheetColors
  var menu: () -> NSMenu

  func makeNSView(context: Context) -> SheetContainerView {
    let view = SheetContainerView(model: model, colors: colors)
    view.cells.menuBuilder = menu
    DispatchQueue.main.async { view.focusGrid() }
    return view
  }

  func updateNSView(_ view: SheetContainerView, context: Context) {
    view.cells.menuBuilder = menu
    view.apply(colors)
  }
}

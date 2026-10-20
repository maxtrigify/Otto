import AppKit
import OttoModels
import Testing

@testable import OttoApp

@MainActor
@Suite("Spreadsheet grid", .serialized)
struct SheetGridTests {
  private func makeGrid(_ sheet: Spreadsheet = Spreadsheet()) -> (
    SheetModel, SheetContainerView, NSWindow
  ) {
    _ = NSApplication.shared
    let model = SheetModel(sheet: sheet)
    let colors = SheetColors(
      background: .black, header: .darkGray, text: .white, muted: .gray, grid: .darkGray,
      accent: .orange, error: .red)
    let view = SheetContainerView(model: model, colors: colors)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = view
    view.frame = window.contentView!.bounds
    view.layoutSubtreeIfNeeded()
    window.makeFirstResponder(view.cells)
    return (model, view, window)
  }

  private func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [])
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
  }

  @Test("Rows grow to read long text: drag, fit to text, click the right row, undo, save")
  func tallRows() throws {
    let long = String(repeating: "A long note that keeps going. ", count: 12)
    var sheet = Spreadsheet()
    sheet.set("A1", "Short")
    sheet.set("A3", long)
    let (model, view, _) = makeGrid(sheet)
    var saved: Spreadsheet?
    model.save = { saved = $0 }
    #expect(!model.wraps(2))
    #expect(model.y(of: 4) == 4 * SheetModel.rowHeight)

    model.fitRows(0...2)
    let fitted = model.height(2)
    #expect(fitted > SheetModel.rowHeight * 3)
    #expect(model.wraps(2))
    // Short text stays on the default height.
    #expect(model.height(0) == SheetModel.rowHeight)
    #expect(saved?.rowHeights[2] == Double(fitted))
    // Rows below move down by the extra height, and clicks land on the right row.
    #expect(model.y(of: 3) == 2 * SheetModel.rowHeight + fitted)
    #expect(model.row(at: 2 * SheetModel.rowHeight + fitted - 1) == 2)
    #expect(model.row(at: 2 * SheetModel.rowHeight + fitted + 1) == 3)
    #expect(view.cells.address(at: NSPoint(x: 10, y: model.y(of: 3) + 5)).row == 3)
    #expect(view.cells.contentSize().height == model.totalHeight)

    model.undo()
    #expect(model.height(2) == SheetModel.rowHeight)
    model.setHeight(1, 80)
    model.finishResize()
    #expect(saved?.rowHeights[1] == 80)
    model.setHeight(1, 10)
    #expect(model.height(1) == SheetModel.rowHeight)
    #expect(model.sheet.rowHeights[1] == nil)
    model.setHeight(1, 10_000)
    #expect(model.height(1) == SheetModel.maximumRowHeight)
    model.select(CellAddress(column: 0, row: 1))
    model.resetRows(model.selectedRows)
    #expect(model.sheet.rowHeights.isEmpty)
  }

  @Test("Typing on a cell shows in the cell straight away; Return saves and moves down")
  func typeInCell() throws {
    let (model, view, window) = makeGrid()
    view.cells.keyDown(with: key("5"))
    #expect(model.editing)
    #expect(model.editText == "5")
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.string == "5")
    // More typing goes into the cell editor, not a separate box.
    editor.insertText("0", replacementRange: editor.selectedRange)
    #expect(model.editText == "50")
    _ = view.cells.control(
      NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(!model.editing)
    #expect(model.raw(CellAddress(column: 0, row: 0)) == "50")
    #expect(model.focus == CellAddress(column: 0, row: 1))
  }

  @Test("Formulas: = suggests functions, click or arrow to add references, brackets close")
  func formulaHelp() throws {
    var sheet = Spreadsheet()
    sheet.set("B2", "10")
    sheet.set("B3", "32")
    let (model, view, window) = makeGrid(sheet)
    model.select(CellAddress(column: 3, row: 0))
    view.cells.keyDown(with: key("="))
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertText("SU", replacementRange: editor.selectedRange)
    #expect(model.suggestions.first?.name == "SUM")
    // Return picks the suggestion rather than saving.
    _ = view.cells.control(
      NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    #expect(model.editText == "=SUM(")
    #expect(model.hint?.name == "SUM")
    #expect(model.acceptsReference)
    // Clicking B2 while the formula wants a reference types it in.
    #expect(view.cells.editorLostClick(at: CellAddress(column: 1, row: 1), extending: false))
    #expect(model.editText == "=SUM(B2")
    // Shift-arrow stretches it into a range.
    model.movePointer(0, 1, extend: true)
    #expect(model.editText == "=SUM(B2:B3")
    #expect(model.references.count == 1)
    model.commit(move: (0, 1))
    #expect(model.raw(CellAddress(column: 3, row: 0)) == "=SUM(B2:B3)")
    #expect(model.value(CellAddress(column: 3, row: 0)) == .number(42))
  }

  @Test("Click cells and type operators to build =A+B/C, like Excel")
  func clickAndTypeFormula() throws {
    var sheet = Spreadsheet()
    sheet.set("A1", "10")
    sheet.set("B1", "8")
    sheet.set("C1", "2")
    let (model, view, window) = makeGrid(sheet)
    func click(_ address: CellAddress) {
      let cell = view.cells.rect(for: address)
      let point = view.cells.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
      func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1)!
      }
      // What AppKit does on a click: the view only takes the keyboard if it accepts it.
      if view.cells.acceptsFirstResponder { window.makeFirstResponder(view.cells) }
      view.cells.mouseDown(with: event(.leftMouseDown))
      view.cells.mouseUp(with: event(.leftMouseUp))
    }
    func type(_ text: String) throws {
      let editor = try #require(window.firstResponder as? NSTextView, "the cell keeps the keyboard")
      editor.insertText(text, replacementRange: editor.selectedRange)
    }
    model.select(CellAddress(column: 3, row: 0))
    view.cells.keyDown(with: key("="))
    click(CellAddress(column: 0, row: 0))
    #expect(model.editText == "=A1")
    try type("+")
    #expect(model.editText == "=A1+")
    click(CellAddress(column: 1, row: 0))
    try type("/")
    click(CellAddress(column: 2, row: 0))
    #expect(model.editText == "=A1+B1/C1")
    // A key that somehow reaches the grid mid-edit still goes into the formula.
    view.cells.keyDown(with: key("*"))
    try type("1")
    #expect(model.editText == "=A1+B1/C1*1")
    model.commit(move: (0, 1))
    #expect(model.value(CellAddress(column: 3, row: 0)) == .number(14))
  }

  @Test("Fill handle continues series and moves formula references; ⌘D fills down")
  func fill() {
    var sheet = Spreadsheet()
    sheet.set("A1", "1")
    sheet.set("A2", "2")
    sheet.set("B1", "=A1*2")
    let (model, _, _) = makeGrid(sheet)
    model.select(from: CellAddress(column: 0, row: 0), to: CellAddress(column: 0, row: 1))
    model.fill(to: CellAddress(column: 0, row: 4))
    #expect(model.raw(CellAddress(column: 0, row: 4)) == "5")
    model.select(CellAddress(column: 1, row: 0))
    model.fill(to: CellAddress(column: 1, row: 2))
    #expect(model.raw(CellAddress(column: 1, row: 2)) == "=A3*2")
    #expect(model.value(CellAddress(column: 1, row: 2)) == .number(6))
    model.select(from: CellAddress(column: 2, row: 0), to: CellAddress(column: 2, row: 2))
    model.apply(["C1": "=B1+1"])
    model.fillDown()
    #expect(model.raw(CellAddress(column: 2, row: 2)) == "=B3+1")
  }

  @Test("Copy and paste keeps formulas moving like Excel; outside text pastes as cells; undo")
  func clipboard() {
    var sheet = Spreadsheet()
    sheet.set("A1", "4")
    sheet.set("B1", "=A1*2")
    let (model, _, _) = makeGrid(sheet)
    model.select(CellAddress(column: 1, row: 0))
    model.copy()
    #expect(NSPasteboard.general.string(forType: .string) == "8")
    model.select(CellAddress(column: 2, row: 1))
    model.paste()
    #expect(model.raw(CellAddress(column: 2, row: 1)) == "=B2*2")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("Name\tAge\nAda\t36", forType: .string)
    model.select(CellAddress(column: 4, row: 4))
    model.paste()
    #expect(model.raw(CellAddress(column: 5, row: 5)) == "36")
    model.undo()
    #expect(model.raw(CellAddress(column: 5, row: 5)).isEmpty)
    model.redo()
    #expect(model.raw(CellAddress(column: 5, row: 5)) == "36")
  }

  @Test("Arrows, ⌘-arrows and Shift extend the selection; Delete clears")
  func navigation() {
    var sheet = Spreadsheet()
    for row in 1...5 { sheet.set("A\(row)", "\(row)") }
    let (model, view, _) = makeGrid(sheet)
    view.cells.keyDown(with: key("\u{F701}", code: 125, flags: [.command]))
    #expect(model.focus == CellAddress(column: 0, row: 4))
    view.cells.keyDown(with: key("\u{F700}", code: 126, flags: [.shift]))
    #expect(model.selectionLabel == "A4:A5")
    view.cells.keyDown(with: key("\u{7F}", code: 51))
    #expect(model.raw(CellAddress(column: 0, row: 3)).isEmpty)
  }

  @Test("Selecting a cell redraws fast")
  func speed() {
    var sheet = Spreadsheet()
    for row in 1...300 {
      for column in 0..<10 {
        sheet.set(
          CellAddress(column: column, row: row - 1).a1,
          column == 9 ? "=SUM(A\(row):I\(row))" : "\(row * column)")
      }
    }
    let (model, view, _) = makeGrid(sheet)
    let rep = view.cells.bitmapImageRepForCachingDisplay(
      in: view.scroll.contentView.documentVisibleRect)!
    let start = Date()
    for step in 0..<20 {
      model.select(CellAddress(column: step % 10, row: step))
      view.cells.cacheDisplay(in: view.scroll.contentView.documentVisibleRect, to: rep)
    }
    let perSelection = Date().timeIntervalSince(start) / 20
    // A frame at 60 Hz is about 16 ms.
    #expect(perSelection < 0.03)
  }

  /// Opt-in picture of the grid mid-formula, for review.
  @Test func renderGrid() throws {
    guard let output = ProcessInfo.processInfo.environment["OTTO_HOME_SNAPSHOT_DIR"] else { return }
    var sheet = Spreadsheet()
    let rows = [
      ["Item", "Monthly", "Yearly"], ["Rent", "1200", "=B2*12"], ["Food", "300", "=B3*12"],
      ["Software", "89", "=B4*12"], ["Total", "=SUM(B2:B4)", "=SUM(C2:C4)"],
    ]
    for (r, row) in rows.enumerated() {
      for (c, value) in row.enumerated() { sheet.set(CellAddress(column: c, row: r).a1, value) }
    }
    let (model, view, window) = makeGrid(sheet)
    window.appearance = NSAppearance(named: .darkAqua)
    model.select(CellAddress(column: 3, row: 4))
    view.cells.keyDown(with: key("="))
    let editor = try #require(window.firstResponder as? NSTextView)
    editor.insertText("AV", replacementRange: editor.selectedRange)
    view.layoutSubtreeIfNeeded()
    let snap = { (name: String) throws in
      let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: rep)
      try rep.representation(using: .png, properties: [:])?.write(
        to: URL(fileURLWithPath: "\(output)/\(name).png"))
    }
    try snap("sheet-suggest")
    _ = view.cells.control(
      NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    model.point(to: CellAddress(column: 1, row: 1), CellAddress(column: 1, row: 3))
    view.layoutSubtreeIfNeeded()
    try snap("sheet-reference")
  }
}

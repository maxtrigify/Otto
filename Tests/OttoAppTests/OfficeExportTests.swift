import AppKit
import OttoModels
import OttoServices
import Testing

@testable import OttoApp

@MainActor
@Suite("Current Office exports", .serialized)
struct OfficeExportTests {
  @Test("Export commits an unfinished cell and keeps all workbook tabs")
  func latestWorkbook() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "Office export \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let office = OfficeStore(workspacePath: root.path)
    let file = try office.create(.spreadsheet, title: "Budget")
    var book = SpreadsheetWorkbook(Spreadsheet(cells: ["A1": "old"]), name: "Summary")
    let details = try book.addTab(named: "Details")
    book.setSheet(Spreadsheet(cells: ["A1": "42"]), for: details.id)
    try office.saveWorkbook(book, path: file.path)
    let grid = SheetModel(sheet: Spreadsheet())
    let tabs = SheetTabsModel()
    tabs.attach(grid, office: office, path: file.path)
    grid.save = { tabs.saveActive($0) }
    tabs.reload(book)
    grid.beginEditing(with: "latest")
    #expect(grid.editing)
    // Another writer adds a tab while the user is typing in the open grid.
    let added = try book.addTab(named: "Agent notes")
    book.setSheet(Spreadsheet(cells: ["A1": "new tab"]), for: added.id)
    try office.saveWorkbook(book, path: file.path)
    let exported = try tabs.workbookForExport(path: file.path)
    #expect(!grid.editing)
    #expect(exported.tabs.map(\.name) == ["Summary", "Details", "Agent notes"])
    #expect(exported.tabs[0].sheet.raw("A1") == "latest")
    #expect(exported.tabs[1].sheet.raw("A1") == "42")
    let archive = XLSXWriter.data(for: exported)
    // The ZIP writer stores the XML without compression.
    let xml = String(decoding: archive, as: UTF8.self)
    #expect(xml.contains("xl/worksheets/sheet2.xml"))
    #expect(xml.contains("xl/worksheets/sheet3.xml"))
    #expect(xml.contains("new tab"))
    #expect(xml.contains("latest"))
    #expect(xml.contains("42"))
  }

  @Test("A failed cell save stops export instead of returning stale disk content")
  func failedSheetSave() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "Office export \(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let office = OfficeStore(workspacePath: root.path)
    let file = try office.create(.spreadsheet, title: "Budget")
    let grid = SheetModel(sheet: Spreadsheet())
    let tabs = SheetTabsModel()
    tabs.attach(grid, office: office, path: file.path)
    grid.save = { tabs.saveActive($0) }
    tabs.reload(try office.loadWorkbook(path: file.path))
    // A directory in place of the file makes the atomic save fail deterministically.
    let url = office.url(for: file.path)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    grid.beginEditing(with: "unsaved")
    #expect(throws: (any Error).self) { try tabs.workbookForExport(path: file.path) }
    #expect(tabs.error != nil)
  }

  @Test("Document export flushes current text and propagates save errors")
  func documentFlush() throws {
    let view = NSTextView()
    view.string = "Latest document text"
    let controller = DocEditorController()
    controller.textView = view
    var saved = ""
    controller.save = { saved = $0.string }
    controller.changed()
    try controller.saveForExport()
    #expect(saved == view.string)
    controller.save = { _ in throw CocoaError(.fileWriteNoPermission) }
    #expect(throws: (any Error).self) { try controller.saveForExport() }
  }
}

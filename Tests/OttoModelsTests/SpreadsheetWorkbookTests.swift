import Foundation
import Testing

@testable import OttoModels

@Suite("Spreadsheet tabs")
struct SpreadsheetWorkbookTests {
  private func book() throws -> SpreadsheetWorkbook {
    var book = SpreadsheetWorkbook(
      Spreadsheet(cells: ["A1": "Total", "B1": "=SUM(Sales!B2:B3)", "B2": "=Sales!B2*2"]),
      name: "Summary")
    let sales = try book.addTab(named: "Sales")
    book.setSheet(
      Spreadsheet(cells: ["A2": "Jan", "B2": "100", "A3": "Feb", "B3": "50"]), for: sales.id)
    let quoted = try book.addTab(named: "Q1 data")
    book.setSheet(Spreadsheet(cells: ["A1": "7", "A2": "=Summary!B1"]), for: quoted.id)
    return book
  }

  @Test("Formulas read other tabs, quoted or not, in any case")
  func crossTabFormulas() throws {
    var book = try book()
    let summary = book.tabs[0]
    let evaluator = book.evaluator(for: summary.id)
    #expect(evaluator.value(at: "B1") == .number(150))
    #expect(evaluator.value(at: "B2") == .number(200))
    #expect(evaluator.evaluate(formula: "='Q1 data'!A1 + sales!b3") == .number(57))
    #expect(evaluator.evaluate(formula: "=VLOOKUP(\"Feb\", Sales!A2:B3, 2, FALSE)") == .number(50))
    #expect(evaluator.evaluate(formula: "=COUNTIF(Sales!B2:B3, \">60\")") == .number(1))
    #expect(evaluator.evaluate(formula: "=Missing!A1") == .error("#REF!"))
    let q1 = try #require(book.tab(named: "q1 DATA"))
    #expect(book.evaluator(for: q1.id).value(at: "A2") == .number(150))

    // A loop through two tabs is caught rather than recursing forever.
    book.setSheet(Spreadsheet(cells: ["A1": "=Summary!C1"]), for: q1.id)
    var summarySheet = summary.sheet
    summarySheet.set("C1", "='Q1 data'!A1")
    book.setSheet(summarySheet, for: summary.id)
    #expect(book.evaluator(for: summary.id).value(at: "C1") == .error("#CYCLE!"))
  }

  @Test("References know their tab, copying keeps the tab, renaming rewrites formulas")
  func referencesAndRenaming() throws {
    let refs = SpreadsheetFormula.references(in: "=SUM(Sales!B2:B3) + 'Q1 data'!A1 + C4")
    #expect(refs.map(\.sheet) == ["Sales", "Q1 data", nil])
    #expect(refs.map { $0.start.a1 } == ["B2", "A1", "C4"])
    #expect(
      SpreadsheetFormula.shifted("=Sales!B2+'Q1 data'!$A1", rows: 1, columns: 1)
        == "=Sales!C3+'Q1 data'!$A2")

    var book = try book()
    let sales = try #require(book.tab(named: "Sales"))
    try book.renameTab(sales.id, to: "Revenue 2026")
    #expect(book.tabs[0].sheet.raw("B1") == "=SUM('Revenue 2026'!B2:B3)")
    #expect(book.evaluator(for: book.tabs[0].id).value(at: "B1") == .number(150))
    let q1 = try #require(book.tab(named: "Q1 data"))
    try book.renameTab(q1.id, to: "Notes")
    #expect(book.tabs[0].sheet.raw("B2") == "='Revenue 2026'!B2*2")
    #expect(SpreadsheetFormula.sheetPrefix("Notes") == "Notes")
    #expect(SpreadsheetFormula.sheetPrefix("A1") == "'A1'")
    #expect(SpreadsheetFormula.sheetPrefix("Bob's") == "'Bob''s'")
  }

  @Test("Tabs are added, named, duplicated, moved and removed with Excel's rules")
  func arranging() throws {
    var book = SpreadsheetWorkbook()
    #expect(book.tabs.map(\.name) == ["Sheet1"])
    let second = try book.addTab()
    #expect(second.name == "Sheet2")
    #expect(throws: SpreadsheetWorkbook.TabError.duplicateName("Sheet1")) {
      try book.renameTab(second.id, to: "sheet1")
    }
    #expect(throws: SpreadsheetWorkbook.TabError.invalidCharacters) {
      try book.renameTab(second.id, to: "a/b")
    }
    #expect(throws: SpreadsheetWorkbook.TabError.emptyName) {
      try book.renameTab(second.id, to: "  ")
    }
    let copy = try book.duplicateTab(second.id)
    #expect(book.tabs.map(\.name) == ["Sheet1", "Sheet2", "Sheet2 (2)"])
    book.moveTab(copy.id, to: 0)
    #expect(book.tabs.first?.id == copy.id)
    let removed = try book.removeTab(copy.id)
    try book.removeTab(second.id)
    #expect(throws: SpreadsheetWorkbook.TabError.lastTab) { try book.removeTab(book.tabs[0].id) }
    book.restoreTab(removed.tab, at: removed.index)
    #expect(book.tabs.map(\.name) == ["Sheet2 (2)", "Sheet1"])
  }

  @Test("Old single-sheet files open as one tab and tabs survive a save")
  func fileFormat() throws {
    let legacy = Data(#"{"cells":{"A1":"5"},"columnWidths":{}}"#.utf8)
    #expect(try JSONDecoder().decode(Spreadsheet.self, from: legacy).rowHeights.isEmpty)
    let tall = Spreadsheet(cells: ["A2": "x"], rowHeights: [1: 80])
    #expect(try JSONDecoder().decode(Spreadsheet.self, from: JSONEncoder().encode(tall)) == tall)
    let opened = try JSONDecoder().decode(SpreadsheetWorkbook.self, from: legacy)
    #expect(opened.tabs.map(\.name) == ["Sheet1"])
    #expect(opened.tabs[0].sheet.raw("A1") == "5")
    #expect(
      try JSONDecoder().decode(SpreadsheetWorkbook.self, from: legacy).tabs[0].id
        == opened.tabs[0].id)
    let book = try book()
    let round = try JSONDecoder().decode(
      SpreadsheetWorkbook.self, from: JSONEncoder().encode(book))
    #expect(round == book)
  }

  @Test("Excel export writes one worksheet per tab with working cross-tab formulas")
  func xlsx() throws {
    let data = XLSXWriter.data(for: try book())
    let url = FileManager.default.temporaryDirectory.appending(path: "tabs-\(UUID()).xlsx")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    func unzip(_ arguments: [String]) throws -> (Int32, String) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
    #expect(try unzip(["-t", url.path]).0 == 0)
    let workbook = try unzip(["-p", url.path, "xl/workbook.xml"]).1
    #expect(workbook.contains(#"<sheet name="Summary" sheetId="1" r:id="rId1"/>"#))
    #expect(workbook.contains(#"<sheet name="Q1 data" sheetId="3" r:id="rId3"/>"#))
    let summary = try unzip(["-p", url.path, "xl/worksheets/sheet1.xml"]).1
    #expect(summary.contains("<f>SUM(Sales!B2:B3)</f><v>150</v>"))
    #expect(
      XLSXWriter.excelFormula("sum('Q1 data'!a1, 'it''s'!b2)") == "SUM('Q1 data'!A1, 'it''s'!B2)")
    let notes = FileManager.default.temporaryDirectory.appending(path: "tall-\(UUID()).xlsx")
    try XLSXWriter.data(
      for: Spreadsheet(cells: ["A2": "x"], rowHeights: [1: 80]), sheetName: "Notes"
    ).write(to: notes)
    defer { try? FileManager.default.removeItem(at: notes) }
    #expect(
      try unzip(["-p", notes.path, "xl/worksheets/sheet1.xml"]).1
        .contains(#"<row r="2" ht="80.0" customHeight="1">"#))
    let types = try unzip(["-p", url.path, "\\[Content_Types].xml"]).1
    #expect(types.contains("/xl/worksheets/sheet3.xml"))
  }
}

import Foundation

/// Writes an Office Open XML workbook, one worksheet per tab.
public enum XLSXWriter {
  /// A minimal valid .xlsx workbook with one sheet: numbers as numbers, text as inline strings,
  /// booleans, and formulas kept as formulas (with the cached evaluated value).
  public static func data(for sheet: Spreadsheet, sheetName: String) -> Data {
    data(for: SpreadsheetWorkbook(sheet, name: sanitizedSheetName(sheetName)))
  }

  /// Every tab becomes a worksheet, in order; formulas between tabs keep working in Excel.
  public static func data(for book: SpreadsheetWorkbook) -> Data {
    var used: Set<String> = []
    let names = book.tabs.enumerated().map { index, tab in
      var name = sanitizedSheetName(tab.name)
      if used.contains(name.lowercased()) { name = "Sheet\(index + 1)" }
      used.insert(name.lowercased())
      return name
    }
    var entries: [(path: String, data: Data)] = [
      ("[Content_Types].xml", Data(contentTypes(count: book.tabs.count).utf8)),
      ("_rels/.rels", Data(rootRelationships.utf8)),
      ("xl/workbook.xml", Data(workbook(sheetNames: names).utf8)),
      ("xl/_rels/workbook.xml.rels", Data(workbookRelationships(count: book.tabs.count).utf8)),
    ]
    for (index, tab) in book.tabs.enumerated() {
      entries.append(
        (
          "xl/worksheets/sheet\(index + 1).xml",
          Data(worksheet(tab.sheet, evaluator: book.evaluator(for: tab.id)).utf8)
        ))
    }
    return ZipArchive.make(entries: entries)
  }

  /// Strips `[]:*?/\`, trims, caps at 31 characters, and falls back to `Sheet1`.
  static func sanitizedSheetName(_ name: String) -> String {
    let cleaned = String(name.filter { !"[]:*?/\\".contains($0) })
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["'"]))
    let capped = String(cleaned.prefix(31)).trimmingCharacters(in: ["'"])
    return capped.isEmpty ? "Sheet1" : capped
  }

  // MARK: Parts

  private static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
  private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
  private static let relationshipNamespace =
    "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

  private static func contentTypes(count: Int) -> String {
    header
      + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
      + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
      + #"<Default Extension="xml" ContentType="application/xml"/>"#
      + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
      + (1...count).map {
        #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
      }.joined()
      + "</Types>"
  }

  private static let rootRelationships =
    header
    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
    + #"<Relationship Id="rId1" Type="\#(relationshipNamespace)/officeDocument" Target="xl/workbook.xml"/>"#
    + "</Relationships>"

  private static func workbookRelationships(count: Int) -> String {
    header
      + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
      + (1...count).map {
        #"<Relationship Id="rId\#($0)" Type="\#(relationshipNamespace)/worksheet" Target="worksheets/sheet\#($0).xml"/>"#
      }.joined()
      + "</Relationships>"
  }

  private static func workbook(sheetNames: [String]) -> String {
    header
      + #"<workbook xmlns="\#(mainNamespace)" xmlns:r="\#(relationshipNamespace)"><sheets>"#
      + sheetNames.enumerated().map { index, name in
        #"<sheet name="\#(escape(name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
      }.joined()
      + #"</sheets><calcPr fullCalcOnLoad="1"/>"#
      + "</workbook>"
  }

  private static func worksheet(_ sheet: Spreadsheet, evaluator: SpreadsheetEvaluator) -> String {
    let filled = sheet.cells.compactMap { key, raw -> (CellAddress, String)? in
      guard !raw.isEmpty, let address = CellAddress(key) else { return nil }
      return (address, raw)
    }
    .sorted { $0.0 < $1.0 }

    var xml = header + #"<worksheet xmlns="\#(mainNamespace)">"#
    let widths = sheet.columnWidths.filter { $0.key >= 0 && $0.value > 0 }.sorted {
      $0.key < $1.key
    }
    if !widths.isEmpty {
      xml += "<cols>"
      for (column, points) in widths {
        // Excel widths are in default-font character units of roughly 7 px (at 96 dpi).
        let characters = (points * 96 / 72 / 7 * 100).rounded() / 100
        xml +=
          #"<col min="\#(column + 1)" max="\#(column + 1)" width="\#(characters)" customWidth="1"/>"#
      }
      xml += "</cols>"
    }
    xml += "<sheetData>"
    var currentRow: Int?
    for (address, raw) in filled {
      if address.row != currentRow {
        if currentRow != nil { xml += "</row>" }
        currentRow = address.row
        // Taller rows keep their height (Excel measures rows in points too).
        let height = sheet.rowHeights[address.row].map { #" ht="\#($0)" customHeight="1""# } ?? ""
        xml += #"<row r="\#(address.row + 1)"\#(height)>"#
      }
      xml += cell(address: address, raw: raw, evaluator: evaluator)
    }
    if currentRow != nil { xml += "</row>" }
    xml += "</sheetData></worksheet>"
    return xml
  }

  private static func cell(
    address: CellAddress, raw: String, evaluator: SpreadsheetEvaluator
  ) -> String {
    let reference = address.a1
    if raw.hasPrefix("=") {
      let formula = "<f>\(escape(excelFormula(String(raw.dropFirst()))))</f>"
      switch evaluator.value(at: reference) {
      case .number(let value):
        return #"<c r="\#(reference)">\#(formula)<v>\#(number(value))</v></c>"#
      case .bool(let flag):
        return #"<c r="\#(reference)" t="b">\#(formula)<v>\#(flag ? 1 : 0)</v></c>"#
      case .text(let text):
        return #"<c r="\#(reference)" t="str">\#(formula)<v>\#(escape(text))</v></c>"#
      case .error(let code):
        let known = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]
        let cached = known.contains(code) ? code : "#VALUE!"
        return #"<c r="\#(reference)" t="e">\#(formula)<v>\#(cached)</v></c>"#
      case .empty:
        return #"<c r="\#(reference)">\#(formula)</c>"#
      }
    }
    switch CellValue.literal(raw) {
    case .number(let value):
      return #"<c r="\#(reference)"><v>\#(number(value))</v></c>"#
    case .bool(let flag):
      return #"<c r="\#(reference)" t="b"><v>\#(flag ? 1 : 0)</v></c>"#
    default:
      let preserve =
        raw.first?.isWhitespace == true || raw.last?.isWhitespace == true
        ? #" xml:space="preserve""# : ""
      return #"<c r="\#(reference)" t="inlineStr"><is><t\#(preserve)>\#(escape(raw))</t></is></c>"#
    }
  }

  private static func number(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  /// Functions added after Excel 2007 must carry the `_xlfn.` prefix inside the file.
  private static let modernFunctions: Set<String> = [
    "CONCAT", "IFS", "SWITCH", "XLOOKUP", "TEXTJOIN", "XOR", "IFNA", "DAYS", "MAXIFS", "MINIFS",
    "STDEV.S", "VAR.S", "RANK.EQ", "CEILING.MATH", "FLOOR.MATH",
  ]

  /// Uppercases names outside string literals and adds the `_xlfn.` prefix Excel requires for
  /// functions newer than the 2007 file format.
  static func excelFormula(_ formula: String) -> String {
    var output = ""
    var name = ""
    var inString = false
    var inSheetName = false
    func flushName(_ next: Character?) {
      guard !name.isEmpty else { return }
      let upper = name.uppercased()
      // Tab names before `!` keep their case.
      output +=
        next == "!"
        ? name : next == "(" && modernFunctions.contains(upper) ? "_xlfn." + upper : upper
      name = ""
    }
    for character in formula {
      if inString {
        output.append(character)
        if character == "\"" { inString = false }
      } else if inSheetName {
        output.append(character)
        if character == "'" { inSheetName = false }
      } else if character == "'" {
        flushName(character)
        output.append(character)
        inSheetName = true
      } else if character.isLetter || character.isNumber || character == "_" || character == "."
        || character == "$"
      {
        name.append(character)
      } else {
        flushName(character)
        output.append(character)
        if character == "\"" { inString = true }
      }
    }
    flushName(nil)
    return output
  }

  static func escape(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&apos;"
      case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
      default:
        // XML 1.0 forbids other C0 controls and the U+FFFE/U+FFFF noncharacters.
        if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }
}

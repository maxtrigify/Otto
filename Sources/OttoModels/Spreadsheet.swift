import Foundation

// MARK: - Addresses

/// A zero-based cell position. Ordering is row-major (row first, then column).
public struct CellAddress: Hashable, Codable, Sendable, Comparable {
  public var column: Int
  public var row: Int

  public init(column: Int, row: Int) {
    self.column = column
    self.row = row
  }

  /// Parses A1 notation (`A1`, `b12`, `AA3`, `$C$4`), case-insensitive. Columns run to `XFD`
  /// and rows to 1,048,576, matching Excel.
  public init?(_ a1: String) {
    let scalars = Array(a1.trimmingCharacters(in: .whitespaces).unicodeScalars)
    var index = 0
    if index < scalars.count, scalars[index] == "$" { index += 1 }
    var column = 0
    var letters = 0
    while index < scalars.count, let letter = Self.letterValue(scalars[index]) {
      column = column * 26 + letter
      letters += 1
      index += 1
      if letters > 3 { return nil }
    }
    guard letters > 0 else { return nil }
    if index < scalars.count, scalars[index] == "$" { index += 1 }
    var row = 0
    var digits = 0
    while index < scalars.count, (48...57).contains(scalars[index].value) {
      row = row * 10 + Int(scalars[index].value - 48)
      digits += 1
      index += 1
      if digits > 7 { return nil }
    }
    guard digits > 0, index == scalars.count, (1...1_048_576).contains(row),
      column <= 16_384
    else { return nil }
    self.init(column: column - 1, row: row - 1)
  }

  /// Canonical A1 notation, e.g. `"B3"`.
  public var a1: String { Self.columnName(column) + String(row + 1) }

  /// The letters for a zero-based column index: 0 → `A`, 25 → `Z`, 26 → `AA`.
  public static func columnName(_ index: Int) -> String {
    guard index >= 0 else { return "" }
    var remaining = index + 1
    var scalars: [Character] = []
    while remaining > 0 {
      remaining -= 1
      scalars.insert(Character(UnicodeScalar(UInt8(65 + remaining % 26))), at: 0)
      remaining /= 26
    }
    return String(scalars)
  }

  public static func < (lhs: CellAddress, rhs: CellAddress) -> Bool {
    (lhs.row, lhs.column) < (rhs.row, rhs.column)
  }

  private static func letterValue(_ scalar: Unicode.Scalar) -> Int? {
    switch scalar.value {
    case 65...90: Int(scalar.value) - 64
    case 97...122: Int(scalar.value) - 96
    default: nil
    }
  }
}

// MARK: - Sheet

/// A sparse grid of raw cell inputs keyed by canonical A1 address.
public struct Spreadsheet: Codable, Equatable, Sendable {
  /// Canonical uppercase `"A1"` → raw input (`"12"`, `"=SUM(A1:A3)"`, `"Hello"`).
  public var cells: [String: String]
  /// Optional per-column widths in points.
  public var columnWidths: [Int: Double]
  /// Rows made taller than the default, in points. Text in a taller row wraps.
  public var rowHeights: [Int: Double]

  public init(
    cells: [String: String] = [:], columnWidths: [Int: Double] = [:],
    rowHeights: [Int: Double] = [:]
  ) {
    self.cells = cells
    self.columnWidths = columnWidths
    self.rowHeights = rowHeights
  }

  private enum CodingKeys: String, CodingKey { case cells, columnWidths, rowHeights }

  /// Files saved before row heights existed have none.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cells = try container.decode([String: String].self, forKey: .cells)
    columnWidths = try container.decodeIfPresent([Int: Double].self, forKey: .columnWidths) ?? [:]
    rowHeights = try container.decodeIfPresent([Int: Double].self, forKey: .rowHeights) ?? [:]
  }

  /// The raw input at an address in any case, or `""` when empty.
  public func raw(_ a1: String) -> String {
    guard let address = CellAddress(a1) else { return "" }
    return cells[address.a1] ?? ""
  }

  /// Stores raw input verbatim; an empty string clears the cell. Invalid addresses are ignored.
  public mutating func set(_ a1: String, _ raw: String) {
    guard let address = CellAddress(a1) else { return }
    cells[address.a1] = raw.isEmpty ? nil : raw
  }

  /// Bounding size of the non-empty cells, `(0, 0)` when the sheet is empty.
  public var usedSize: (columns: Int, rows: Int) {
    var columns = 0
    var rows = 0
    for (key, value) in cells where !value.isEmpty {
      guard let address = CellAddress(key) else { continue }
      columns = max(columns, address.column + 1)
      rows = max(rows, address.row + 1)
    }
    return (columns, rows)
  }
}

// MARK: - Values

/// The evaluated value of a cell or formula.
public enum CellValue: Equatable, Sendable {
  case empty
  case number(Double)
  case text(String)
  case bool(Bool)
  case error(String)

  /// User-facing text: integers without a fraction, other numbers to 10 significant digits.
  public var display: String {
    switch self {
    case .empty: ""
    case .number(let value): Self.format(value)
    case .text(let text): text
    case .bool(let flag): flag ? "TRUE" : "FALSE"
    case .error(let code): code
    }
  }

  /// Numeric reading: numbers, booleans as 1/0, and numeric text. `nil` for empty, other text
  /// and errors (arithmetic separately treats empty as 0).
  public var number: Double? {
    switch self {
    case .number(let value): value
    case .bool(let flag): flag ? 1 : 0
    case .text(let text): Self.parseNumber(text)
    case .empty, .error: nil
    }
  }

  /// Interprets non-formula input: numbers (`1,234.5`, `12%`, `$5`), `TRUE`/`FALSE`, or text.
  static func literal(_ raw: String) -> CellValue {
    if raw.isEmpty { return .empty }
    if let number = parseNumber(raw) { return .number(number) }
    switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
    case "TRUE": return .bool(true)
    case "FALSE": return .bool(false)
    default: return .text(raw)
    }
  }

  static func parseNumber(_ raw: String) -> Double? {
    var text = Substring(raw.trimmingCharacters(in: .whitespaces))
    var sign = 1.0
    if text.hasPrefix("-") {
      sign = -1
      text.removeFirst()
    } else if text.hasPrefix("+") {
      text.removeFirst()
    }
    if text.hasPrefix("$") { text.removeFirst() }
    var scale = 1.0
    if text.hasSuffix("%") {
      scale = 0.01
      text.removeLast()
    }
    if text.contains(",") {
      guard let grouped = ungroup(text) else { return nil }
      text = Substring(grouped)
    }
    guard !text.isEmpty, text.contains(where: \.isASCIIDigit),
      text.allSatisfy({ $0.isASCIIDigit || ".eE+-".contains($0) }),
      let value = Double(text), value.isFinite
    else { return nil }
    return sign * value * scale
  }

  /// Removes thousands separators, requiring well-formed 3-digit groups before any decimal point.
  private static func ungroup(_ text: Substring) -> String? {
    let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let integer = parts.first, !(parts.count > 1 && parts[1].contains(",")) else {
      return nil
    }
    let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
    guard let head = groups.first, (1...3).contains(head.count),
      groups.dropFirst().allSatisfy({ $0.count == 3 })
    else { return nil }
    return groups.joined() + (parts.count > 1 ? "." + parts[1] : "")
  }

  static func format(_ value: Double) -> String {
    guard value.isFinite else { return "#NUM!" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(format: "%.10g", value)
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Evaluator

/// Evaluates cells and formulas against a snapshot of a sheet. Results are memoised for the
/// lifetime of the evaluator, so create a new one after the sheet changes.
public struct SpreadsheetEvaluator {
  /// One sheet's filled cells and the values worked out so far.
  fileprivate final class Cache {
    let filled: [(address: CellAddress, raw: String)]
    let extent: (rows: Int, columns: Int)
    var values: [CellAddress: CellValue] = [:]
    var visiting: Set<CellAddress> = []

    init(_ sheet: Spreadsheet) {
      filled = sheet.cells.compactMap { key, raw in
        guard !raw.isEmpty, let address = CellAddress(key) else { return nil }
        return (address, raw)
      }
      .sorted { $0.address < $1.address }
      extent = (
        (filled.last?.address.row ?? -1) + 1,
        (filled.map(\.address.column).max() ?? -1) + 1
      )
    }
  }

  /// Every tab a formula can reach (`Sales!B2`), shared by the evaluators of one workbook so a
  /// loop that runs through several tabs is still caught.
  fileprivate final class Book {
    /// Keyed by lowercased tab name.
    var sheets: [String: Spreadsheet] = [:]
    var caches: [String: Cache] = [:]
    var depth = 0
  }

  /// Guards against stack exhaustion on very long dependency chains.
  private static let maxDepth = 400

  private let sheet: Spreadsheet
  private let filled: [(address: CellAddress, raw: String)]
  private let cache: Cache
  private let book: Book
  /// Rows and columns spanned by filled cells; everything beyond is empty.
  let extent: (rows: Int, columns: Int)

  public init(_ sheet: Spreadsheet) {
    self.init(sheet, named: "", in: [:])
  }

  /// Evaluates `sheet`, a tab called `name`, whose formulas may read the other tabs.
  public init(_ sheet: Spreadsheet, named name: String, in tabs: [String: Spreadsheet]) {
    let book = Book()
    for (tab, contents) in tabs { book.sheets[tab.lowercased()] = contents }
    book.sheets[name.lowercased()] = sheet
    let cache = Cache(sheet)
    book.caches[name.lowercased()] = cache
    self.init(sheet: sheet, cache: cache, book: book)
  }

  private init(sheet: Spreadsheet, cache: Cache, book: Book) {
    self.sheet = sheet
    self.cache = cache
    self.book = book
    filled = cache.filled
    extent = cache.extent
  }

  /// The evaluator for another tab in the same workbook, or nil when there is no such tab.
  func tab(_ name: String) -> SpreadsheetEvaluator? {
    let key = name.lowercased()
    guard let sheet = book.sheets[key] else { return nil }
    let cache = book.caches[key] ?? Cache(sheet)
    book.caches[key] = cache
    return SpreadsheetEvaluator(sheet: sheet, cache: cache, book: book)
  }

  /// The value of a cell; `#REF!` for an invalid address and `#CYCLE!` for circular references.
  public func value(at a1: String) -> CellValue {
    guard let address = CellAddress(a1) else { return .error("#REF!") }
    return value(at: address)
  }

  /// Evaluates a formula with or without its leading `=`.
  public func evaluate(formula: String) -> CellValue {
    var source = Substring(formula.trimmingCharacters(in: .whitespacesAndNewlines))
    if source.hasPrefix("=") { source.removeFirst() }
    guard let expression = FormulaParser.parse(String(source)) else { return .error("#ERROR!") }
    let result = evaluate(expression)
    return result == .empty ? .number(0) : result
  }

  func value(at address: CellAddress) -> CellValue {
    if let cached = cache.values[address] { return cached }
    if cache.visiting.contains(address) { return .error("#CYCLE!") }
    guard let raw = sheet.cells[address.a1], !raw.isEmpty else { return .empty }
    guard raw.hasPrefix("=") else { return CellValue.literal(raw) }
    guard book.depth < Self.maxDepth else { return .error("#REF!") }
    cache.visiting.insert(address)
    book.depth += 1
    let result = evaluate(formula: raw)
    book.depth -= 1
    cache.visiting.remove(address)
    cache.values[address] = result
    return result
  }

  // MARK: Expressions

  struct CellError: Error {
    var code: String
  }

  func evaluate(_ expression: FormulaExpression) -> CellValue {
    switch expression {
    case .number(let value): return .number(value)
    case .text(let text): return .text(text)
    case .bool(let flag): return .bool(flag)
    case .error(let code): return .error(code)
    case .ref(let address): return value(at: address)
    case .range: return .error("#VALUE!")
    case .sheet(let name, let inner):
      return tab(name)?.evaluate(inner) ?? .error("#REF!")
    case .negate(let operand):
      return guarded { .number(-(try numeric(evaluate(operand)))) }
    case .binary(let op, let lhs, let rhs):
      let left = evaluate(lhs)
      if case .error = left { return left }
      let right = evaluate(rhs)
      if case .error = right { return right }
      return guarded { try binary(op, left, right) }
    case .call(let name, let args):
      return guarded { try call(name, args) }
    }
  }

  private func guarded(_ body: () throws -> CellValue) -> CellValue {
    do {
      return try body()
    } catch let error as CellError {
      return .error(error.code)
    } catch {
      return .error("#VALUE!")
    }
  }

  private func binary(_ op: String, _ left: CellValue, _ right: CellValue) throws -> CellValue {
    switch op {
    case "&": return .text(try text(left) + text(right))
    case "=": return .bool(compare(left, right) == .orderedSame)
    case "<>": return .bool(compare(left, right) != .orderedSame)
    case "<": return .bool(compare(left, right) == .orderedAscending)
    case ">": return .bool(compare(left, right) == .orderedDescending)
    case "<=": return .bool(compare(left, right) != .orderedDescending)
    case ">=": return .bool(compare(left, right) != .orderedAscending)
    default: break
    }
    let a = try numeric(left)
    let b = try numeric(right)
    let result: Double
    switch op {
    case "+": result = a + b
    case "-": result = a - b
    case "*": result = a * b
    case "/":
      guard b != 0 else { throw CellError(code: "#DIV/0!") }
      result = a / b
    case "^":
      guard !(a == 0 && b < 0) else { throw CellError(code: "#DIV/0!") }
      result = pow(a, b)
    default: throw CellError(code: "#ERROR!")
    }
    guard result.isFinite else { throw CellError(code: "#NUM!") }
    return .number(result)
  }

  /// Excel ordering: numbers < text < booleans; text compares case-insensitively; empty takes
  /// the other side's type.
  func compare(_ left: CellValue, _ right: CellValue) -> ComparisonResult {
    func rank(_ value: CellValue, other: CellValue) -> (Int, CellValue) {
      switch value {
      case .number: return (0, value)
      case .text: return (1, value)
      case .bool: return (2, value)
      default:
        switch other {
        case .text: return (1, .text(""))
        case .bool: return (2, .bool(false))
        default: return (0, .number(0))
        }
      }
    }
    let (leftRank, l) = rank(left, other: right)
    let (rightRank, r) = rank(right, other: left)
    if leftRank != rightRank {
      return leftRank < rightRank ? .orderedAscending : .orderedDescending
    }
    switch (l, r) {
    case (.number(let a), .number(let b)):
      return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    case (.text(let a), .text(let b)):
      return a.caseInsensitiveCompare(b)
    case (.bool(let a), .bool(let b)):
      return a == b ? .orderedSame : (!a ? .orderedAscending : .orderedDescending)
    default:
      return .orderedSame
    }
  }

  func numeric(_ value: CellValue) throws -> Double {
    switch value {
    case .empty: return 0
    case .error(let code): throw CellError(code: code)
    case .text(let text):
      guard let number = CellValue.parseNumber(text) else { throw CellError(code: "#VALUE!") }
      return number
    default: return value.number ?? 0
    }
  }

  func text(_ value: CellValue) throws -> String {
    if case .error(let code) = value { throw CellError(code: code) }
    return value.display
  }

  func truth(_ value: CellValue) throws -> Bool {
    switch value {
    case .empty: return false
    case .bool(let flag): return flag
    case .number(let number): return number != 0
    case .error(let code): throw CellError(code: code)
    case .text(let text):
      switch text.uppercased() {
      case "TRUE": return true
      case "FALSE": return false
      default: throw CellError(code: "#VALUE!")
      }
    }
  }

  // MARK: Functions

  /// One argument's values; ranges yield their non-empty cells in row-major order.
  func values(of argument: FormulaExpression) -> (values: [CellValue], isRange: Bool) {
    if case .sheet(let name, let inner) = argument, case .range = inner {
      guard let other = tab(name) else { return ([.error("#REF!")], false) }
      return other.values(of: inner)
    }
    guard case .range(let start, let end) = argument else { return ([evaluate(argument)], false) }
    let columns = min(start.column, end.column)...max(start.column, end.column)
    let rows = min(start.row, end.row)...max(start.row, end.row)
    let inside = filled.filter {
      columns.contains($0.address.column) && rows.contains($0.address.row)
    }
    return (inside.map { value(at: $0.address) }, true)
  }

  func numbers(_ args: [FormulaExpression]) throws -> [Double] {
    var result: [Double] = []
    for arg in args {
      let (items, isRange) = values(of: arg)
      for item in items {
        switch item {
        case .error(let code): throw CellError(code: code)
        case .number(let number): result.append(number)
        case .empty: continue
        default: if !isRange { result.append(try numeric(item)) }
        }
      }
    }
    return result
  }

  private func call(_ name: String, _ args: [FormulaExpression]) throws -> CellValue {
    func arity(_ range: ClosedRange<Int>) throws {
      guard range.contains(args.count) else { throw CellError(code: "#VALUE!") }
    }
    func scalar(_ index: Int) throws -> CellValue {
      let value = evaluate(args[index])
      if case .error(let code) = value { throw CellError(code: code) }
      return value
    }
    switch name {
    case "SUM":
      return .number(try numbers(args).reduce(0, +))
    case "AVERAGE":
      let all = try numbers(args)
      guard !all.isEmpty else { throw CellError(code: "#DIV/0!") }
      return .number(all.reduce(0, +) / Double(all.count))
    case "MIN":
      return .number(try numbers(args).min() ?? 0)
    case "MAX":
      return .number(try numbers(args).max() ?? 0)
    case "COUNT":
      let counted = args.flatMap { arg -> [CellValue] in
        let (items, isRange) = values(of: arg)
        return items.filter { item in
          if case .number = item { return true }
          return !isRange && item != .empty && item.number != nil
        }
      }
      return .number(Double(counted.count))
    case "COUNTA":
      return .number(Double(args.flatMap { values(of: $0).values }.filter { $0 != .empty }.count))
    case "ROUND":
      try arity(1...2)
      let value = try numeric(scalar(0))
      let digits = args.count > 1 ? try numeric(scalar(1)).rounded(.towardZero) : 0
      let factor = pow(10, digits)
      let rounded = (value * factor).rounded(.toNearestOrAwayFromZero) / factor
      return .number(rounded.isFinite ? rounded : value)
    case "ABS":
      try arity(1...1)
      return .number(abs(try numeric(scalar(0))))
    case "IF":
      try arity(2...3)
      if try truth(scalar(0)) { return evaluate(args[1]) }
      return args.count > 2 ? evaluate(args[2]) : .bool(false)
    case "AND", "OR":
      var flags: [Bool] = []
      for arg in args {
        let (items, isRange) = values(of: arg)
        for item in items {
          if isRange, case .text = item { continue }
          flags.append(try truth(item))
        }
      }
      guard !flags.isEmpty else { throw CellError(code: "#VALUE!") }
      return .bool(name == "AND" ? flags.allSatisfy { $0 } : flags.contains(true))
    case "NOT":
      try arity(1...1)
      return .bool(!(try truth(scalar(0))))
    case "CONCAT", "CONCATENATE":
      return .text(try args.flatMap { values(of: $0).values }.map(text).joined())
    case "LEN":
      try arity(1...1)
      return .number(Double(try text(scalar(0)).count))
    case "UPPER":
      try arity(1...1)
      return .text(try text(scalar(0)).uppercased())
    case "LOWER":
      try arity(1...1)
      return .text(try text(scalar(0)).lowercased())
    case "TODAY":
      try arity(0...0)
      let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
      return .text(
        String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    default:
      return try extendedCall(name, args)
    }
  }
}

// MARK: - Formula parsing

indirect enum FormulaExpression: Equatable, Sendable {
  case number(Double)
  case text(String)
  case bool(Bool)
  case error(String)
  case ref(CellAddress)
  case range(CellAddress, CellAddress)
  /// A reference or range on another tab: `Sales!B2`, `'Q1 data'!A1:A9`.
  case sheet(String, FormulaExpression)
  case negate(FormulaExpression)
  case binary(String, FormulaExpression, FormulaExpression)
  case call(String, [FormulaExpression])
}

extension FormulaExpression {
  /// A range, on this tab or another.
  var isRange: Bool {
    switch self {
    case .range: true
    case .sheet(_, let inner): inner.isRange
    default: false
    }
  }
}

/// Recursive-descent parser. Precedence, lowest first: comparison, `&`, `+ -`, `* /`, `^`
/// (right-associative), unary minus (binds tighter than `^`, as in Excel).
struct FormulaParser {
  enum Token: Equatable {
    case number(Double)
    case text(String)
    case name(String)
    case op(String)
    case error(String)
    /// A tab name written before `!`, quoted or not.
    case sheet(String)
  }

  /// Error literals that may appear in formulas, e.g. after a copied reference fell off the grid.
  static let errorLiterals = [
    "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A", "#NULL!", "#ERROR!", "#CYCLE!",
  ]

  private var tokens: [Token]
  private var position = 0

  static func parse(_ source: String) -> FormulaExpression? {
    guard let tokens = tokenize(source), !tokens.isEmpty else { return nil }
    var parser = FormulaParser(tokens: tokens)
    guard let expression = parser.comparison(), parser.position == tokens.count else { return nil }
    return expression
  }

  private init(tokens: [Token]) {
    self.tokens = tokens
  }

  static func tokenize(_ source: String) -> [Token]? {
    let scalars = Array(source.unicodeScalars)
    var tokens: [Token] = []
    var index = 0
    func isDigit(_ i: Int) -> Bool { i < scalars.count && (48...57).contains(scalars[i].value) }
    func isNameStart(_ s: Unicode.Scalar) -> Bool {
      s == "$" || s == "_" || CharacterSet.letters.contains(s)
    }
    while index < scalars.count {
      let scalar = scalars[index]
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        index += 1
      } else if isDigit(index) || (scalar == "." && isDigit(index + 1)) {
        let start = index
        while isDigit(index) || (index < scalars.count && scalars[index] == ".") { index += 1 }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
          var next = index + 1
          if next < scalars.count, scalars[next] == "+" || scalars[next] == "-" { next += 1 }
          if isDigit(next) {
            index = next
            while isDigit(index) { index += 1 }
          }
        }
        var literal = ""
        literal.unicodeScalars.append(contentsOf: scalars[start..<index])
        guard let value = Double(literal) else { return nil }
        tokens.append(.number(value))
      } else if scalar == "\"" {
        var text = ""
        index += 1
        while true {
          guard index < scalars.count else { return nil }
          if scalars[index] == "\"" {
            if index + 1 < scalars.count, scalars[index + 1] == "\"" {
              text.unicodeScalars.append("\"")
              index += 2
              continue
            }
            index += 1
            break
          }
          text.unicodeScalars.append(scalars[index])
          index += 1
        }
        tokens.append(.text(text))
      } else if scalar == "'" {
        var name = ""
        index += 1
        while true {
          guard index < scalars.count else { return nil }
          if scalars[index] == "'" {
            if index + 1 < scalars.count, scalars[index + 1] == "'" {
              name.unicodeScalars.append("'")
              index += 2
              continue
            }
            index += 1
            break
          }
          name.unicodeScalars.append(scalars[index])
          index += 1
        }
        guard index < scalars.count, scalars[index] == "!", !name.isEmpty else { return nil }
        index += 1
        tokens.append(.sheet(name))
      } else if scalar == "#" {
        let rest = String(String.UnicodeScalarView(scalars[index...])).uppercased()
        guard let code = errorLiterals.first(where: { rest.hasPrefix($0) }) else { return nil }
        tokens.append(.error(code))
        index += code.unicodeScalars.count
      } else if isNameStart(scalar) {
        let start = index
        while index < scalars.count,
          isNameStart(scalars[index]) || isDigit(index) || scalars[index] == "."
        {
          index += 1
        }
        var name = ""
        name.unicodeScalars.append(contentsOf: scalars[start..<index])
        if index < scalars.count, scalars[index] == "!" {
          index += 1
          tokens.append(.sheet(name))
        } else {
          tokens.append(.name(name.uppercased()))
        }
      } else {
        let pair =
          index + 1 < scalars.count ? String(scalar) + String(scalars[index + 1]) : ""
        if ["<=", ">=", "<>"].contains(pair) {
          tokens.append(.op(pair))
          index += 2
        } else if "+-*/^&=<>,():".unicodeScalars.contains(scalar) {
          tokens.append(.op(String(scalar)))
          index += 1
        } else {
          return nil
        }
      }
    }
    return tokens
  }

  private var current: Token? { position < tokens.count ? tokens[position] : nil }

  private mutating func take(_ ops: Set<String>) -> String? {
    guard case .op(let op) = current, ops.contains(op) else { return nil }
    position += 1
    return op
  }

  private mutating func binaryLevel(
    _ ops: Set<String>, _ next: (inout FormulaParser) -> FormulaExpression?
  ) -> FormulaExpression? {
    guard var lhs = next(&self) else { return nil }
    while let op = take(ops) {
      guard let rhs = next(&self) else { return nil }
      lhs = .binary(op, lhs, rhs)
    }
    return lhs
  }

  mutating func comparison() -> FormulaExpression? {
    binaryLevel(["=", "<>", "<", ">", "<=", ">="]) { $0.concatenation() }
  }

  private mutating func concatenation() -> FormulaExpression? {
    binaryLevel(["&"]) { $0.additive() }
  }

  private mutating func additive() -> FormulaExpression? {
    binaryLevel(["+", "-"]) { $0.multiplicative() }
  }

  private mutating func multiplicative() -> FormulaExpression? {
    binaryLevel(["*", "/"]) { $0.power() }
  }

  private mutating func power() -> FormulaExpression? {
    guard let base = unary() else { return nil }
    guard take(["^"]) != nil else { return base }
    guard let exponent = power() else { return nil }
    return .binary("^", base, exponent)
  }

  private mutating func unary() -> FormulaExpression? {
    if take(["-"]) != nil { return unary().map { .negate($0) } }
    if take(["+"]) != nil { return unary() }
    return primary()
  }

  private mutating func primary() -> FormulaExpression? {
    guard let token = current else { return nil }
    position += 1
    switch token {
    case .number(let value): return .number(value)
    case .text(let text): return .text(text)
    case .error(let code): return .error(code)
    case .op("("):
      guard let inner = comparison(), take([")"]) != nil else { return nil }
      return inner
    case .op: return nil
    case .sheet(let tab):
      guard case .name(let name) = current, let address = CellAddress(name) else { return nil }
      position += 1
      guard take([":"]) != nil else { return .sheet(tab, .ref(address)) }
      guard case .name(let endName) = current else { return nil }
      position += 1
      guard let end = CellAddress(endName) else { return .error("#REF!") }
      return .sheet(tab, .range(address, end))
    case .name(let name):
      if take(["("]) != nil { return call(name) }
      if let address = CellAddress(name) {
        guard take([":"]) != nil else { return .ref(address) }
        guard case .name(let endName) = current else { return nil }
        position += 1
        guard let end = CellAddress(endName) else { return .error("#REF!") }
        return .range(address, end)
      }
      if name == "TRUE" { return .bool(true) }
      if name == "FALSE" { return .bool(false) }
      return .error(Self.looksLikeReference(name) ? "#REF!" : "#NAME?")
    }
  }

  private mutating func call(_ name: String) -> FormulaExpression? {
    var args: [FormulaExpression] = []
    if take([")"]) != nil { return .call(name, args) }
    repeat {
      guard let arg = comparison() else { return nil }
      args.append(arg)
    } while take([","]) != nil
    guard take([")"]) != nil else { return nil }
    return .call(name, args)
  }

  /// Letters followed by digits (e.g. `A0`, `ZZZZ1`) that fall outside the grid.
  private static func looksLikeReference(_ name: String) -> Bool {
    let stripped = name.replacingOccurrences(of: "$", with: "")
    guard let firstDigit = stripped.firstIndex(where: \.isASCIIDigit) else { return false }
    let letters = stripped[..<firstDigit]
    let digits = stripped[firstDigit...]
    return !letters.isEmpty && letters.allSatisfy { ("A"..."Z").contains($0) }
      && digits.allSatisfy(\.isASCIIDigit)
  }
}

// MARK: - CSV

/// RFC 4180 CSV conversion for spreadsheets.
public enum SpreadsheetCSV {
  /// Writes the used range with CRLF line endings; `evaluated` writes display values instead of
  /// raw inputs.
  public static func encode(_ sheet: Spreadsheet, evaluated: Bool) -> String {
    encode(sheet, evaluator: evaluated ? SpreadsheetEvaluator(sheet) : nil)
  }

  /// Values from `evaluator` (which can see the other tabs), or raw input when nil.
  public static func encode(_ sheet: Spreadsheet, evaluator: SpreadsheetEvaluator?) -> String {
    let size = sheet.usedSize
    var lines: [String] = []
    for row in 0..<size.rows {
      var fields: [String] = []
      for column in 0..<size.columns {
        let a1 = CellAddress(column: column, row: row).a1
        let field = evaluator?.value(at: a1).display ?? sheet.raw(a1)
        fields.append(quote(field))
      }
      lines.append(fields.joined(separator: ","))
    }
    return lines.joined(separator: "\r\n")
  }

  /// Parses CSV with quoted fields, doubled quotes, CRLF or LF endings and embedded newlines.
  public static func decode(_ text: String) -> Spreadsheet {
    var sheet = Spreadsheet()
    var row = 0
    var column = 0
    var field = String.UnicodeScalarView()
    var inQuotes = false
    var scalars = Array(text.unicodeScalars)
    if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
    func commit() {
      let value = String(field)
      if !value.isEmpty { sheet.set(CellAddress(column: column, row: row).a1, value) }
      field = String.UnicodeScalarView()
    }
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      if inQuotes {
        if scalar == "\"" {
          if index < scalars.count, scalars[index] == "\"" {
            field.append("\"")
            index += 1
          } else {
            inQuotes = false
          }
        } else {
          field.append(scalar)
        }
        continue
      }
      switch scalar {
      case "\"" where field.isEmpty:
        inQuotes = true
      case ",":
        commit()
        column += 1
      case "\r", "\n":
        if scalar == "\r", index < scalars.count, scalars[index] == "\n" { index += 1 }
        commit()
        row += 1
        column = 0
      default:
        field.append(scalar)
      }
    }
    commit()
    return sheet
  }

  private static func quote(_ field: String) -> String {
    let needsQuotes = field.unicodeScalars.contains { "\",\r\n".unicodeScalars.contains($0) }
    guard needsQuotes else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

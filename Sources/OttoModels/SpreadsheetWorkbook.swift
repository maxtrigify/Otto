import Foundation

/// A spreadsheet file with one or more tabs, like Excel's worksheets. Formulas on one tab can
/// read another with `Sales!B2` or `'Q1 data'!A1:A9`.
public struct SpreadsheetWorkbook: Equatable, Sendable {
  public struct Tab: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var sheet: Spreadsheet

    public init(id: UUID = UUID(), name: String, sheet: Spreadsheet = Spreadsheet()) {
      self.id = id
      self.name = name
      self.sheet = sheet
    }
  }

  public enum TabError: Error, LocalizedError, Equatable {
    case emptyName
    case invalidCharacters
    case duplicateName(String)
    case lastTab
    case unknownTab(String)

    public var errorDescription: String? {
      switch self {
      case .emptyName: "Give the tab a name."
      case .invalidCharacters: "Tab names can’t contain [ ] : * ? / or \\."
      case .duplicateName(let name): "There’s already a tab called “\(name)”."
      case .lastTab: "A spreadsheet needs at least one tab."
      case .unknownTab(let name): "There’s no tab called “\(name)”."
      }
    }
  }

  /// Excel's limit, so names survive export.
  public static let nameLimit = 31
  public static let tabLimit = 64

  /// Never empty.
  public private(set) var tabs: [Tab]

  public init(tabs: [Tab]) {
    self.tabs = tabs.isEmpty ? [Tab(name: "Sheet1")] : tabs
  }

  /// A one-tab workbook, as every sheet was before tabs existed.
  public init(_ sheet: Spreadsheet = Spreadsheet(), name: String = "Sheet1") {
    tabs = [Tab(name: name, sheet: sheet)]
  }

  public func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

  /// Finds a tab by name, ignoring case, as formulas do.
  public func tab(named name: String) -> Tab? {
    let key = name.trimmingCharacters(in: .whitespaces)
    return tabs.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
  }

  /// Every tab by name, for evaluating formulas that reach across tabs.
  public var sheetsByName: [String: Spreadsheet] {
    Dictionary(tabs.map { ($0.name, $0.sheet) }, uniquingKeysWith: { first, _ in first })
  }

  public func evaluator(for id: UUID) -> SpreadsheetEvaluator {
    let tab = tabs.first { $0.id == id } ?? tabs[0]
    return SpreadsheetEvaluator(tab.sheet, named: tab.name, in: sheetsByName)
  }

  public mutating func setSheet(_ sheet: Spreadsheet, for id: UUID) {
    guard let index = index(of: id) else { return }
    tabs[index].sheet = sheet
  }

  // MARK: Arranging tabs

  /// Adds an empty tab after `after` (or at the end) called "Sheet<n>" unless named.
  @discardableResult
  public mutating func addTab(named name: String? = nil, after: UUID? = nil) throws -> Tab {
    let tab = Tab(name: try validName(name ?? nextName(), excluding: nil))
    let position = after.flatMap(index(of:)).map { $0 + 1 } ?? tabs.count
    tabs.insert(tab, at: position)
    return tab
  }

  /// Copies a tab next to itself as "Name (2)".
  @discardableResult
  public mutating func duplicateTab(_ id: UUID) throws -> Tab {
    guard let index = index(of: id) else { throw TabError.unknownTab(id.uuidString) }
    let original = tabs[index]
    var number = 2
    var name = Self.copyName(original.name, number)
    while tab(named: name) != nil {
      number += 1
      name = Self.copyName(original.name, number)
    }
    let copy = Tab(name: name, sheet: original.sheet)
    tabs.insert(copy, at: index + 1)
    return copy
  }

  /// Renames a tab and rewrites formulas on every tab that pointed at the old name.
  public mutating func renameTab(_ id: UUID, to name: String) throws {
    guard let index = index(of: id) else { throw TabError.unknownTab(id.uuidString) }
    let old = tabs[index].name
    let new = try validName(name, excluding: id)
    guard new != old else { return }
    tabs[index].name = new
    for tabIndex in tabs.indices {
      for (key, raw) in tabs[tabIndex].sheet.cells where raw.hasPrefix("=") {
        let rewritten = SpreadsheetFormula.renamingSheet(raw, from: old, to: new)
        if rewritten != raw { tabs[tabIndex].sheet.cells[key] = rewritten }
      }
    }
  }

  /// Removes a tab. Formulas that pointed at it show #REF!, as in Excel.
  @discardableResult
  public mutating func removeTab(_ id: UUID) throws -> (tab: Tab, index: Int) {
    guard tabs.count > 1 else { throw TabError.lastTab }
    guard let index = index(of: id) else { throw TabError.unknownTab(id.uuidString) }
    return (tabs.remove(at: index), index)
  }

  /// Puts a removed tab back (undo).
  public mutating func restoreTab(_ tab: Tab, at index: Int) {
    guard self.index(of: tab.id) == nil else { return }
    var tab = tab
    if self.tab(named: tab.name) != nil { tab.name = Self.copyName(tab.name, 2) }
    tabs.insert(tab, at: min(max(0, index), tabs.count))
  }

  /// Moves a tab to `destination`, an index among the tabs before the move.
  public mutating func moveTab(_ id: UUID, to destination: Int) {
    guard let from = index(of: id) else { return }
    let tab = tabs.remove(at: from)
    tabs.insert(tab, at: min(max(0, destination), tabs.count))
  }

  /// Trims a proposed name and checks it is allowed and not taken by another tab.
  public func validName(_ proposed: String, excluding id: UUID?) throws -> String {
    let name = String(
      proposed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit)
    ).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.hasPrefix("'"), !name.hasSuffix("'") else {
      throw name.isEmpty ? TabError.emptyName : TabError.invalidCharacters
    }
    guard !name.contains(where: { "[]:*?/\\".contains($0) }) else {
      throw TabError.invalidCharacters
    }
    if let clash = tabs.first(where: {
      $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      throw TabError.duplicateName(clash.name)
    }
    return name
  }

  private func nextName() -> String {
    var number = tabs.count + 1
    while tab(named: "Sheet\(number)") != nil { number += 1 }
    return "Sheet\(number)"
  }

  private static func copyName(_ name: String, _ number: Int) -> String {
    let suffix = " (\(number))"
    return String(name.prefix(nameLimit - suffix.count)) + suffix
  }
}

extension SpreadsheetWorkbook: Codable {
  private enum CodingKeys: String, CodingKey { case tabs }

  /// Reads both the tabbed format and the older single-sheet files (`{"cells": …}`).
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let tabs = try container.decodeIfPresent([Tab].self, forKey: .tabs) {
      self.init(tabs: tabs)
    } else {
      // Legacy files have one unnamed tab. Its identity must survive repeated reads so an
      // editor can merge a pending cell edit into the latest workbook before export.
      self.init(tabs: [
        Tab(
          id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
          name: "Sheet1", sheet: try Spreadsheet(from: decoder))
      ])
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(tabs, forKey: .tabs)
  }
}

import OttoModels
import OttoServices
import SwiftUI

/// The tabs of an open spreadsheet: which one is showing, and adding, renaming, reordering,
/// duplicating and deleting them. Every change saves the whole workbook.
@MainActor
final class SheetTabsModel: ObservableObject {
  @Published private(set) var book = SpreadsheetWorkbook()
  @Published private(set) var activeID: UUID?
  @Published var error: String?
  private weak var grid: SheetModel?
  private var office: OfficeStore?
  private var path = ""
  private var saveFailure: Error?
  /// The tab the grid is showing, so a rename or reload doesn't reset its selection.
  private var shownID: UUID?

  var active: SpreadsheetWorkbook.Tab {
    book.tabs.first { $0.id == activeID } ?? book.tabs[0]
  }

  func attach(_ grid: SheetModel, office: OfficeStore, path: String) {
    self.grid = grid
    self.office = office
    self.path = path
    saveFailure = nil
    shownID = nil
  }

  /// Reads the file again (on open, or after an agent changed it), staying on the same tab
  /// when it still exists.
  func reload(_ next: SpreadsheetWorkbook) {
    book = next
    if activeID.flatMap(next.index(of:)) == nil { activeID = next.tabs[0].id }
    showActive()
  }

  /// The grid saved an edit to the open tab.
  func saveActive(_ sheet: Spreadsheet) {
    let activeID = active.id
    do {
      guard let office else { throw CocoaError(.fileReadUnknown) }
      var latest = try office.loadWorkbook(path: path)
      guard latest.index(of: activeID) != nil else {
        throw SpreadsheetWorkbook.TabError.unknownTab(active.name)
      }
      latest.setSheet(sheet, for: activeID)
      book = latest
      persist()
    } catch {
      saveFailure = error
      self.error = "Couldn’t save: \(error.localizedDescription)"
    }
  }

  /// Commit the cell still being typed before exporting every tab from disk.
  func workbookForExport(path expectedPath: String) throws -> SpreadsheetWorkbook {
    guard expectedPath == path, let office, let grid else { throw CocoaError(.fileReadUnknown) }
    if grid.editing { grid.commit() }
    if let saveFailure { throw saveFailure }
    return try office.loadWorkbook(path: path)
  }

  func select(_ id: UUID) {
    guard id != activeID, book.index(of: id) != nil else { return }
    if let grid, grid.editing { grid.commit() }
    activeID = id
    showActive()
  }

  func add() {
    guard book.tabs.count < SpreadsheetWorkbook.tabLimit else {
      error = "A spreadsheet holds up to \(SpreadsheetWorkbook.tabLimit) tabs."
      return
    }
    change { book in
      let tab = try book.addTab(after: activeID)
      activeID = tab.id
    }
  }

  func duplicate(_ id: UUID) {
    change { book in activeID = try book.duplicateTab(id).id }
  }

  /// Returns false (and explains why) when the name can't be used.
  @discardableResult
  func rename(_ id: UUID, to name: String) -> Bool {
    change { book in try book.renameTab(id, to: name) }
  }

  func move(_ id: UUID, by offset: Int) {
    guard let index = book.index(of: id) else { return }
    change { book in book.moveTab(id, to: index + offset) }
  }

  /// Drops a dragged tab where `target` is.
  func move(_ id: UUID, onto target: UUID) {
    guard id != target, let index = book.index(of: target) else { return }
    change { book in book.moveTab(id, to: index) }
  }

  func delete(_ id: UUID) -> (tab: SpreadsheetWorkbook.Tab, index: Int)? {
    var removed: (tab: SpreadsheetWorkbook.Tab, index: Int)?
    change { book in
      removed = try book.removeTab(id)
      if activeID == id {
        activeID = book.tabs[min(removed?.index ?? 0, book.tabs.count - 1)].id
      }
    }
    return removed
  }

  func restore(_ tab: SpreadsheetWorkbook.Tab, at index: Int) {
    change { book in
      book.restoreTab(tab, at: index)
      activeID = tab.id
    }
  }

  /// Cells an agent changed on one tab. Older highlights without a tab belong to the first.
  func touched(in tab: SpreadsheetWorkbook.Tab, from keys: Set<String>) -> Set<String> {
    let prefix = tab.name.lowercased() + "!"
    let isFirst = book.tabs.first?.id == tab.id
    return Set(
      keys.compactMap { key in
        if key.lowercased().hasPrefix(prefix) { return String(key.dropFirst(prefix.count)) }
        return isFirst && !key.contains("!") ? key : nil
      })
  }

  @discardableResult
  private func change(_ edit: (inout SpreadsheetWorkbook) throws -> Void) -> Bool {
    if let grid, grid.editing { grid.commit() }
    var next = book
    do {
      try edit(&next)
    } catch {
      self.error = error.localizedDescription
      return false
    }
    book = next
    error = nil
    persist()
    showActive()
    return true
  }

  private func showActive() {
    let tab = active
    var others = book.sheetsByName
    others[tab.name] = nil
    grid?.show(tab.sheet, tab: tab.name, others: others, switching: shownID != tab.id)
    shownID = tab.id
  }

  private func persist() {
    do {
      try office?.saveWorkbook(book, path: path)
      saveFailure = nil
    } catch {
      saveFailure = error
      self.error = "Couldn’t save: \(error.localizedDescription)"
    }
  }
}

/// Excel-style tabs under the grid: click to switch, double-click to rename, drag to reorder,
/// right-click for more, + to add.
struct SheetTabBar: View {
  @ObservedObject var tabs: SheetTabsModel
  /// Tab names with cells an agent just changed, shown with a dot.
  let changed: Set<UUID>
  @Environment(\.ottoPalette) private var palette
  @State private var renaming: UUID?
  @State private var draftName = ""
  @State private var dropTarget: UUID?
  @State private var undo: OttoUndoToast?
  @State private var pendingRestore: (tab: SpreadsheetWorkbook.Tab, index: Int)?
  @FocusState private var nameFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Button(action: tabs.add) {
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
          .frame(width: 26, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.muted)
      .help("Add a tab")
      .accessibilityLabel("Add a tab")
      .accessibilityIdentifier("sheet.tabs.add")
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 2) {
            ForEach(tabs.book.tabs) { tab in
              chip(tab).id(tab.id)
            }
          }
          .padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .onChange(of: tabs.activeID) { _, id in
          withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
        }
      }
      if let error = tabs.error {
        Text(error).font(.ottoDisplay(11)).foregroundStyle(palette.red).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(height: 34)
    .background(palette.raised.opacity(0.5))
    .ottoUndoToast(
      $undo,
      onUndo: {
        if let pending = pendingRestore { tabs.restore(pending.tab, at: pending.index) }
        pendingRestore = nil
      },
      onExpire: { pendingRestore = nil })
  }

  @ViewBuilder private func chip(_ tab: SpreadsheetWorkbook.Tab) -> some View {
    let active = tab.id == tabs.active.id
    Group {
      if renaming == tab.id {
        TextField("Tab name", text: $draftName)
          .textFieldStyle(.plain)
          .font(.ottoDisplay(12).weight(.semibold))
          .frame(width: max(70, CGFloat(draftName.count) * 7.5 + 16))
          .focused($nameFocused)
          .onSubmit { finishRename(tab) }
          .onExitCommand { renaming = nil }
          .onChange(of: nameFocused) { _, focused in
            if !focused, renaming == tab.id { finishRename(tab) }
          }
      } else {
        HStack(spacing: 5) {
          Text(tab.name)
            .font(.ottoDisplay(12).weight(active ? .semibold : .regular))
            .lineLimit(1)
          if changed.contains(tab.id) {
            Circle().fill(palette.signal).frame(width: 5, height: 5)
              .accessibilityLabel("Changed by AI")
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 26)
    .foregroundStyle(active ? palette.paper : palette.muted)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(active ? palette.surface : .clear)
    )
    .overlay(alignment: .bottom) {
      if active {
        Capsule().fill(palette.signal).frame(height: 2).padding(.horizontal, 8)
      }
    }
    .overlay {
      if dropTarget == tab.id {
        RoundedRectangle(cornerRadius: 6).strokeBorder(palette.signal, lineWidth: 1.5)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { beginRename(tab) }
    .onTapGesture { tabs.select(tab.id) }
    .draggable(tab.id.uuidString) {
      Text(tab.name).font(.ottoDisplay(12).weight(.semibold))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 6))
    }
    .dropDestination(for: String.self) { items, _ in
      guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
      withAnimation(.easeOut(duration: 0.15)) { tabs.move(id, onto: tab.id) }
      return true
    } isTargeted: { targeted in
      if targeted {
        dropTarget = tab.id
      } else if dropTarget == tab.id {
        dropTarget = nil
      }
    }
    .contextMenu {
      Button("Rename…") { beginRename(tab) }
      Button("Duplicate") { tabs.duplicate(tab.id) }
      Divider()
      Button("Move left") { tabs.move(tab.id, by: -1) }
        .disabled(tabs.book.tabs.first?.id == tab.id)
      Button("Move right") { tabs.move(tab.id, by: 1) }
        .disabled(tabs.book.tabs.last?.id == tab.id)
      Divider()
      Button("Delete", role: .destructive) { delete(tab) }
        .disabled(tabs.book.tabs.count == 1)
    }
    .help(tab.name)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Tab \(tab.name)")
    .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
  }

  private func beginRename(_ tab: SpreadsheetWorkbook.Tab) {
    tabs.select(tab.id)
    draftName = tab.name
    renaming = tab.id
    nameFocused = true
  }

  private func finishRename(_ tab: SpreadsheetWorkbook.Tab) {
    guard renaming == tab.id else { return }
    renaming = nil
    if draftName != tab.name { tabs.rename(tab.id, to: draftName) }
  }

  private func delete(_ tab: SpreadsheetWorkbook.Tab) {
    guard let removed = tabs.delete(tab.id) else { return }
    pendingRestore = removed
    undo = OttoUndoToast(title: "Tab deleted", detail: "“\(tab.name)”")
  }
}

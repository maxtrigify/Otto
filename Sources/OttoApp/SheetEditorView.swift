import AppKit
import OttoModels
import OttoServices
import SwiftUI

/// A spreadsheet that behaves like Excel and Google Sheets: type straight into a cell, "="
/// suggests functions, click cells to build a formula, drag the corner to fill, and copy and
/// paste with other apps. Cells an agent changed glow until cleared.
struct SheetEditorView: View {
  @ObservedObject var office: OfficeStore
  let file: OfficeFile
  let ask: (OfficeAsk) -> Void
  let bots: [(id: UUID, name: String)]
  @Environment(\.ottoPalette) private var palette
  @ObservedObject var model: SheetModel
  @ObservedObject var tabs: SheetTabsModel
  @State private var loaded = false
  @State private var loadError: String?
  @FocusState private var barFocused: Bool
  /// The formula bar grows to show a long cell's whole text, like Excel's expand arrow.
  @AppStorage("otto.sheet.formulaBarExpanded") private var barExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      formulaBar
      Divider().overlay(palette.paper.opacity(0.08))
      SheetGrid(model: model, colors: colors, menu: makeMenu)
      Divider().overlay(palette.paper.opacity(0.08))
      SheetTabBar(tabs: tabs, changed: changedTabs)
      statusBar
    }
    .onAppear(perform: load)
    .onChange(of: office.revisions[file.path]) { _, _ in reloadFromDisk() }
    .onChange(of: office.agentTouched[file.path]) { _, _ in showTouched() }
    .onChange(of: tabs.activeID) { _, _ in showTouched() }
  }

  /// Tabs with cells an agent changed, for the dot on each tab.
  private var changedTabs: Set<UUID> {
    let keys = office.agentTouched[file.path] ?? []
    guard !keys.isEmpty else { return [] }
    return Set(tabs.book.tabs.filter { !tabs.touched(in: $0, from: keys).isEmpty }.map(\.id))
  }

  private func showTouched() {
    model.touched = tabs.touched(in: tabs.active, from: office.agentTouched[file.path] ?? [])
    model.redraw()
  }

  private var colors: SheetColors {
    SheetColors(
      background: NSColor(palette.surface), header: NSColor(palette.raised),
      text: NSColor(palette.paper), muted: NSColor(palette.muted),
      grid: NSColor(palette.paper.opacity(0.09)), accent: NSColor(palette.signal),
      error: NSColor(palette.red))
  }

  // MARK: Formula bar

  private var barText: Binding<String> {
    Binding(
      get: { model.editing ? model.editText : model.raw(model.focus) },
      set: { value in
        if !model.editing { model.beginEditingInBar() }
        model.editText = value
      })
  }

  private var formulaBar: some View {
    HStack(alignment: barExpanded ? .top : .center, spacing: 10) {
      Text(model.selectionLabel)
        .font(.ottoMono(11, weight: .medium))
        .frame(width: 84, alignment: .leading)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      Text("fx").font(.ottoMono(11, weight: .semibold).italic()).foregroundStyle(palette.muted)
      TextField("Type a value, or = for a formula", text: barText, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.ottoMono(12.5))
        .foregroundStyle(palette.paper)
        .lineLimit(barExpanded ? 3...14 : 1...1)
        .padding(.top, barExpanded ? 5 : 0)
        .focused($barFocused)
        .onSubmit {
          model.commit(move: (0, 1))
          barFocused = false
        }
        .onKeyPress(.escape) {
          model.cancelEditing()
          barFocused = false
          return .handled
        }
        .accessibilityLabel("Cell contents")
      if let hint = model.hint {
        Text(hint.signature)
          .font(.ottoMono(10.5))
          .foregroundStyle(palette.muted)
          .lineLimit(1)
          .help(hint.summary)
      }
      if !(office.agentTouched[file.path] ?? []).isEmpty {
        Button("Clear AI highlights") { office.clearTouched(path: file.path) }
          .buttonStyle(.plain)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.signal)
      }
      Button {
        withAnimation(.easeOut(duration: 0.15)) { barExpanded.toggle() }
      } label: {
        Image(systemName: barExpanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.muted)
      .keyboardShortcut("u", modifiers: [.control, .shift])
      .help(
        barExpanded
          ? "Collapse the formula bar (⌃⇧U)" : "Expand the formula bar to read long text (⌃⇧U)"
      )
      .accessibilityLabel(barExpanded ? "Collapse formula bar" : "Expand formula bar")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, barExpanded ? 9 : 0)
    .frame(minHeight: 42)
  }

  private var statusBar: some View {
    HStack(spacing: 14) {
      if let stats = model.selectionStats {
        Text("SUM \(CellValue.number(stats.sum).display)")
        Text("AVERAGE \(CellValue.number(stats.sum / Double(stats.count)).display)")
        Text("COUNT \(stats.count)")
      }
      if let loadError { Text(loadError).foregroundStyle(palette.red) }
      Spacer()
      Text("= FOR FORMULAS · DRAG A ROW EDGE TO READ LONG TEXT · RIGHT-CLICK TO ASK AI")
    }
    .font(.ottoMicro).tracking(1.4)
    .foregroundStyle(palette.muted)
    .padding(.horizontal, 16)
    .frame(height: 28)
  }

  // MARK: Menu

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    let label = model.selectionLabel
    let place = tabs.book.tabs.count > 1 ? "\(tabs.active.name)!\(label)" : label
    let quote = "\(place) in “\(file.title)”"
    menu.addItem(ClosureMenuItem("Cut") { model.copy(cut: true) })
    menu.addItem(ClosureMenuItem("Copy") { model.copy() })
    menu.addItem(ClosureMenuItem("Paste") { model.paste() })
    menu.addItem(ClosureMenuItem("Clear") { model.clearSelection() })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem("Fill down (⌘D)") { model.fillDown() })
    menu.addItem(ClosureMenuItem("Fill right (⌘R)") { model.fillRight() })
    menu.addItem(.separator())
    let rows = model.selectedRows
    menu.addItem(
      ClosureMenuItem(rows.count == 1 ? "Fit row height to text" : "Fit row heights to text") {
        model.fitRows(rows)
      })
    if rows.contains(where: model.wraps) {
      menu.addItem(
        ClosureMenuItem(rows.count == 1 ? "Reset row height" : "Reset row heights") {
          model.resetRows(rows)
        })
    }
    menu.addItem(.separator())
    let askItem = ClosureMenuItem("Ask AI about \(label)…") { ask(OfficeAsk(quote: quote)) }
    askItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
    menu.addItem(askItem)
    menu.addItem(
      ClosureMenuItem("Add a total row below") {
        ask(OfficeAsk(quote: quote, request: "Add a clearly labelled total row under this range."))
      })
    menu.addItem(
      ClosureMenuItem("Explain or fix this formula") {
        ask(
          OfficeAsk(
            quote: "\(quote): \(model.raw(model.focus))",
            request: "Explain what this does in plain words, and fix it if it's wrong."))
      })
    menu.addItem(
      ClosureMenuItem("Chart this on a dashboard") {
        ask(
          OfficeAsk(
            quote: quote,
            request:
              "Turn this data into a chart card on one of my dashboards (create one if needed) with home.add_card, style line or bar, and say in source that it came from this sheet."
          ))
      })
    if !bots.isEmpty {
      let tag = NSMenuItem(title: "Ask a bot", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      for bot in bots {
        submenu.addItem(ClosureMenuItem(bot.name) { ask(OfficeAsk(quote: quote, bot: bot.id)) })
      }
      tag.submenu = submenu
      menu.addItem(tag)
    }
    return menu
  }

  // MARK: Loading and saving

  private func load() {
    guard !loaded else { return }
    loaded = true
    tabs.attach(model, office: office, path: file.path)
    model.save = { [tabs] sheet in tabs.saveActive(sheet) }
    reloadFromDisk()
    showTouched()
  }

  private func reloadFromDisk() {
    // Never pull the sheet out from under someone mid-typing.
    guard !model.editing else { return }
    do {
      tabs.reload(try office.loadWorkbook(path: file.path))
      loadError = nil
    } catch {
      loadError = "Couldn’t open: \(error.localizedDescription)"
    }
  }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("Not used") }

  @objc private func run() { handler() }
}

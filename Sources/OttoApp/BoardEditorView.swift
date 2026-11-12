import AppKit
import OttoModels
import OttoServices
import SwiftUI

/// What the pointer does on a whiteboard.
enum BoardTool: String, CaseIterable, Identifiable {
  case select, hand, note, text, rectangle, ellipse, diamond, frame, arrow, ask

  var id: String { rawValue }

  var symbol: String {
    switch self {
    case .select: "cursorarrow"
    case .hand: "hand.raised"
    case .note: "note.text"
    case .text: "textformat"
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .diamond: "diamond"
    case .frame: "rectangle.dashed"
    case .arrow: "arrow.up.right"
    case .ask: "sparkles"
    }
  }

  var help: String {
    switch self {
    case .select: "Select and move (V)"
    case .hand: "Move around the board (H, or hold Space)"
    case .note: "Sticky note (N)"
    case .text: "Text (T)"
    case .rectangle: "Rectangle (R)"
    case .ellipse: "Ellipse (O)"
    case .diamond: "Diamond (D)"
    case .frame: "Frame: a titled area that carries what is inside it (F)"
    case .arrow: "Arrow: drag from one thing to another (A)"
    case .ask: "Draw a box around part of the board and ask AI about it"
    }
  }

  /// The kind of item this tool makes, if it makes one by clicking or dragging on the board.
  var makes: (kind: BoardItem.Kind, shape: BoardItem.Shape?)? {
    switch self {
    case .note: (.note, nil)
    case .text: (.text, nil)
    case .rectangle: (.shape, .rectangle)
    case .ellipse: (.shape, .ellipse)
    case .diamond: (.shape, .diamond)
    case .frame: (.frame, nil)
    case .select, .hand, .arrow, .ask: nil
    }
  }
}

extension BoardItem.Tint {
  /// Sticky-note paper. Pastel on every theme, like real notes, so dark text always reads.
  var paper: Color {
    switch self {
    case .yellow: Color(red: 0.969, green: 0.851, blue: 0.463)
    case .green: Color(red: 0.663, green: 0.875, blue: 0.651)
    case .blue: Color(red: 0.624, green: 0.816, blue: 0.949)
    case .pink: Color(red: 0.957, green: 0.686, blue: 0.776)
    case .orange: Color(red: 0.973, green: 0.737, blue: 0.541)
    case .purple: Color(red: 0.788, green: 0.722, blue: 0.949)
    case .grey: Color(red: 0.871, green: 0.859, blue: 0.824)
    }
  }
}

/// The board on screen: its items, what is selected, the camera and the undo history.
@MainActor
final class BoardModel: ObservableObject {
  @Published var board = Whiteboard()
  @Published var selection: Set<String> = []
  @Published var tool: BoardTool = .select
  @Published var editingID: String?
  @Published var draft = ""
  /// Screen point = board point × scale + offset.
  @Published var scale: CGFloat = 1
  @Published var offset: CGSize = CGSize(width: 80, height: 80)
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published var saveError: String?
  var viewSize: CGSize = .zero
  var save: ((Whiteboard) throws -> Void)?
  private var undoStack: [Whiteboard] = []
  private var redoStack: [Whiteboard] = []

  static let scaleRange: ClosedRange<CGFloat> = 0.15...3

  // MARK: Changes

  /// Makes a change the person can undo, and saves it.
  func mutate(_ change: (inout Whiteboard) -> Void) {
    var next = board
    change(&next)
    guard next != board else { return }
    remember(board)
    board = next
    persist()
  }

  /// Takes in what is on disk after an agent changed it. The earlier board stays in the undo
  /// history, so Undo steps back over what the agent did.
  func adopt(_ fresh: Whiteboard) {
    guard fresh != board else { return }
    if !board.items.isEmpty || !undoStack.isEmpty { remember(board) }
    board = fresh
    selection = selection.filter { fresh.item($0) != nil }
    if let editingID, fresh.item(editingID) == nil { self.editingID = nil }
  }

  private func remember(_ previous: Whiteboard) {
    undoStack.append(previous)
    if undoStack.count > 120 { undoStack.removeFirst() }
    redoStack.removeAll()
    canUndo = true
    canRedo = false
  }

  func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(board)
    restore(previous)
  }

  func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(board)
    restore(next)
  }

  private func restore(_ state: Whiteboard) {
    // Ids only ever go up, so an undone item's id is never handed out again.
    var state = state
    state.counter = max(state.counter, board.counter)
    // Undo steps over what is on the board, not over whether it is kept fresh.
    state.automationID = board.automationID
    board = state
    selection = selection.filter { state.item($0) != nil }
    editingID = nil
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
    persist()
  }

  private func persist() {
    do {
      try save?(board)
      saveError = nil
    } catch {
      saveError = "Couldn’t save: \(error.localizedDescription)"
    }
  }

  // MARK: Camera

  func boardPoint(_ screen: CGPoint) -> CGPoint {
    CGPoint(x: (screen.x - offset.width) / scale, y: (screen.y - offset.height) / scale)
  }

  func screenRect(_ rect: CGRect) -> CGRect {
    CGRect(
      x: rect.minX * scale + offset.width, y: rect.minY * scale + offset.height,
      width: rect.width * scale, height: rect.height * scale)
  }

  func boardRect(_ screen: CGRect) -> CGRect {
    let origin = boardPoint(screen.origin)
    return CGRect(
      x: origin.x, y: origin.y, width: screen.width / scale, height: screen.height / scale)
  }

  func pan(by delta: CGSize) {
    offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
  }

  /// Zooms keeping the board point under `anchor` (a screen point) where it is.
  func zoom(to target: CGFloat, around anchor: CGPoint? = nil) {
    let next = min(max(target, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
    let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    let fixed = boardPoint(anchor)
    scale = next
    offset = CGSize(width: anchor.x - fixed.x * next, height: anchor.y - fixed.y * next)
  }

  /// Shows the whole board, never enlarging past actual size.
  func fit() {
    guard let bounds = board.bounds, viewSize.width > 80, viewSize.height > 80 else {
      scale = 1
      offset = CGSize(width: 80, height: 80)
      return
    }
    let margin: CGFloat = 56
    let fitted = min(
      (viewSize.width - margin * 2) / max(bounds.width, 1),
      (viewSize.height - margin * 2) / max(bounds.height, 1))
    scale = min(max(fitted, Self.scaleRange.lowerBound), 1)
    offset = CGSize(
      width: (viewSize.width - bounds.width * scale) / 2 - bounds.minX * scale,
      height: (viewSize.height - bounds.height * scale) / 2 - bounds.minY * scale)
  }

  // MARK: Items

  /// What moves when the selection is dragged: the selection, plus whatever sits in a
  /// selected frame.
  func carried(by ids: Set<String>) -> Set<String> {
    var all = ids
    let frames = Set(ids.filter { board.item($0)?.kind == .frame })
    guard !frames.isEmpty else { return all }
    for item in board.items {
      if let frame = board.frame(containing: item), frames.contains(frame.id) {
        all.insert(item.id)
      }
    }
    return all
  }

  /// The topmost thing under a board point, for joining arrows. Frames only when nothing
  /// else is there.
  func item(at point: CGPoint, excluding: String? = nil) -> BoardItem? {
    let hit = board.items.reversed().filter {
      $0.kind != .arrow && $0.id != excluding && $0.rect.contains(point)
    }
    return hit.first { $0.kind != .frame } ?? hit.first
  }

  @discardableResult
  func add(
    _ kind: BoardItem.Kind, shape: BoardItem.Shape? = nil, rect: CGRect? = nil,
    centredAt centre: CGPoint? = nil, tint: BoardItem.Tint? = nil
  ) -> String {
    var id = ""
    mutate { board in
      id = board.issueID()
      var item = BoardItem(id: id, kind: kind, tint: tint, shape: shape)
      if let rect {
        item.x = rect.minX
        item.y = rect.minY
        item.w = max(rect.width, item.minimumSize.width)
        item.h = max(rect.height, item.minimumSize.height)
      } else if let centre {
        item.x = (centre.x - item.w / 2).rounded()
        item.y = (centre.y - item.h / 2).rounded()
      }
      board.items.append(item)
    }
    selection = [id]
    return id
  }

  func beginEditing(_ id: String) {
    guard let item = board.item(id) else { return }
    commitEditing()
    draft = item.text
    editingID = id
    selection = [id]
  }

  func commitEditing() {
    guard let id = editingID else { return }
    editingID = nil
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    mutate { board in
      guard let index = board.index(of: id) else { return }
      // A text label nobody typed into is not worth keeping.
      if text.isEmpty, board.items[index].kind == .text {
        board.remove([id])
      } else {
        board.items[index].text = text
      }
    }
    selection = selection.filter { board.item($0) != nil }
  }

  func deleteSelection() {
    guard !selection.isEmpty else { return }
    let ids = selection
    mutate { $0.remove(ids) }
    selection = []
  }

  func duplicateSelection() {
    let chosen = board.items.filter { selection.contains($0.id) }
    guard !chosen.isEmpty else { return }
    var fresh: Set<String> = []
    mutate { board in
      var renamed: [String: String] = [:]
      for item in chosen where item.kind != .arrow {
        var copy = item
        copy.id = board.issueID()
        copy.x += 24
        copy.y += 24
        renamed[item.id] = copy.id
        board.items.append(copy)
        fresh.insert(copy.id)
      }
      // An arrow comes along only when both things it joins were copied too.
      for arrow in chosen where arrow.kind == .arrow {
        var copy = arrow
        if let from = arrow.from {
          guard let mapped = renamed[from] else { continue }
          copy.from = mapped
        }
        if let to = arrow.to {
          guard let mapped = renamed[to] else { continue }
          copy.to = mapped
        }
        copy.id = board.issueID()
        copy.x += 24
        copy.y += 24
        board.items.append(copy)
        fresh.insert(copy.id)
      }
    }
    if !fresh.isEmpty { selection = fresh }
  }

  func recolour(_ ids: Set<String>, _ tint: BoardItem.Tint) {
    mutate { board in
      for index in board.items.indices
      where ids.contains(board.items[index].id) && board.items[index].kind != .arrow {
        board.items[index].tint = tint
      }
    }
  }

  func reorder(_ ids: Set<String>, toFront: Bool) {
    mutate { board in
      let moving = board.items.filter { ids.contains($0.id) }
      let rest = board.items.filter { !ids.contains($0.id) }
      board.items = toFront ? rest + moving : moving + rest
    }
  }
}

/// A whiteboard: sticky notes, text, shapes, frames and arrows on an endless surface. Agents
/// place things with the board tools; what they touched glows until cleared, and drawing a box
/// with the Ask tool asks AI about just that part.
struct BoardEditorView: View {
  @ObservedObject var office: OfficeStore
  let services: ApplicationServices
  let file: OfficeFile
  let ask: (OfficeAsk) -> Void
  let bots: [(id: UUID, name: String)]
  /// Starts real work on a note: a fresh session or a bot's own chat. Nil where that is not
  /// possible, which hides the hand-off menu.
  var delegate: BoardDelegate?
  /// How the session a note was handed to is doing right now.
  var agentStatus: (UUID) -> NodeStatus? = { _ in nil }
  var openAgent: (UUID) -> Void = { _ in }
  /// Tells the side chat what is selected, so "change these" means something to the agent.
  var selected: BoardSelection?
  @Environment(\.ottoPalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var model = BoardModel()
  @State private var loaded = false
  @State private var loadError: String?
  /// How far the selection has been dragged so far, in board points.
  @State private var dragOffset: CGSize = .zero
  @State private var dragging: Set<String> = []
  @State private var resizing: (id: String, size: CGSize)?
  /// The box being drawn on the empty board, in screen points.
  @State private var marquee: CGRect?
  /// An arrow being drawn: where it starts (an item or a board point) and where the pointer is.
  @State private var arrowDraft: (from: String?, start: CGPoint, end: CGPoint)?
  @State private var panStart: CGSize?
  @State private var spaceHeld = false
  @State private var lastTap: (id: String?, at: Date) = (nil, .distantPast)
  @FocusState private var boardFocused: Bool
  @FocusState private var textFocused: Bool

  private var touched: Set<String> { office.agentTouched[file.path] ?? [] }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().overlay(palette.paper.opacity(0.08))
      GeometryReader { geometry in
        surface
          .onAppear {
            model.viewSize = geometry.size
            load()
          }
          .onChange(of: geometry.size) { _, size in model.viewSize = size }
      }
      Divider().overlay(palette.paper.opacity(0.08))
      statusBar
    }
    // On artwork themes the pane behind is the painting itself. A board needs a calm surface
    // for frames, arrows and the dot grid to read, as the sheet and document editors have.
    .background(palette.surface.opacity(0.92))
    .onChange(of: office.revisions[file.path]) { _, _ in reloadFromDisk() }
    .onChange(of: textFocused) { _, focused in
      if !focused { model.commitEditing() }
    }
    .onDisappear {
      model.commitEditing()
      selected?.quote = nil
    }
    .onChange(of: model.selection) { _, _ in shareSelection() }
    .onChange(of: model.board) { _, _ in shareSelection() }
    #if DEBUG
      .onReceive(NotificationCenter.default.publisher(for: OttoDevProbe.boardNotification)) {
        note in
        probe(note.object as? String ?? "")
      }
    #endif
  }

  #if DEBUG
    /// Development only: runs the same hand-off the right-click menu does, for agent shells
    /// that cannot click. `give:<item id>:<Claude Code | Codex | bot name>`.
    private func probe(_ command: String) {
      let parts = command.split(separator: ":", maxSplits: 2).map(String.init)
      guard parts.count == 3, parts[0] == "give", let item = model.board.item(parts[1]) else {
        OttoDevProbe.log("board probe: no such item or command: \(command)")
        return
      }
      if let provider = AgentProvider.allCases.first(where: { $0.rawValue == parts[2] }) {
        give(item, to: .provider(provider), name: provider.rawValue)
      } else if let bot = bots.first(where: { $0.name == parts[2] }) {
        give(item, to: .bot(bot.id), name: bot.name)
      } else {
        OttoDevProbe.log("board probe: no agent called \(parts[2])")
        return
      }
      OttoDevProbe.log("board probe: gave \(item.id) to \(parts[2]) delegate=\(delegate != nil)")
    }
  #endif

  private func shareSelection() {
    let items = model.board.items.filter { model.selection.contains($0.id) }
    selected?.quote =
      items.isEmpty
      ? nil : "Selected on the whiteboard “\(file.title)”:\n" + model.board.listing(items)
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 6) {
      HStack(spacing: 2) {
        ForEach(BoardTool.allCases.filter { $0 != .ask }) { tool in toolButton(tool) }
      }
      .padding(3)
      .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
      Button {
        model.tool = model.tool == .ask ? .select : .ask
      } label: {
        Label("Ask about an area", systemImage: "sparkles")
          .font(.ottoDisplay(12).weight(.medium))
          .foregroundStyle(model.tool == .ask ? palette.ink : palette.signal)
          .padding(.horizontal, 10)
          .frame(height: 28)
          .background(
            model.tool == .ask ? palette.signal : palette.signal.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .help(BoardTool.ask.help)
      .accessibilityIdentifier("board.tool.ask")
      if !model.selection.isEmpty {
        Divider().frame(height: 18).overlay(palette.paper.opacity(0.1)).padding(.horizontal, 4)
        swatches
        iconButton("square.on.square", help: "Duplicate (⌘D)") { model.duplicateSelection() }
        iconButton("trash", help: "Delete") { model.deleteSelection() }
      }
      Spacer(minLength: 8)
      freshControl
      if !touched.isEmpty {
        Button("Clear AI highlights") { office.clearTouched(path: file.path) }
          .buttonStyle(.plain)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.signal)
      }
      iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", enabled: model.canUndo) {
        model.undo()
      }
      iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", enabled: model.canRedo) {
        model.redo()
      }
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
  }

  /// Whether an automation keeps this board up to date, and the way to set one up.
  @ViewBuilder private var freshControl: some View {
    if let routine = model.board.automationID.flatMap({ services.routines.routine(id: $0) }) {
      Menu {
        Text(routine.enabled ? "Updates on \(routine.trigger.summary)" : "Paused in Automations")
        Button("Change what it tracks or when…") {
          ask(
            OfficeAsk(
              request:
                "I want to change how this board is kept up to date. Ask me what it should track and how often, then re-schedule it with board.keep_fresh."
            ))
        }
        Divider()
        Button("Stop keeping it fresh", role: .destructive) {
          do { try services.stopKeepingBoardFresh(path: file.path) } catch {
            model.saveError = error.localizedDescription
          }
        }
      } label: {
        Label("Kept fresh", systemImage: "clock.arrow.circlepath")
          .font(.ottoDisplay(11.5).weight(.medium))
          .foregroundStyle(palette.signal)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("An automation keeps this board up to date")
    } else {
      Button {
        ask(
          OfficeAsk(
            request:
              "Keep this board up to date for me on a schedule. If I haven't said what it should track or how often, ask me first, then set it up with board.keep_fresh."
          ))
      } label: {
        Label("Keep fresh", systemImage: "clock.arrow.circlepath")
          .font(.ottoDisplay(11.5))
          .foregroundStyle(palette.paper.opacity(0.72))
      }
      .buttonStyle(.plain)
      .help("Have an agent update this board on a schedule")
    }
  }

  private func toolButton(_ tool: BoardTool) -> some View {
    let active = model.tool == tool
    return Button {
      model.tool = tool
    } label: {
      Image(systemName: tool.symbol)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(active ? palette.ink : palette.paper.opacity(0.82))
        .frame(width: 30, height: 26)
        .background(active ? palette.signal : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(tool.help)
    .accessibilityLabel(tool.help)
    .accessibilityIdentifier("board.tool.\(tool.rawValue)")
  }

  private func iconButton(
    _ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .frame(width: 28, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(palette.paper.opacity(enabled ? 0.82 : 0.28))
    .disabled(!enabled)
    .help(help)
    .accessibilityLabel(help)
  }

  private var swatches: some View {
    HStack(spacing: 5) {
      ForEach(BoardItem.Tint.allCases, id: \.self) { tint in
        Button {
          model.recolour(model.selection, tint)
        } label: {
          Circle().fill(tint.paper)
            .frame(width: 15, height: 15)
            .overlay(Circle().strokeBorder(palette.paper.opacity(0.25), lineWidth: 0.5))
            .frame(width: 20, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tint.rawValue.capitalized)
        .accessibilityLabel("Colour \(tint.rawValue)")
      }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 14) {
      Text("\(model.board.items.count) ITEM\(model.board.items.count == 1 ? "" : "S")")
      if model.selection.count > 1 { Text("\(model.selection.count) SELECTED") }
      if let message = loadError ?? model.saveError {
        Text(message).foregroundStyle(palette.red)
      }
      Spacer()
      Text(
        "DOUBLE-CLICK FOR A NOTE · SCROLL TO MOVE · ⌘ SCROLL OR PINCH TO ZOOM · RIGHT-CLICK TO ASK AI"
      )
    }
    .font(.ottoMicro).tracking(1.4)
    .foregroundStyle(palette.muted)
    .lineLimit(1)
    .padding(.horizontal, 16)
    .frame(height: 28)
  }

  // MARK: Surface

  private var panning: Bool { model.tool == .hand || spaceHeld }

  private var surface: some View {
    ZStack(alignment: .topLeading) {
      BoardDots(scale: model.scale, offset: model.offset, colour: palette.paper.opacity(0.11))
      Color.clear
        .contentShape(Rectangle())
        .gesture(backgroundDrag)
        .onTapGesture { location in backgroundTap(location) }
        .contextMenu { backgroundMenu }
      Group {
        ForEach(model.board.items.filter { $0.kind == .frame }) { item in itemView(item) }
        ForEach(model.board.items.filter { $0.kind == .arrow }) { item in arrowView(item) }
        ForEach(model.board.items.filter { $0.kind != .frame && $0.kind != .arrow }) { item in
          itemView(item)
        }
      }
      .allowsHitTesting(!panning && model.tool != .ask)
      if let arrowDraft {
        BoardArrowShape(
          start: screenPoint(arrowDraft.start), end: screenPoint(arrowDraft.end),
          head: 9 * headScale
        )
        .stroke(palette.signal, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .allowsHitTesting(false)
      }
      if let marquee {
        RoundedRectangle(cornerRadius: 3)
          .fill(palette.signal.opacity(model.tool == .ask ? 0.10 : 0.07))
          .overlay(
            RoundedRectangle(cornerRadius: 3).strokeBorder(
              palette.signal.opacity(0.9),
              style: StrokeStyle(lineWidth: 1, dash: model.tool == .ask ? [5, 4] : []))
          )
          .frame(width: marquee.width, height: marquee.height)
          .position(x: marquee.midX, y: marquee.midY)
          .allowsHitTesting(false)
      }
      if model.board.items.isEmpty { emptyHint }
      zoomControls
    }
    .coordinateSpace(name: "board")
    .clipped()
    .background(palette.ink.opacity(0.10))
    .background(
      BoardScrollCatcher(
        onScroll: { delta in model.pan(by: delta) },
        onZoom: { factor, anchor in model.zoom(to: model.scale * factor, around: anchor) })
    )
    .focusable()
    .focusEffectDisabled()
    .focused($boardFocused)
    .onKeyPress(phases: [.down, .up, .repeat]) { press in handleKey(press) }
  }

  private var headScale: CGFloat { min(max(model.scale, 0.6), 1.6) }

  private func screenPoint(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: point.x * model.scale + model.offset.width,
      y: point.y * model.scale + model.offset.height)
  }

  private var emptyHint: some View {
    VStack(spacing: 8) {
      Image(systemName: "scribble.variable").font(.system(size: 26))
        .foregroundStyle(palette.signal)
        .allowsHitTesting(false)
      Text("An empty board").font(.ottoDisplay(16).weight(.semibold))
        .allowsHitTesting(false)
      Text(
        "Double-click anywhere for a sticky note, start from a layout, or ask AI in the side panel to plan it for you."
      )
      .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
      .allowsHitTesting(false)
      HStack(spacing: 6) {
        ForEach(BoardTemplate.allCases) { template in
          Button {
            model.mutate { board in
              let start = template.board
              board.items = start.items
              board.counter = max(board.counter, start.counter)
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { model.fit() }
          } label: {
            Label(template.title, systemImage: template.symbol)
              .font(.ottoDisplay(12))
              .foregroundStyle(palette.paper.opacity(0.9))
              .padding(.horizontal, 10)
              .frame(height: 28)
              .background(palette.raised.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
              .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(palette.paper.opacity(0.1)))
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("board.template.\(template.rawValue)")
        }
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var zoomControls: some View {
    HStack(spacing: 2) {
      iconButton("minus", help: "Zoom out") { model.zoom(to: model.scale / 1.25) }
      Button {
        model.zoom(to: 1)
      } label: {
        Text("\(Int((model.scale * 100).rounded()))%")
          .font(.ottoMono(10.5, weight: .medium))
          .monospacedDigit()
          .frame(width: 44, height: 26)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.paper.opacity(0.82))
      .help("Actual size")
      iconButton("plus", help: "Zoom in") { model.zoom(to: model.scale * 1.25) }
      iconButton("arrow.up.left.and.arrow.down.right", help: "Fit the whole board") {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { model.fit() }
      }
    }
    .padding(3)
    .background(palette.raised.opacity(0.94), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.paper.opacity(0.1)))
    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  // MARK: Items

  /// Where an item is drawn right now, in board points: its saved place plus any drag or
  /// resize in progress.
  private func liveRect(_ item: BoardItem) -> CGRect {
    var rect = item.rect
    if dragging.contains(item.id) {
      rect.origin.x += dragOffset.width
      rect.origin.y += dragOffset.height
    }
    if let resizing, resizing.id == item.id { rect.size = resizing.size }
    return rect
  }

  /// The board as it looks mid-drag, so arrows follow the things they join.
  private var liveBoard: Whiteboard {
    guard !dragging.isEmpty || resizing != nil else { return model.board }
    var board = model.board
    for index in board.items.indices {
      let rect = liveRect(board.items[index])
      board.items[index].x = rect.minX
      board.items[index].y = rect.minY
      board.items[index].w = rect.width
      board.items[index].h = rect.height
    }
    return board
  }

  private func itemView(_ item: BoardItem) -> some View {
    let rect = model.screenRect(liveRect(item))
    let selected = model.selection.contains(item.id)
    let editing = model.editingID == item.id
    return BoardItemBody(
      item: item, scale: model.scale, palette: palette, selected: selected,
      touched: touched.contains(item.id),
      editor: editing
        ? AnyView(
          TextField("", text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($textFocused)
            .onSubmit { model.commitEditing() }
            .onKeyPress(.escape) {
              model.commitEditing()
              return .handled
            }) : nil
    )
    .frame(width: rect.width, height: rect.height)
    .contentShape(BoardHitShape(kind: item.kind, shape: item.shape, scale: model.scale))
    .overlay(alignment: .bottomLeading) {
      if let chip = chip(for: item), !editing {
        Button {
          if let task = item.task { openAgent(task.agentID) }
        } label: {
          BoardStatusChip(label: chip.label, tone: chip.tone, scale: model.scale, palette: palette)
        }
        .buttonStyle(.plain)
        .padding(8 * model.scale)
        .allowsHitTesting(item.task != nil)
        .help(item.task == nil ? "" : "Open \(item.task?.assignee ?? "")’s session")
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if selected, model.selection.count == 1, !editing { resizeHandle(item) }
    }
    .position(x: rect.midX, y: rect.midY)
    .gesture(itemDrag(item))
    .onTapGesture { itemTap(item) }
    .contextMenu { itemMenu(item) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(item.kind.rawValue.capitalized)\(item.text.isEmpty ? "" : ": \(item.text)")"
    )
    .accessibilityIdentifier("board.item.\(item.id)")
  }

  /// The small label on an item: where its work stands, and who has it when it was handed
  /// to an agent. For handed-off notes the session's live state fills in until it reports back.
  private func chip(for item: BoardItem) -> (label: String, tone: BoardStatusChip.Tone)? {
    guard let task = item.task else {
      guard let status = item.status else { return nil }
      return (status.label, BoardStatusChip.tone(status))
    }
    switch item.status {
    case .done: return ("\(task.assignee) · Done", .good)
    case .blocked: return ("\(task.assignee) · Blocked", .bad)
    default: break
    }
    switch agentStatus(task.agentID) {
    case .working, .starting: return ("\(task.assignee) · Working", .working)
    case .waiting: return ("\(task.assignee) · Needs you", .attention)
    case .failed: return ("\(task.assignee) · Failed", .bad)
    case .stopped: return ("\(task.assignee) · Stopped", .quiet)
    case .idle, .done: return ("\(task.assignee) · Replied", .attention)
    case nil: return (task.assignee, .quiet)
    }
  }

  /// Hands a note to an agent or bot as real work and marks the note with who has it.
  private func give(_ item: BoardItem, to target: AssistantTarget, name: String) {
    guard let delegate else { return }
    model.commitEditing()
    let text = (model.board.item(item.id)?.text ?? item.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      model.saveError = "Write what needs doing on the note first."
      return
    }
    let place = model.board.frame(containing: item).map { " (under “\($0.text)”)" } ?? ""
    let message =
      text.replacingOccurrences(of: "\n", with: " · ")
      + "\n\nFrom my whiteboard “\(file.title)”\(place)."
    let brief = ApplicationServices.boardTaskBrief(boardTitle: file.title, itemID: item.id)
    Task {
      do {
        let agentID = try await delegate(target, message, brief)
        model.mutate { board in
          guard let index = board.index(of: item.id) else { return }
          board.items[index].task = BoardItem.Task(agentID: agentID, assignee: name)
          // The agent may already have reported back by the time the launch returns.
          if board.items[index].status == nil || board.items[index].status == .todo {
            board.items[index].status = .doing
          }
        }
        model.saveError = nil
      } catch {
        model.saveError = "Couldn’t hand it over: \(error.localizedDescription)"
      }
    }
  }

  private func setStatus(_ ids: Set<String>, _ status: BoardItem.Status?) {
    model.mutate { board in
      for index in board.items.indices
      where ids.contains(board.items[index].id) && board.items[index].kind != .arrow {
        board.items[index].status = status
      }
    }
  }

  private func resizeHandle(_ item: BoardItem) -> some View {
    Circle().fill(palette.signal)
      .frame(width: 11, height: 11)
      .overlay(Circle().strokeBorder(palette.ink.opacity(0.7), lineWidth: 1.5))
      .frame(width: 26, height: 26)
      .contentShape(Rectangle())
      .offset(x: 10, y: 10)
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named("board"))
          .onChanged { value in
            let minimum = item.minimumSize
            resizing = (
              item.id,
              CGSize(
                width: max(minimum.width, item.w + value.translation.width / model.scale),
                height: max(minimum.height, item.h + value.translation.height / model.scale))
            )
          }
          .onEnded { _ in
            guard let size = resizing?.size else { return }
            resizing = nil
            model.mutate { board in
              guard let index = board.index(of: item.id) else { return }
              board.items[index].w = size.width.rounded()
              board.items[index].h = size.height.rounded()
            }
          }
      )
      .help("Drag to resize")
  }

  private func arrowView(_ arrow: BoardItem) -> some View {
    let board = liveBoard
    let selected = model.selection.contains(arrow.id)
    let glow = touched.contains(arrow.id)
    return Group {
      if let ends = board.arrowEnds(arrow) {
        let start = screenPoint(ends.start)
        let end = screenPoint(ends.end)
        let shape = BoardArrowShape(start: start, end: end, head: 9 * headScale)
        ZStack {
          shape
            .stroke(
              selected || glow ? palette.signal : palette.paper.opacity(0.62),
              style: StrokeStyle(
                lineWidth: selected ? 2.4 : 1.7, lineCap: .round, lineJoin: .round)
            )
            .contentShape(shape.stroke(style: StrokeStyle(lineWidth: 16, lineCap: .round)))
            .gesture(itemDrag(arrow))
            .onTapGesture { itemTap(arrow) }
            .contextMenu { itemMenu(arrow) }
          if model.editingID == arrow.id {
            TextField("Label", text: $model.draft)
              .textFieldStyle(.plain)
              .font(.ottoDisplay(max(9, 11.5 * model.scale)))
              .multilineTextAlignment(.center)
              .focused($textFocused)
              .onSubmit { model.commitEditing() }
              .frame(width: 140)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(palette.surface, in: Capsule())
              .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
          } else if !arrow.text.isEmpty {
            Text(arrow.text)
              .font(.ottoDisplay(max(8, 11.5 * model.scale)))
              .foregroundStyle(palette.paper.opacity(0.9))
              .lineLimit(1)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(palette.surface, in: Capsule())
              .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
              .allowsHitTesting(false)
          }
        }
      }
    }
    .accessibilityIdentifier("board.item.\(arrow.id)")
  }

  // MARK: Gestures

  private func itemTap(_ item: BoardItem) {
    boardFocused = true
    let now = Date()
    let isDouble = lastTap.id == item.id && now.timeIntervalSince(lastTap.at) < 0.4
    lastTap = (item.id, now)
    if isDouble {
      model.beginEditing(item.id)
      focusText()
      return
    }
    if model.editingID != nil, model.editingID != item.id { model.commitEditing() }
    if NSEvent.modifierFlags.contains(.shift) {
      if model.selection.contains(item.id) {
        model.selection.remove(item.id)
      } else {
        model.selection.insert(item.id)
      }
    } else {
      model.selection = [item.id]
    }
  }

  private func focusText() {
    DispatchQueue.main.async { textFocused = true }
  }

  private func itemDrag(_ item: BoardItem) -> some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
      .onChanged { value in
        boardFocused = true
        if model.tool == .arrow {
          let start =
            item.kind == .arrow
            ? model.boardPoint(value.startLocation)
            : CGPoint(x: item.rect.midX, y: item.rect.midY)
          arrowDraft = (
            item.kind == .arrow ? nil : item.id, start, model.boardPoint(value.location)
          )
          return
        }
        guard model.editingID != item.id else { return }
        if dragging.isEmpty {
          if !model.selection.contains(item.id) { model.selection = [item.id] }
          dragging = model.carried(by: model.selection)
        }
        dragOffset = CGSize(
          width: value.translation.width / model.scale,
          height: value.translation.height / model.scale)
      }
      .onEnded { value in
        if model.tool == .arrow {
          finishArrow(at: model.boardPoint(value.location))
          return
        }
        let moved = dragging
        let delta = CGSize(width: dragOffset.width.rounded(), height: dragOffset.height.rounded())
        dragging = []
        dragOffset = .zero
        guard !moved.isEmpty, delta != .zero else { return }
        model.mutate { board in
          for index in board.items.indices where moved.contains(board.items[index].id) {
            let item = board.items[index]
            // A joined arrow follows its ends; only a free end has a place to move.
            if item.kind == .arrow, item.from != nil, item.to != nil { continue }
            board.items[index].x += delta.width
            board.items[index].y += delta.height
          }
        }
      }
  }

  private func finishArrow(at point: CGPoint) {
    guard let draft = arrowDraft else { return }
    arrowDraft = nil
    let target = model.item(at: point, excluding: draft.from)
    // Too short to be meant, unless it lands on something.
    let length = hypot(point.x - draft.start.x, point.y - draft.start.y)
    guard target != nil || length > 24 else { return }
    var id = ""
    model.mutate { board in
      id = board.issueID()
      var arrow = BoardItem(id: id, kind: .arrow, from: draft.from, to: target?.id)
      arrow.x = draft.start.x.rounded()
      arrow.y = draft.start.y.rounded()
      arrow.w = (point.x - draft.start.x).rounded()
      arrow.h = (point.y - draft.start.y).rounded()
      board.items.append(arrow)
    }
    model.selection = [id]
    model.tool = .select
  }

  private var backgroundDrag: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("board"))
      .onChanged { value in
        boardFocused = true
        if panning {
          let start = panStart ?? model.offset
          panStart = start
          model.offset = CGSize(
            width: start.width + value.translation.width,
            height: start.height + value.translation.height)
          return
        }
        if model.tool == .arrow {
          arrowDraft = (
            nil, model.boardPoint(value.startLocation), model.boardPoint(value.location)
          )
          return
        }
        marquee = CGRect(
          x: min(value.startLocation.x, value.location.x),
          y: min(value.startLocation.y, value.location.y),
          width: abs(value.location.x - value.startLocation.x),
          height: abs(value.location.y - value.startLocation.y))
      }
      .onEnded { value in
        if panStart != nil {
          panStart = nil
          return
        }
        if model.tool == .arrow {
          finishArrow(at: model.boardPoint(value.location))
          return
        }
        guard let box = marquee else { return }
        marquee = nil
        let area = model.boardRect(box)
        if let makes = model.tool.makes {
          let id = model.add(makes.kind, shape: makes.shape, rect: area)
          model.tool = .select
          beginEditingNew(id)
          return
        }
        let inside = model.board.items(in: area)
        if model.tool == .ask {
          model.tool = .select
          model.selection = Set(inside.map(\.id))
          guard !inside.isEmpty else { return }
          ask(OfficeAsk(quote: quote(for: inside, boxed: true)))
          return
        }
        let ids = Set(inside.map(\.id))
        model.selection =
          NSEvent.modifierFlags.contains(.shift) ? model.selection.union(ids) : ids
      }
  }

  private func beginEditingNew(_ id: String) {
    model.beginEditing(id)
    focusText()
  }

  private func backgroundTap(_ location: CGPoint) {
    boardFocused = true
    model.commitEditing()
    let point = model.boardPoint(location)
    if let makes = model.tool.makes {
      let id = model.add(makes.kind, shape: makes.shape, centredAt: point)
      model.tool = .select
      beginEditingNew(id)
      return
    }
    let now = Date()
    let isDouble = lastTap.id == nil && now.timeIntervalSince(lastTap.at) < 0.4
    lastTap = (nil, isDouble ? .distantPast : now)
    if isDouble, model.tool == .select {
      let id = model.add(.note, centredAt: point)
      beginEditingNew(id)
      return
    }
    if !NSEvent.modifierFlags.contains(.shift) { model.selection = [] }
  }

  private func handleKey(_ press: KeyPress) -> KeyPress.Result {
    guard model.editingID == nil else { return .ignored }
    if press.key == .space {
      spaceHeld = press.phase != .up
      return .handled
    }
    guard press.phase != .up else { return .ignored }
    let command = press.modifiers.contains(.command)
    switch press.key {
    case .delete, .deleteForward:
      model.deleteSelection()
      return .handled
    case .escape:
      model.selection = []
      model.tool = .select
      marquee = nil
      arrowDraft = nil
      return .handled
    case .return:
      guard model.selection.count == 1, let id = model.selection.first else { return .ignored }
      model.beginEditing(id)
      focusText()
      return .handled
    case .leftArrow, .rightArrow, .upArrow, .downArrow:
      guard !model.selection.isEmpty else { return .ignored }
      let step: Double = press.modifiers.contains(.shift) ? 20 : 4
      let delta: (Double, Double) =
        switch press.key {
        case .leftArrow: (-step, 0)
        case .rightArrow: (step, 0)
        case .upArrow: (0, -step)
        default: (0, step)
        }
      let moving = model.carried(by: model.selection)
      model.mutate { board in
        for index in board.items.indices where moving.contains(board.items[index].id) {
          board.items[index].x += delta.0
          board.items[index].y += delta.1
        }
      }
      return .handled
    default: break
    }
    let character = press.characters.lowercased()
    if command {
      switch character {
      case "z":
        if press.modifiers.contains(.shift) { model.redo() } else { model.undo() }
        return .handled
      case "a":
        model.selection = Set(model.board.items.map(\.id))
        return .handled
      case "d":
        model.duplicateSelection()
        return .handled
      case "0":
        model.fit()
        return .handled
      case "=", "+":
        model.zoom(to: model.scale * 1.25)
        return .handled
      case "-":
        model.zoom(to: model.scale / 1.25)
        return .handled
      default: return .ignored
      }
    }
    guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
    let tools: [String: BoardTool] = [
      "v": .select, "h": .hand, "n": .note, "t": .text, "r": .rectangle, "o": .ellipse,
      "d": .diamond, "f": .frame, "a": .arrow,
    ]
    if let tool = tools[character] {
      model.tool = tool
      return .handled
    }
    return .ignored
  }

  // MARK: Menus and asking

  /// What an agent is told about the chosen items: their ids, places and text.
  private func quote(for items: [BoardItem], boxed: Bool = false) -> String {
    let lead =
      boxed
      ? "The area I boxed on the whiteboard “\(file.title)” holds:"
      : "On the whiteboard “\(file.title)”:"
    return lead + "\n" + model.board.listing(items)
  }

  private func chosen(_ item: BoardItem) -> [BoardItem] {
    let ids = model.selection.contains(item.id) ? model.selection : [item.id]
    return model.board.items.filter { ids.contains($0.id) }
  }

  @ViewBuilder private func itemMenu(_ item: BoardItem) -> some View {
    let items = chosen(item)
    let ids = Set(items.map(\.id))
    let noun = items.count == 1 ? "this" : "these \(items.count)"
    Button("Ask AI about \(noun)…", systemImage: "sparkles") {
      ask(OfficeAsk(quote: quote(for: items)))
    }
    if items.count > 1 {
      Button("Group by theme") {
        ask(
          OfficeAsk(
            quote: quote(for: items),
            request:
              "Group these by theme: put each group in its own titled frame, one colour per group, tidy on a grid, with board.update and board.add."
          ))
      }
      Button("Turn into action items") {
        ask(
          OfficeAsk(
            quote: quote(for: items),
            request:
              "Turn these into clear action items on the board, each with an owner and a date where I gave one, in a frame called Actions."
          ))
      }
    } else if item.kind != .arrow {
      Button("Break this down") {
        ask(
          OfficeAsk(
            quote: quote(for: items),
            request: "Break this into its next steps as notes beside it, joined with arrows."))
      }
    }
    if !bots.isEmpty {
      Menu("Ask a bot") {
        ForEach(bots, id: \.id) { bot in
          Button(bot.name) { ask(OfficeAsk(quote: quote(for: items), bot: bot.id)) }
        }
      }
    }
    Divider()
    if delegate != nil, items.count == 1, item.kind == .note || item.kind == .shape {
      Menu("Give this to…") {
        ForEach([AgentProvider.claudeCode, .codex], id: \.self) { provider in
          Button("A new \(provider.rawValue) session") {
            give(item, to: .provider(provider), name: provider.rawValue)
          }
        }
        if !bots.isEmpty {
          Divider()
          ForEach(bots, id: \.id) { bot in
            Button(bot.name) { give(item, to: .bot(bot.id), name: bot.name) }
          }
        }
      }
    }
    if let task = item.task, items.count == 1 {
      Button("Open \(task.assignee)’s session") { openAgent(task.agentID) }
    }
    if item.kind != .arrow || items.count > 1 {
      Menu("Status") {
        ForEach(BoardItem.Status.allCases, id: \.self) { status in
          Button(status.label) { setStatus(ids, status) }
        }
        Divider()
        Button("None") { setStatus(ids, nil) }
      }
    }
    if item.kind != .arrow || items.count > 1 {
      Menu("Colour") {
        ForEach(BoardItem.Tint.allCases, id: \.self) { tint in
          Button(tint.rawValue.capitalized) { model.recolour(ids, tint) }
        }
      }
    }
    Button(item.kind == .arrow ? "Edit label" : "Edit text") {
      model.beginEditing(item.id)
      focusText()
    }
    Button("Duplicate") {
      model.selection = ids
      model.duplicateSelection()
    }
    Button("Bring to front") { model.reorder(ids, toFront: true) }
    Button("Send to back") { model.reorder(ids, toFront: false) }
    Divider()
    Button("Delete", role: .destructive) {
      model.selection = ids
      model.deleteSelection()
    }
  }

  @ViewBuilder private var backgroundMenu: some View {
    Button("Ask AI about the whole board…", systemImage: "sparkles") {
      ask(OfficeAsk(quote: nil))
    }
    Button("Tidy the board") {
      ask(
        OfficeAsk(
          request:
            "Tidy this board with board.update: line things up on a grid, stop anything overlapping, keep related notes together and keep every frame's contents inside it."
        ))
    }
    Divider()
    Button("Select all") { model.selection = Set(model.board.items.map(\.id)) }
    Button("Fit the whole board") { model.fit() }
  }

  // MARK: Loading

  private func load() {
    guard !loaded else { return }
    loaded = true
    let path = file.path
    model.save = { [weak office] board in try office?.saveBoard(board, path: path) }
    do {
      model.board = try office.loadBoard(path: file.path)
      loadError = nil
    } catch {
      loadError = "Couldn’t open: \(error.localizedDescription)"
    }
    model.fit()
    boardFocused = true
  }

  private func reloadFromDisk() {
    do {
      let wasEmpty = model.board.items.isEmpty
      model.adopt(try office.loadBoard(path: file.path))
      loadError = nil
      // The first things an agent puts on an empty board should be in view.
      if wasEmpty, !model.board.items.isEmpty {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { model.fit() }
      }
    } catch {
      loadError = "Couldn’t open: \(error.localizedDescription)"
    }
  }
}

// MARK: - Drawing

/// One item's look, without its place or gestures, so the board and its picture export share it.
struct BoardItemBody: View {
  let item: BoardItem
  let scale: CGFloat
  let palette: OttoPalette
  var selected = false
  var touched = false
  /// The text field shown in place of the words while the person is typing.
  var editor: AnyView?

  private static var noteInk: Color { Color(red: 0.11, green: 0.11, blue: 0.10) }

  var body: some View {
    let ring = selected || touched
    // Selection is a firm ring; something an agent changed gets a quieter one.
    let ringColour = selected ? palette.signal : palette.signal.opacity(0.55)
    let ringWidth: CGFloat = selected ? 2 : 1.2
    switch item.kind {
    case .note:
      let shape = RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
      label(
        size: 13, weight: .medium, colour: Self.noteInk, alignment: .topLeading,
        padding: 12
      )
      .background((item.tint ?? .yellow).paper, in: shape)
      .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
      .overlay(shape.strokeBorder(ringColour, lineWidth: ring ? ringWidth : 0).padding(-2))
      .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.24), radius: 9 * scale, y: 5 * scale)
    case .text:
      label(
        size: min(max(item.h * 0.45, 12), 72), weight: .semibold, colour: palette.paper,
        alignment: .leading, padding: 4
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4).strokeBorder(ringColour, lineWidth: selected ? 1.5 : 0)
      )
    case .shape:
      let outline = item.tint?.paper ?? palette.paper.opacity(0.6)
      let fill = item.tint.map { $0.paper.opacity(0.18) } ?? palette.raised.opacity(0.72)
      let shape = BoardOutline(shape: item.shape ?? .rectangle, radius: 9 * scale)
      label(
        size: 13, weight: .medium, colour: palette.paper, alignment: .center,
        padding: item.shape == .rectangle || item.shape == nil ? 10 : 22
      )
      .background(shape.fill(fill))
      .overlay(shape.stroke(ring ? ringColour : outline, lineWidth: selected ? 2 : 1.5))
    case .frame:
      let shape = RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
      ZStack(alignment: .topLeading) {
        shape.fill(palette.paper.opacity(0.035))
        shape.strokeBorder(
          ring ? ringColour : palette.paper.opacity(0.16), lineWidth: selected ? 2 : 1)
        label(
          size: 13, weight: .semibold, colour: palette.paper.opacity(0.86),
          alignment: .topLeading, padding: 14, placeholder: "Untitled frame", minimum: 11
        )
        .frame(height: max(34, 40 * scale), alignment: .topLeading)
      }
    case .arrow:
      EmptyView()
    }
  }

  @ViewBuilder
  private func label(
    size: Double, weight: Font.Weight, colour: Color, alignment: Alignment, padding: Double,
    placeholder: String = "", minimum: Double = 4
  ) -> some View {
    // A frame's title stays readable when the board is zoomed out to fit.
    let font = Font.ottoDisplay(max(minimum, size * scale)).weight(weight)
    Group {
      if let editor {
        editor
          .foregroundStyle(colour)
          .tint(colour)
          .multilineTextAlignment(alignment == .center ? .center : .leading)
      } else {
        Text(item.text.isEmpty ? placeholder : item.text)
          .foregroundStyle(item.text.isEmpty ? colour.opacity(0.45) : colour)
          .multilineTextAlignment(alignment == .center ? .center : .leading)
          .minimumScaleFactor(0.55)
      }
    }
    .font(font)
    .lineSpacing(2 * scale)
    .padding(min(padding, padding * max(scale, 0.75)))
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
  }
}

/// What is selected on the open board, as the listing an agent can act on. The side chat sends
/// it along with a message, so the agent knows which items "these" are.
@MainActor
final class BoardSelection: ObservableObject {
  var quote: String?
}

/// Starts work on a note for a target with the note as the message and a hidden brief; returns
/// the session doing it.
typealias BoardDelegate = (
  _ target: AssistantTarget, _ message: String, _ brief: String
) async throws -> UUID

/// The small label on an item saying where its work stands. Dark on every theme so it reads
/// on pastel note paper.
struct BoardStatusChip: View {
  enum Tone { case quiet, working, attention, good, bad }

  let label: String
  let tone: Tone
  let scale: CGFloat
  let palette: OttoPalette

  static func tone(_ status: BoardItem.Status) -> Tone {
    switch status {
    case .todo: .quiet
    case .doing: .working
    case .done: .good
    case .blocked: .bad
    }
  }

  private var dot: Color {
    switch tone {
    case .quiet: Color.white.opacity(0.5)
    case .working: Color(red: 0.96, green: 0.68, blue: 0.30)
    case .attention: Color(red: 0.38, green: 0.80, blue: 0.82)
    case .good: Color(red: 0.47, green: 0.85, blue: 0.52)
    case .bad: Color(red: 0.95, green: 0.42, blue: 0.36)
    }
  }

  var body: some View {
    HStack(spacing: 4 * scale) {
      Circle().fill(dot).frame(width: 6 * scale, height: 6 * scale)
      Text(label)
        .font(.ottoDisplay(max(4, 10.5 * scale)).weight(.semibold))
        .lineLimit(1)
    }
    .foregroundStyle(Color.white.opacity(0.95))
    .padding(.horizontal, 7 * scale)
    .padding(.vertical, 3 * scale)
    .background(Color(red: 0.10, green: 0.10, blue: 0.09).opacity(0.88), in: Capsule())
    .accessibilityLabel(label)
  }
}

/// The outline of a shape item.
struct BoardOutline: Shape {
  let shape: BoardItem.Shape
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    switch shape {
    case .rectangle:
      return Path(roundedRect: rect, cornerRadius: min(radius, min(rect.width, rect.height) / 2))
    case .ellipse:
      return Path(ellipseIn: rect)
    case .diamond:
      var path = Path()
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
      path.closeSubpath()
      return path
    }
  }
}

/// Where an item takes clicks. A frame is held by its title strip and its edge, so dragging
/// across its middle still draws a selection box around what is inside.
struct BoardHitShape: Shape {
  let kind: BoardItem.Kind
  let shape: BoardItem.Shape?
  let scale: CGFloat

  func path(in rect: CGRect) -> Path {
    guard kind == .frame else {
      return BoardOutline(shape: shape ?? .rectangle, radius: 0).path(in: rect)
    }
    let band = max(8, 10 * scale)
    var path = Path()
    path.addRect(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(26, 38 * scale)))
    path.addRect(CGRect(x: rect.minX, y: rect.minY, width: band, height: rect.height))
    path.addRect(CGRect(x: rect.maxX - band, y: rect.minY, width: band, height: rect.height))
    path.addRect(CGRect(x: rect.minX, y: rect.maxY - band, width: rect.width, height: band))
    return path
  }
}

/// A straight arrow with an open head at its end.
struct BoardArrowShape: Shape {
  var start: CGPoint
  var end: CGPoint
  var head: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: start)
    path.addLine(to: end)
    let angle = atan2(end.y - start.y, end.x - start.x)
    guard hypot(end.x - start.x, end.y - start.y) > 1 else { return path }
    for side in [-1.0, 1.0] {
      let wing = angle + .pi + side * 0.42
      path.move(to: end)
      path.addLine(to: CGPoint(x: end.x + cos(wing) * head, y: end.y + sin(wing) * head))
    }
    return path
  }
}

/// The dot grid behind the board. It thins out when zoomed far away so it never turns to noise.
struct BoardDots: View {
  let scale: CGFloat
  let offset: CGSize
  let colour: Color

  var body: some View {
    Canvas { context, size in
      var step = 24 * scale
      while step < 14 { step *= 2 }
      let startX = offset.width.truncatingRemainder(dividingBy: step)
      let startY = offset.height.truncatingRemainder(dividingBy: step)
      var path = Path()
      var y = startY - step
      while y < size.height + step {
        var x = startX - step
        while x < size.width + step {
          path.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
          x += step
        }
        y += step
      }
      context.fill(path, with: .color(colour))
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Scrolling moves the board and ⌘-scroll or a pinch zooms it. SwiftUI has no scroll-wheel
/// handler, so a quiet AppKit view watches the events that land on it.
struct BoardScrollCatcher: NSViewRepresentable {
  let onScroll: (CGSize) -> Void
  let onZoom: (CGFloat, CGPoint) -> Void

  func makeNSView(context: Context) -> CatcherView {
    let view = CatcherView()
    view.onScroll = onScroll
    view.onZoom = onZoom
    return view
  }

  func updateNSView(_ view: CatcherView, context: Context) {
    view.onScroll = onScroll
    view.onZoom = onZoom
  }

  static func dismantleNSView(_ view: CatcherView, coordinator: ()) { view.stop() }

  final class CatcherView: NSView {
    var onScroll: ((CGSize) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    private var monitor: Any?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
        [weak self] event in
        guard let self, self.handles(event) else { return event }
        let point = self.convert(event.locationInWindow, from: nil)
        if event.type == .magnify {
          self.onZoom?(1 + event.magnification, point)
        } else if event.modifierFlags.contains(.command) {
          let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
          self.onZoom?(exp(amount * 0.01), point)
        } else {
          let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
          self.onScroll?(
            CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
        }
        return nil
      }
    }

    private func handles(_ event: NSEvent) -> Bool {
      guard let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return false }
      return bounds.contains(convert(event.locationInWindow, from: nil))
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

// MARK: - Picture export

/// The whole board as a still picture, for sharing.
struct BoardPicture: View {
  let board: Whiteboard
  let palette: OttoPalette

  static let margin: CGFloat = 48

  private var bounds: CGRect { board.bounds ?? CGRect(x: 0, y: 0, width: 480, height: 320) }

  var body: some View {
    let bounds = bounds
    ZStack(alignment: .topLeading) {
      palette.surface
      ForEach(board.items.filter { $0.kind == .frame }) { item in placed(item, in: bounds) }
      ForEach(board.items.filter { $0.kind == .arrow }) { arrow in
        if let ends = board.arrowEnds(arrow) {
          let start = shifted(ends.start, in: bounds)
          let end = shifted(ends.end, in: bounds)
          BoardArrowShape(start: start, end: end, head: 9)
            .stroke(
              palette.paper.opacity(0.62),
              style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
          if !arrow.text.isEmpty {
            Text(arrow.text).font(.ottoDisplay(11.5)).foregroundStyle(palette.paper.opacity(0.9))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(palette.surface, in: Capsule())
              .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
          }
        }
      }
      ForEach(board.items.filter { $0.kind != .frame && $0.kind != .arrow }) { item in
        placed(item, in: bounds)
      }
    }
    .frame(width: bounds.width + Self.margin * 2, height: bounds.height + Self.margin * 2)
  }

  private func shifted(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
    CGPoint(x: point.x - bounds.minX + Self.margin, y: point.y - bounds.minY + Self.margin)
  }

  private func placed(_ item: BoardItem, in bounds: CGRect) -> some View {
    let centre = shifted(CGPoint(x: item.rect.midX, y: item.rect.midY), in: bounds)
    return BoardItemBody(item: item, scale: 1, palette: palette)
      .frame(width: item.w, height: item.h)
      .position(x: centre.x, y: centre.y)
  }

  /// A PNG of the board at twice its size, or nil when it cannot be drawn.
  @MainActor
  static func png(_ board: Whiteboard, palette: OttoPalette) -> Data? {
    let renderer = ImageRenderer(
      content: BoardPicture(board: board, palette: palette).environment(\.ottoPalette, palette))
    renderer.scale = 2
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}

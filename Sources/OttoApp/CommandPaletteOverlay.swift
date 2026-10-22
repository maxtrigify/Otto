import AppKit
import OttoModels
import OttoServices
import OttoTools
import SwiftUI

/// Navigation and everyday app actions. Raw tools require the explicit Developer filter.
struct PaletteQuickAction: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let symbol: String
  let keywords: String
  var accent: PaletteAccent = .signal
  var agentProvider: AgentProvider? = nil
  var searchOnly = false
  let perform: () -> Void
}

/// Per-item icon tint from the design's quick-action palette (agents get provider hues).
enum PaletteAccent {
  case signal, cyan, amber, red

  func color(_ palette: OttoPalette) -> Color {
    switch self {
    case .signal: palette.signal
    case .cyan: palette.cyan
    case .amber: palette.amber
    case .red: palette.red
    }
  }
}

/// The palette's segmented filter chips. Categories follow the quick-action id namespaces.
enum PaletteFilter: String, CaseIterable {
  case all = "All"
  case jump = "Jump to"
  case agents = "Chat"
  case actions = "Actions"
  case developer = "Developer"

  var showsTools: Bool { self == .developer }

  func includes(_ action: PaletteQuickAction, searching: Bool = true) -> Bool {
    guard searching || !action.searchOnly else { return false }
    return switch self {
    case .all: true
    case .jump: action.id.hasPrefix("go.")
    case .agents: action.id.hasPrefix("agent.") || action.id.hasPrefix("bot.")
    case .actions:
      !action.id.hasPrefix("go.") && !action.id.hasPrefix("agent.")
        && !action.id.hasPrefix("bot.")
    case .developer: false
    }
  }

  var next: PaletteFilter {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + 1) % all.count]
  }

  var previous: PaletteFilter {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
  }
}

/// The actions the palette ran most recently lead the list until the first keystroke, the way
/// Fluid Functionalism's CommandMenu seeds its suggestions. Pure and testable.
enum CommandPaletteRecents {
  static let limit = 3

  static func decode(_ raw: String) -> [String] {
    raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
  }

  static func encode(_ ids: [String]) -> String { ids.joined(separator: ",") }

  static func remembering(_ id: String, in ids: [String]) -> [String] {
    Array(([id] + ids.filter { $0 != id }).prefix(limit))
  }
}

/// One field over every action: type, arrow, Enter. The panel keeps its top edge and the
/// field never moves while the rows filter beneath it; the highlight glides between rows
/// under the pointer or the arrow keys and always rests on the first row after a keystroke,
/// so Enter has a target.
struct CommandPaletteOverlay: View {
  @Environment(\.ottoPalette) private var palette
  @Environment(\.ottoMotion) private var motion
  @ObservedObject var services: ApplicationServices
  @ObservedObject var uiState: WorkspaceUIState
  let quickActions: [PaletteQuickAction]
  @State private var definitions: [ToolDefinition] = []
  @State private var query = ""
  @State private var filter: PaletteFilter = .all
  @State private var selection: CommandPaletteItem?
  @State private var input = "{}"
  @State private var result = ""
  @State private var running = false
  @State private var presented = false
  @State private var listHeight: CGFloat = 0
  /// Only keyboard and programmatic moves scroll the list; the pointer never does, or a
  /// hover would drag the rows out from under it.
  @State private var scrollTarget: CommandPaletteItem?
  @AppStorage("otto.commandPalette.recent") private var recentRaw = ""
  @FocusState private var searchFocused: Bool
  @Namespace private var filterSelection

  private static let listCap: CGFloat = 440
  private static let listFloor: CGFloat = 240

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private var matchingActions: [PaletteQuickAction] {
    let needle = trimmedQuery
    let scoped = quickActions.filter { filter.includes($0, searching: !needle.isEmpty) }
    guard !needle.isEmpty else { return scoped }
    return scoped.filter {
      $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        || $0.keywords.lowercased().contains(needle)
    }
  }

  /// Recently run actions lead while nothing is typed and the view is unfiltered.
  private var recentActions: [PaletteQuickAction] {
    guard trimmedQuery.isEmpty, filter == .all else { return [] }
    let ids = CommandPaletteRecents.decode(recentRaw)
    return ids.compactMap { id in quickActions.first { $0.id == id } }
  }

  private var remainingActions: [PaletteQuickAction] {
    let recent = Set(recentActions.map(\.id))
    let rest = matchingActions.filter { !recent.contains($0.id) }
    // Places come first so the list reads the same way the keyboard moves through it.
    return rest.filter { $0.id.hasPrefix("go.") } + rest.filter { !$0.id.hasPrefix("go.") }
  }

  // Internal tools never appear in everyday navigation or search.
  private var matchingTools: [ToolDefinition] {
    guard filter.showsTools else { return [] }
    return CommandPaletteCatalog.actions(from: definitions, matching: query)
  }

  private var listedItems: [CommandPaletteItem] {
    CommandPaletteNavigator.items(
      actionIDs: (recentActions + remainingActions).map(\.id),
      toolNames: matchingTools.map(\.name)
    )
  }

  private var selectedAction: PaletteQuickAction? {
    guard case .action(let id) = selection else { return nil }
    return matchingActions.first { $0.id == id }
  }

  private var selectedTool: ToolDefinition? {
    guard case .tool(let name) = selection else { return nil }
    return matchingTools.first { $0.name == name }
  }

  private var enterHint: String {
    if let action = selectedAction { return action.title }
    if selectedTool != nil { return "Run command" }
    return "Run"
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Blurred ink scrim, matching the design's overlay treatment (ink 32% over blur).
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        .overlay(palette.ink.opacity(0.32).ignoresSafeArea())
        .opacity(presented ? 1 : 0)
        .onTapGesture(perform: close)
      panel
        // Anchored near the top so a panel that grows and shrinks with its rows keeps its
        // top edge, and the field, exactly where the eye already is.
        .padding(.top, 96)
        .opacity(presented ? 1 : 0)
        .scaleEffect(presented ? 1 : 0.97, anchor: .top)
    }
    .animation(motion.presence(.slow, isPresented: presented), value: presented)
    .task {
      presented = true
      definitions = await services.toolDefinitions()
      selectFirstMatch()
      searchFocused = true
    }
    .onChange(of: query) { _, _ in selectFirstMatch() }
    .onChange(of: filter) { _, _ in
      selectFirstMatch()
      searchFocused = true
    }
    .onExitCommand(perform: close)
    .background(PaletteArrowKeyCatcher(onMove: moveSelection, onMoveFilter: moveFilter))
    .accessibilityLabel("Otto command palette")
  }

  private var panel: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: searchFocused ? .bold : .medium))
            .foregroundStyle(searchFocused ? palette.paper : palette.muted)
            .animation(motion.tint, value: searchFocused)
          TextField(filter.showsTools ? "Search developer tools" : "Search Otto", text: $query)
            .textFieldStyle(.plain)
            .font(.ottoDisplay(16))
            .foregroundStyle(palette.paper)
            .focused($searchFocused)
            .onSubmit(runSelection)
            .onKeyPress(.upArrow) {
              moveSelection(-1)
              return .handled
            }
            .onKeyPress(.downArrow) {
              moveSelection(1)
              return .handled
            }
          if !query.isEmpty {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.ottoChrome(cornerRadius: 9))
            .accessibilityLabel("Clear search")
            .transition(.opacity.animation(motion.fade))
          }
          keycap("ESC")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).stroke(palette.paper.opacity(0.1), lineWidth: 1)
        )
        .animation(motion.fade, value: query.isEmpty)
        filterChips
      }
      .padding(.top, 14)
      .padding(.horizontal, 16)
      .padding(.bottom, 10)

      Divider().overlay(palette.paper.opacity(0.06))
      HStack(spacing: 0) {
        ScrollViewReader { proxy in
          ScrollView {
            OttoFluidHover(
              axis: .vertical,
              style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.07), cornerRadius: 8),
              highlight: $selection
            ) {
              VStack(alignment: .leading, spacing: 2) {
                if !recentActions.isEmpty {
                  sectionHeader("Recent")
                  ForEach(recentActions) { action in
                    quickActionRow(action)
                  }
                }
                let jumps = remainingActions.filter { $0.id.hasPrefix("go.") }
                let others = remainingActions.filter { !$0.id.hasPrefix("go.") }
                if !jumps.isEmpty {
                  sectionHeader("Jump to")
                  ForEach(jumps) { action in quickActionRow(action) }
                }
                if !others.isEmpty {
                  sectionHeader(recentActions.isEmpty && jumps.isEmpty ? "Suggestions" : "Actions")
                  ForEach(others) { action in quickActionRow(action) }
                }
                if !matchingTools.isEmpty {
                  sectionHeader("Advanced commands")
                  ForEach(matchingTools, id: \.name) { definition in
                    toolRow(definition)
                  }
                }
                if listedItems.isEmpty {
                  ContentUnavailableView("No matching commands", systemImage: "command")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 12)
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                listHeight = $0
              }
            }
          }
          .ottoScrollChrome(fade: 20)
          .onChange(of: scrollTarget) { _, item in
            guard let item else { return }
            // The row and the highlight travel on the same spring, so they arrive together.
            withAnimation(motion.enter(.fast)) {
              proxy.scrollTo(item, anchor: item == listedItems.first ? .top : .center)
            }
            scrollTarget = nil
          }
        }
        .frame(width: 320)

        Divider().overlay(palette.paper.opacity(0.06))
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.raised.opacity(0.55))
      }
      .frame(height: min(Self.listCap, max(Self.listFloor, listHeight)))
      .animation(motion.enter(.moderate), value: listHeight)

      Divider().overlay(palette.paper.opacity(0.06))
      footer
    }
    .frame(width: 760)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .ottoElevated(cornerRadius: 14, depth: .modal)
  }

  /// Four hints at most, and Enter is named after the row it will run.
  private var footer: some View {
    HStack(spacing: 14) {
      hint("↑↓", "Select")
      hint("← →", "Filter")
      Spacer(minLength: 0)
      hint("Esc", "Close")
      hint("↵", enterHint)
        .id(enterHint)
        .transition(.opacity.animation(motion.fade))
    }
    .animation(motion.fade, value: enterHint)
    .padding(.horizontal, 16)
    .frame(height: 34)
  }

  private func hint(_ key: String, _ label: String) -> some View {
    HStack(spacing: 6) {
      keycap(key)
      Text(label)
        .font(.ottoDisplay(11))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
    }
  }

  /// A small bordered key, the way devl.dev draws keyboard hints.
  private func keycap(_ key: String) -> some View {
    Text(key)
      .font(.ottoMono(9.5, weight: .medium))
      .foregroundStyle(palette.muted)
      .padding(.horizontal, 5)
      .frame(minWidth: 18, minHeight: 17)
      .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.paper.opacity(0.12)))
  }

  private var filterChips: some View {
    OttoFluidHover(
      axis: .horizontal,
      style: OttoFluidHoverStyle(fill: palette.paper.opacity(0.05), cornerRadius: 7)
    ) {
      HStack(spacing: 2) {
        ForEach(PaletteFilter.allCases, id: \.self) { candidate in
          let on = candidate == filter
          Button {
            withAnimation(motion.enter(.moderate)) { filter = candidate }
          } label: {
            Text(candidate.rawValue)
              .font(.ottoDisplay(12))
              .foregroundStyle(on ? palette.paper : palette.muted)
              .animation(motion.tint, value: on)
              .padding(.horizontal, 11)
              .padding(.vertical, 4)
              .background {
                if on {
                  RoundedRectangle(cornerRadius: 7)
                    .fill(palette.surface)
                    .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
                    .matchedGeometryEffect(id: "palette-filter", in: filterSelection)
                }
              }
              .contentShape(RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .ottoHoverItem(candidate)
          .accessibilityLabel("Filter: \(candidate.rawValue)")
        }
      }
    }
    .padding(3)
    .background(palette.paper.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.ottoMicro)
      .tracking(2.4)
      .foregroundStyle(palette.muted)
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 2)
  }

  // Rows carry no fill of their own: the group's single highlight glides between them.
  private func quickActionRow(_ action: PaletteQuickAction) -> some View {
    let item = CommandPaletteItem.action(action.id)
    return Button {
      selection = item
      run(action)
    } label: {
      HStack(alignment: .center, spacing: 11) {
        actionIcon(action, size: 14, color: action.accent.color(palette))
          .frame(width: 20)
          .opacity(0.85)
        (Text(action.title).font(.ottoDisplay(13.5)).foregroundStyle(palette.paper)
          + Text("  ")
          + Text(action.subtitle).font(.ottoDisplay(11.5)).foregroundStyle(palette.muted))
          .lineLimit(1)
        Spacer(minLength: 6)
        if selection == item {
          HStack(spacing: 3) {
            Image(systemName: "return").font(.system(size: 8.5, weight: .semibold))
            Text("go")
          }
          .font(.ottoMicro)
          .foregroundStyle(palette.muted)
        } else {
          Image(systemName: "arrow.right").font(.system(size: 9, weight: .medium))
            .foregroundStyle(palette.muted.opacity(0.45))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .ottoHoverItem(item)
    .id(item)
  }

  private func toolRow(_ definition: ToolDefinition) -> some View {
    let item = CommandPaletteItem.tool(definition.name)
    return Button {
      select(definition)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text(definition.name)
          .font(.ottoMono(10, weight: .bold))
          .foregroundStyle(palette.paper)
        Text(definition.description)
          .font(.ottoDisplay(11))
          .foregroundStyle(palette.muted)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .ottoHoverItem(item)
    .id(item)
  }

  @ViewBuilder private var detail: some View {
    if let action = selectedAction {
      VStack(alignment: .leading, spacing: 14) {
        actionIcon(action, size: 28, color: palette.signal)
          .frame(width: 30, height: 30, alignment: .leading)
        Text(action.title).font(.ottoDisplay(21)).foregroundStyle(palette.paper)
        Text(action.subtitle)
          .font(.ottoDisplay(13))
          .foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        HStack {
          Spacer()
          Button {
            run(action)
          } label: {
            Text("Run")
              .font(.ottoDisplay(13))
              .padding(.horizontal, 16)
              .padding(.vertical, 6)
          }
          .buttonStyle(.ottoPrimary(cornerRadius: 7))
          .keyboardShortcut(.defaultAction)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    } else if let selected = selectedTool {
      VStack(alignment: .leading, spacing: 12) {
        Text(selected.name).font(.ottoMono(13, weight: .black)).foregroundStyle(palette.signal)
        Text(selected.description).font(.ottoDisplay(15)).foregroundStyle(palette.paper)
        HStack {
          Text(selected.riskLevel.rawValue.uppercased())
          Text(selected.requiredScopes.map(\.rawValue).sorted().joined(separator: " · "))
        }
        .font(.ottoMono(8, weight: .bold)).foregroundStyle(palette.muted)
        Text("INPUT · JSON").font(.ottoMono(8, weight: .black)).foregroundStyle(palette.muted)
        TextEditor(text: $input)
          .font(.ottoMono(11))
          .scrollContentBackground(.hidden)
          .padding(8)
          .background(palette.ink, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.paper.opacity(0.1)))
        if !result.isEmpty {
          Text(result).font(.ottoMono(9))
            .foregroundStyle(result.hasPrefix("Error:") ? palette.red : palette.signal)
            .textSelection(.enabled).lineLimit(4)
        }
        HStack {
          Spacer()
          Button {
            run(selected)
          } label: {
            Text(running ? "Running…" : "Run Command")
              .font(.ottoDisplay(13))
              .padding(.horizontal, 16)
              .padding(.vertical, 6)
          }
          .buttonStyle(.ottoPrimary(cornerRadius: 7))
          .keyboardShortcut(.defaultAction)
          .disabled(running)
        }
      }
      .padding(24)
    } else {
      ContentUnavailableView("No matching commands", systemImage: "command")
    }
  }

  private func selectFirstMatch() {
    applySelection(listedItems.first)
    scrollTarget = listedItems.first
  }

  private func moveSelection(_ step: Int) {
    let next = CommandPaletteNavigator.move(from: selection, through: listedItems, by: step)
    applySelection(next)
    scrollTarget = next
  }

  /// ← → step the filter chips, but only while the field is empty so a caret still has
  /// somewhere to go while a query is being edited.
  private func moveFilter(_ step: Int) -> Bool {
    guard query.isEmpty else { return false }
    withAnimation(motion.enter(.moderate)) {
      filter = step < 0 ? filter.previous : filter.next
    }
    return true
  }

  private func applySelection(_ item: CommandPaletteItem?) {
    switch item {
    case .action(let id):
      selection = .action(id)
      result = ""
    case .tool(let name):
      if let definition = matchingTools.first(where: { $0.name == name }) {
        select(definition)
      } else {
        selection = .tool(name)
      }
    case nil:
      selection = nil
      input = "{}"
      result = ""
    }
  }

  private func runSelection() {
    if let action = selectedAction {
      run(action)
    } else if let tool = selectedTool {
      run(tool)
    }
  }

  @ViewBuilder
  private func actionIcon(_ action: PaletteQuickAction, size: CGFloat, color: Color) -> some View {
    if let provider = action.agentProvider {
      AgentProviderLogo(provider: provider, size: size, color: color)
    } else {
      Image(systemName: action.symbol)
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
  }

  private func select(_ definition: ToolDefinition) {
    selection = .tool(definition.name)
    input = CommandPaletteCatalog.inputTemplate(for: definition)
    result = ""
  }

  private func run(_ action: PaletteQuickAction) {
    recentRaw = CommandPaletteRecents.encode(
      CommandPaletteRecents.remembering(action.id, in: CommandPaletteRecents.decode(recentRaw)))
    close()
    action.perform()
  }

  private func run(_ definition: ToolDefinition) {
    running = true
    result = ""
    Task {
      do {
        let data = Data(input.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let output = try await services.callUserTool(name: definition.name, input: value)
        let encoded = try JSONEncoder.pretty.encode(output)
        result = String(decoding: encoded, as: UTF8.self)
      } catch {
        result = "Error: \(error.localizedDescription)"
      }
      running = false
    }
  }

  /// Slow in, faster out: the panel leaves on the slow tier's exit tween, and the overlay is
  /// torn down once that has run.
  private func close() {
    guard presented else { return }
    presented = false
    let delay = motion.reduceMotion ? OttoMotion.fadeDuration : OttoMotion.slow.exitDuration
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      uiState.showsCommandPalette = false
    }
  }
}

/// TextField swallows ↑/↓ for the caret, so the palette also watches the window key stream
/// and handles those codes itself while it is on screen. ← → go to the filter chips when the
/// palette says it can take them.
private struct PaletteArrowKeyCatcher: NSViewRepresentable {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  var onMove: (Int) -> Void
  var onMoveFilter: (Int) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(onMove: onMove, onMoveFilter: onMoveFilter)
  }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.isEnabled = spaceVisible
    context.coordinator.install()
    return NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.isEnabled = spaceVisible
    context.coordinator.onMove = onMove
    context.coordinator.onMoveFilter = onMoveFilter
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  @MainActor
  final class Coordinator {
    var onMove: (Int) -> Void
    var onMoveFilter: (Int) -> Bool
    var isEnabled = true
    private var monitor: Any?

    init(onMove: @escaping (Int) -> Void, onMoveFilter: @escaping (Int) -> Bool) {
      self.onMove = onMove
      self.onMoveFilter = onMoveFilter
    }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard self.isEnabled else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isEmpty else { return event }
        switch event.keyCode {
        case 126:
          MainActor.assumeIsolated { self.onMove(-1) }
          return nil
        case 125:
          MainActor.assumeIsolated { self.onMove(1) }
          return nil
        case 123:
          return MainActor.assumeIsolated { self.onMoveFilter(-1) } ? nil : event
        case 124:
          return MainActor.assumeIsolated { self.onMoveFilter(1) } ? nil : event
        default:
          return event
        }
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

extension JSONEncoder {
  fileprivate static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

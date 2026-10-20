import AppKit
import Charts
import OttoModels
import OttoServices
import SwiftUI

/// Cards agents and automations put on Home ("add my top meetings to my home page"). Lists,
/// numbers with their change, or a short note, on the same smoked glass as the brief.
struct HomeCardsView: View {
  @ObservedObject var cards: HomeCardsStore
  @ObservedObject var services: ApplicationServices
  /// The page to show: nil is Home, otherwise a dashboard.
  var dashboardID: UUID? = nil
  /// Dashboards are wider, so they take more columns.
  var minimumColumnWidth: CGFloat = 300
  /// The page's accent for charts; a card's own colour wins.
  var accent: HomeCardColor? = nil
  /// Arranging the page: drag cards to reorder, pick each card's size and colour.
  var editing = false
  let openAutomations: () -> Void
  /// Opens a card's running or failed update beside the page. Nil hides the option.
  var showRun: ((HomeCard, UUID) -> Void)? = nil
  @Environment(\.ottoPalette) private var palette
  @State private var explaining: UUID?
  @State private var refreshing: Set<UUID> = []
  @State private var confirmRemove: HomeCard?
  @State private var pendingRemoval: (card: HomeCard, index: Int, automationID: UUID?)?
  @State private var undo: OttoUndoToast?
  @State private var status: OttoStatusToast?
  @State private var dropTarget: UUID?

  var body: some View {
    let page = cards.cards(on: dashboardID)
    if !page.isEmpty {
      HomeCardGrid(minimumColumnWidth: minimumColumnWidth, spacing: 14) {
        ForEach(page) { card in
          cardView(card)
            .layoutValue(key: HomeCardGrid.Width.self, value: card.width ?? .regular)
        }
      }
      .animation(.easeOut(duration: 0.2), value: page.map { "\($0.id)\($0.width as Any)" })
      .foregroundStyle(palette.paper)
      .confirmationDialog(
        "Remove “\(confirmRemove?.title ?? "")”?",
        isPresented: Binding(
          get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
        presenting: confirmRemove
      ) { card in
        Button("Remove card and its automation", role: .destructive) {
          remove(card, deletingAutomation: true)
        }
        Button("Remove card only") { remove(card, deletingAutomation: false) }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text("An automation keeps this card up to date.")
      }
      .ottoStatusToast($status)
      .ottoUndoToast($undo, onUndo: undoRemoval, onExpire: commitRemoval)
    }
  }

  private func automation(_ card: HomeCard) -> Routine? {
    card.automationID.flatMap { services.routines.routine(id: $0) }
  }

  /// The card's colour, else the page's, else the theme's.
  private func tint(_ card: HomeCard) -> Color {
    (card.color ?? accent)?.swatch ?? palette.signal
  }

  @ViewBuilder private func cardView(_ card: HomeCard) -> some View {
    let body = cardBody(card)
    if editing {
      body
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
              dropTarget == card.id ? tint(card) : palette.paper.opacity(0.22),
              style: StrokeStyle(lineWidth: dropTarget == card.id ? 2 : 1, dash: [5, 4]))
        }
        .draggable(card.id.uuidString) {
          Text(card.title).font(.ottoDisplay(13).weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .ottoGlass(cornerRadius: 10)
        }
        .dropDestination(for: String.self) { items, _ in
          guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
          withAnimation(.easeOut(duration: 0.2)) { try? cards.move(id: id, to: card.id) }
          return true
        } isTargeted: { targeted in
          if targeted {
            dropTarget = card.id
          } else if dropTarget == card.id {
            dropTarget = nil
          }
        }
    } else {
      body
    }
  }

  private func cardBody(_ card: HomeCard) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(card.title)
          .font(.ottoDisplay(15).weight(.semibold))
          .foregroundStyle(palette.paper.opacity(0.92))
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        if editing {
          Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.muted)
            .help("Drag to move")
            .accessibilityHidden(true)
        } else {
          if refreshing.contains(card.id) || services.cardRunIsWorking(cardID: card.id) {
            ProgressView().controlSize(.mini)
          }
          menu(card)
        }
      }
      content(card)
      // Cards in a row share a height, so the footer sits on the bottom edge.
      Spacer(minLength: 0)
      if editing {
        editBar(card)
      } else {
        footer(card)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .ottoGlass(cornerRadius: 16)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(card.title)
  }

  @ViewBuilder private func content(_ card: HomeCard) -> some View {
    if card.isEmpty {
      Text(
        automation(card) == nil
          ? "Nothing here yet." : "Nothing yet. It fills in on the next run."
      )
      .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        if card.style == .metrics, !card.rows.isEmpty {
          metrics(card.rows, tint: (card.color ?? accent) == nil ? nil : tint(card))
        } else if card.style.isChart, card.rows.contains(where: { $0.number != nil }) {
          chart(card)
        } else if !card.rows.isEmpty {
          list(card.rows)
        }
        if let text = card.text, !text.isEmpty {
          Text(Self.markdown(text))
            .font(.ottoDisplay(13))
            .foregroundStyle(palette.paper.opacity(0.86))
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(12)
        }
      }
    }
  }

  /// Line and bar charts plot each row's value in order; labels run along the bottom.
  private func chart(_ card: HomeCard) -> some View {
    let points = card.rows.compactMap { row in row.number.map { (label: row.label, value: $0) } }
    // The shaded area starts just under the lowest point so small changes stay visible.
    let low = points.map(\.value).min() ?? 0
    let high = points.map(\.value).max() ?? 0
    let floor = low - max((high - low) * 0.15, abs(low) * 0.001)
    return Chart(Array(points.enumerated()), id: \.offset) { _, point in
      if card.style == .line {
        AreaMark(
          x: .value("Label", point.label), yStart: .value("Floor", floor),
          yEnd: .value("Value", point.value)
        )
        .foregroundStyle(
          LinearGradient(
            colors: [tint(card).opacity(0.28), tint(card).opacity(0.02)],
            startPoint: .top, endPoint: .bottom)
        )
        .interpolationMethod(.catmullRom)
        LineMark(x: .value("Label", point.label), y: .value("Value", point.value))
          .foregroundStyle(tint(card))
          .lineStyle(StrokeStyle(lineWidth: 2))
          .interpolationMethod(.catmullRom)
      } else {
        BarMark(x: .value("Label", point.label), y: .value("Value", point.value))
          .foregroundStyle(tint(card).gradient)
          .cornerRadius(4)
      }
    }
    .chartXAxis {
      AxisMarks { _ in
        AxisValueLabel().font(.ottoMono(9)).foregroundStyle(palette.muted)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine().foregroundStyle(palette.paper.opacity(0.08))
        AxisValueLabel().font(.ottoMono(9)).foregroundStyle(palette.muted)
      }
    }
    // Trends read better when the axis hugs the data rather than starting at zero.
    .chartYScale(domain: .automatic(includesZero: card.style == .bar))
    .frame(height: 170)
    .accessibilityLabel(
      points.map { "\($0.label) \(Self.plain($0.value))" }.joined(separator: ", "))
  }

  static func plain(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
  }

  private func list(_ rows: [HomeCardRow]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(rows.prefix(12).enumerated()), id: \.element.id) { index, row in
        if index > 0 { Divider().overlay(palette.paper.opacity(0.06)) }
        if let url = row.url.flatMap(URL.init(string:)) {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            listRow(row, linked: true)
          }
          .buttonStyle(.plain)
          .help(url.absoluteString)
        } else {
          listRow(row, linked: false)
        }
      }
      if rows.count > 12 {
        Text("+\(rows.count - 12) more").font(.ottoMicro).foregroundStyle(palette.muted)
          .padding(.top, 6)
      }
    }
  }

  private func listRow(_ row: HomeCardRow, linked: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(row.label).font(.ottoDisplay(13).weight(.medium)).lineLimit(2)
          if linked {
            Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
              .foregroundStyle(palette.muted)
          }
        }
        if let detail = row.detail {
          Text(detail).font(.ottoDisplay(12)).foregroundStyle(palette.muted).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if let value = row.value {
        Text(value).font(.ottoMono(11, weight: .medium))
          .foregroundStyle(palette.paper.opacity(0.8)).monospacedDigit()
      }
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  private func metrics(_ rows: [HomeCardRow], tint: Color?) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 110), spacing: 10, alignment: .topLeading)],
      alignment: .leading, spacing: 14
    ) {
      ForEach(rows.prefix(9)) { row in
        VStack(alignment: .leading, spacing: 4) {
          Text(row.label.uppercased()).font(.ottoMicro).tracking(1.6)
            .foregroundStyle(palette.muted).lineLimit(1)
          Text(row.value ?? "—")
            .font(.ottoDisplay(24).weight(.semibold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
          HStack(spacing: 6) {
            if let delta = row.delta, delta != 0 {
              Text(Self.signed(delta))
                .font(.ottoMono(10, weight: .medium))
                .foregroundStyle(delta > 0 ? palette.cyan : palette.red)
            } else if let detail = row.detail {
              Text(detail).font(.ottoDisplay(11)).foregroundStyle(palette.muted).lineLimit(1)
            }
            if row.history.count >= 3 {
              HomeCardSparkline(values: row.history)
                .stroke(tint ?? palette.paper.opacity(0.5), lineWidth: 1.2)
                .frame(width: 44, height: 14)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func footer(_ card: HomeCard) -> some View {
    let by = automation(card)?.name ?? card.updatedBy
    let when = card.updatedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(
          ([("Updated " + when)] + [by].compactMap { $0 }).joined(separator: " · ").uppercased()
        )
        .lineLimit(1)
        Spacer(minLength: 6)
        // Every number says where it came from, so people can trust or question it.
        if card.source != nil {
          Button(explaining == card.id ? "HIDE" : "HOW THIS WAS MADE") {
            withAnimation(.easeOut(duration: 0.15)) {
              explaining = explaining == card.id ? nil : card.id
            }
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.paper.opacity(0.7))
        }
      }
      .font(.ottoMicro).tracking(1.6)
      .foregroundStyle(palette.muted.opacity(0.9))
      if explaining == card.id, let source = card.source {
        Text(source)
          .font(.ottoMono(10.5))
          .foregroundStyle(palette.paper.opacity(0.8))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(palette.paper.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      }
    }
  }

  private func menu(_ card: HomeCard) -> some View {
    Menu {
      if let routine = automation(card) {
        Button("Refresh now", systemImage: "arrow.clockwise") { refresh(card, routine) }
        Button("Change automation…", systemImage: "clock.arrow.circlepath") { openAutomations() }
      } else {
        Button("Keep it updated…", systemImage: "clock.arrow.circlepath") { openAutomations() }
      }
      if let run = services.cardRunSession(cardID: card.id) {
        let working = services.cardRunIsWorking(cardID: card.id)
        if let showRun {
          Button(
            working ? "Watch the update" : "See why the update failed",
            systemImage: working ? "eye" : "exclamationmark.triangle"
          ) { showRun(card, run) }
        }
        Button(
          working ? "Stop update" : "Dismiss failed update",
          systemImage: working ? "stop.circle" : "xmark.circle"
        ) {
          Task { await services.closeCardRun(cardID: card.id) }
        }
      }
      Divider()
      Picker("Size", selection: widthBinding(card)) {
        ForEach(HomeCard.Width.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      Picker("Colour", selection: colorBinding(card)) {
        Text(dashboardID == nil ? "Theme" : "Dashboard").tag(HomeCardColor?.none)
        ForEach(HomeCardColor.allCases, id: \.self) { Text($0.title).tag(HomeCardColor?.some($0)) }
      }
      Button("Move earlier", systemImage: "arrow.up") { try? cards.move(id: card.id, by: -1) }
        .disabled(cards.cards(on: dashboardID).first?.id == card.id)
      Button("Move later", systemImage: "arrow.down") { try? cards.move(id: card.id, by: 1) }
        .disabled(cards.cards(on: dashboardID).last?.id == card.id)
      Divider()
      Button(
        dashboardID == nil ? "Remove from Home" : "Remove card", systemImage: "trash",
        role: .destructive
      ) {
        if automation(card) != nil {
          confirmRemove = card
        } else {
          remove(card, deletingAutomation: false)
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(palette.muted)
        .frame(width: 22, height: 18)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Card options")
  }

  private func widthBinding(_ card: HomeCard) -> Binding<HomeCard.Width> {
    Binding(
      get: { cards.card(id: card.id)?.width ?? .regular },
      set: { width in
        withAnimation(.easeOut(duration: 0.2)) {
          save { try cards.update(id: card.id) { $0.width = width == .regular ? nil : width } }
        }
      })
  }

  private func colorBinding(_ card: HomeCard) -> Binding<HomeCardColor?> {
    Binding(
      get: { cards.card(id: card.id)?.color },
      set: { color in save { try cards.update(id: card.id) { $0.color = color } } })
  }

  private func save(_ change: () throws -> Void) {
    do { try change() } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t save", detail: error.localizedDescription)
    }
  }

  /// Size and colour for one card while the page is being arranged.
  private func editBar(_ card: HomeCard) -> some View {
    let width = widthBinding(card)
    let color = colorBinding(card)
    return VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        HStack(spacing: 2) {
          ForEach(HomeCard.Width.allCases, id: \.self) { option in
            let active = width.wrappedValue == option
            Button {
              width.wrappedValue = option
            } label: {
              Text(option.title).font(.ottoDisplay(11.5).weight(active ? .semibold : .regular))
                .padding(.horizontal, 9).frame(height: 24)
                .background(active ? palette.paper.opacity(0.16) : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(active ? palette.paper : palette.muted)
            .accessibilityLabel("Size \(option.title)")
            .accessibilityAddTraits(active ? .isSelected : [])
          }
        }
        .padding(2)
        .background(palette.paper.opacity(0.06), in: Capsule())
        .fixedSize()
        Spacer(minLength: 6)
        Button {
          if automation(card) != nil {
            confirmRemove = card
          } else {
            remove(card, deletingAutomation: false)
          }
        } label: {
          Image(systemName: "trash").font(.system(size: 11, weight: .medium))
            .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.muted)
        .help("Remove card")
        .accessibilityLabel("Remove \(card.title)")
      }
      HomeCardColorSwatches(selection: color, fallback: accent?.swatch ?? palette.signal)
    }
  }

  private func refresh(_ card: HomeCard, _ routine: Routine) {
    refreshing.insert(card.id)
    Task {
      do {
        let output = try await services.testRoutine(id: routine.id)
        if output.fired {
          status = OttoStatusToast(
            kind: .info, title: "Refreshing “\(card.title)”",
            detail: "It updates when \(routine.name) finishes.")
        } else {
          status = OttoStatusToast(
            kind: .error, title: "Couldn’t refresh", detail: output.reason)
        }
      } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t refresh", detail: error.localizedDescription)
      }
      refreshing.remove(card.id)
    }
  }

  /// The card goes at once; deleting its automation waits until the undo window closes.
  private func remove(_ card: HomeCard, deletingAutomation: Bool) {
    commitRemoval()
    let index = cards.allCards.firstIndex { $0.id == card.id } ?? 0
    do { try cards.remove(id: card.id) } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t remove", detail: error.localizedDescription)
      return
    }
    Task { await services.closeCardRun(cardID: card.id) }
    pendingRemoval = (card, index, deletingAutomation ? card.automationID : nil)
    undo = OttoUndoToast(
      title: deletingAutomation ? "Card and automation removed" : "Card removed",
      detail: "“\(card.title)”")
  }

  private func undoRemoval() {
    guard let pending = pendingRemoval else { return }
    pendingRemoval = nil
    try? cards.restore(pending.card, at: pending.index)
  }

  private func commitRemoval() {
    guard let pending = pendingRemoval else { return }
    pendingRemoval = nil
    if let id = pending.automationID { try? services.deleteRoutine(id: id) }
  }

  static func signed(_ value: Double) -> String {
    let magnitude = abs(value)
    let text =
      magnitude >= 1_000_000
      ? String(format: "%.1fM", magnitude / 1_000_000)
      : magnitude >= 10_000
        ? String(format: "%.1fk", magnitude / 1_000)
        : magnitude.rounded() == magnitude
          ? String(Int(magnitude)) : String(format: "%.1f", magnitude)
    return (value > 0 ? "+" : "−") + text
  }

  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}

/// A tiny trend line through a row's recent values.
struct HomeCardSparkline: Shape {
  let values: [Double]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard values.count >= 2, let low = values.min(), let high = values.max() else { return path }
    let span = high - low
    for (index, value) in values.enumerated() {
      let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
      let y =
        rect.maxY - (span == 0 ? rect.height / 2 : rect.height * CGFloat((value - low) / span))
      if index == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }
    return path
  }
}

/// A row of colour dots; the first, ringed one means "no colour of its own".
struct HomeCardColorSwatches: View {
  @Binding var selection: HomeCardColor?
  /// Shown in the first dot: what the card or page falls back to.
  let fallback: Color
  var size: CGFloat = 14
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    HStack(spacing: 5) {
      dot(nil, fill: fallback)
      ForEach(HomeCardColor.allCases, id: \.self) { color in dot(color, fill: color.swatch) }
    }
  }

  private func dot(_ color: HomeCardColor?, fill: Color) -> some View {
    let active = selection == color
    return Button {
      selection = color
    } label: {
      ZStack {
        Circle().fill(fill.opacity(color == nil ? 0.35 : 1))
        if color == nil {
          Circle().strokeBorder(fill, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        }
      }
      .frame(width: size, height: size)
      .padding(2)
      .overlay(Circle().strokeBorder(palette.paper.opacity(active ? 0.9 : 0), lineWidth: 1.5))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(color?.title ?? "Default")
    .accessibilityLabel(color?.title ?? "Default colour")
    .accessibilityAddTraits(active ? .isSelected : [])
  }
}

/// Cards in rows: each takes one, two or all columns, and cards in a row share the tallest
/// one's height so the page stays even.
struct HomeCardGrid: Layout {
  struct Width: LayoutValueKey {
    static let defaultValue = HomeCard.Width.regular
  }

  var minimumColumnWidth: CGFloat
  var spacing: CGFloat

  private struct Row {
    var items: [(index: Int, width: CGFloat)] = []
    var height: CGFloat = 0
  }

  private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
    let columns = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
    let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
    var rows: [Row] = []
    var current = Row()
    var used = 0
    for (index, subview) in subviews.enumerated() {
      let span = subview[Width.self].span(of: columns)
      if used + span > columns, !current.items.isEmpty {
        rows.append(current)
        current = Row()
        used = 0
      }
      let itemWidth = column * CGFloat(span) + spacing * CGFloat(span - 1)
      let height = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height
      current.items.append((index, itemWidth))
      current.height = max(current.height, height)
      used += span
    }
    if !current.items.isEmpty { rows.append(current) }
    return rows
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? minimumColumnWidth * 3 + spacing * 2
    let rows = rows(width: width, subviews: subviews)
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for row in rows(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for item in row.items {
        subviews[item.index].place(
          at: CGPoint(x: x, y: y), anchor: .topLeading,
          proposal: ProposedViewSize(width: item.width, height: row.height))
        x += item.width + spacing
      }
      y += row.height + spacing
    }
  }
}

extension HomeCard.Width {
  var title: String {
    switch self {
    case .regular: "Small"
    case .wide: "Wide"
    case .full: "Full"
    }
  }
}

extension HomeCardColor {
  var title: String { rawValue == "gray" ? "Grey" : rawValue.capitalized }

  /// Bright enough to read on the dark smoked cards dashboards use.
  var swatch: Color {
    switch self {
    case .green: Color(red: 0.24, green: 0.86, blue: 0.59)
    case .blue: Color(red: 0.36, green: 0.66, blue: 1.0)
    case .purple: Color(red: 0.66, green: 0.55, blue: 0.98)
    case .pink: Color(red: 0.96, green: 0.45, blue: 0.71)
    case .orange: Color(red: 0.98, green: 0.57, blue: 0.24)
    case .yellow: Color(red: 0.98, green: 0.8, blue: 0.08)
    case .red: Color(red: 0.97, green: 0.44, blue: 0.44)
    case .gray: Color(red: 0.63, green: 0.63, blue: 0.67)
    }
  }
}

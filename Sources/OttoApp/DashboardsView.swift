import OttoModels
import OttoServices
import SwiftUI

/// Named pages of live cards — Revenue, Socials, My week — built by asking an agent. Each card
/// shows when it was updated and how it was made; automations keep them fresh.
struct DashboardsView<Conversation: View>: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var cards: HomeCardsStore
  @ObservedObject var office: OfficeStore
  /// Cards use Home's smoked glass: a dark plate with light text on every theme.
  let cardPalette: OttoPalette
  let start: AssistantStarter
  let openAutomations: () -> Void
  @ViewBuilder let conversation: (UUID) -> Conversation
  @Environment(\.ottoPalette) private var palette
  @AppStorage("otto.dashboards.selected") private var selectedRaw = ""
  @AppStorage(AssistantTarget.defaultsKey) private var targetRaw = ""
  @State private var showsPanel = true
  /// A card's running or failed update shown in the side panel instead of the helper.
  @State private var viewingRun: (card: HomeCard, nodeID: UUID)?
  @State private var naming = false
  @State private var draftName = ""
  @State private var renaming: Dashboard?
  @State private var error: String?
  @State private var undo: OttoUndoToast?
  @State private var pendingDelete: (Dashboard, [HomeCard])?
  /// Arranging the open dashboard: reorder, size and colour cards, set the page's look.
  @State var editing = false

  static var examples: [(String, String)] {
    [
      ("person.2", "Socials: my followers on LinkedIn, Reddit and Substack, with the trend"),
      ("sterlingsign.circle", "Revenue: this month's payments and MRR from Stripe"),
      ("calendar", "My week: meetings per day and my free focus time"),
      ("tray.full", "Inbox: unread email by sender and what needs a reply"),
    ]
  }

  private var target: Binding<AssistantTarget> {
    Binding(
      get: { AssistantTarget(storageValue: targetRaw) ?? .provider(.claudeCode) },
      set: { targetRaw = $0.storageValue })
  }

  private var selected: Dashboard? {
    let id = UUID(uuidString: selectedRaw)
    return cards.dashboards.first { $0.id == id } ?? cards.dashboards.first
  }

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          header
          if let dashboard = selected {
            tabs
            page(dashboard)
          } else {
            emptyState
          }
          if let error {
            Text(error).font(.ottoDisplay(12)).foregroundStyle(palette.red)
          }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: 1180, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      if let run = viewingRun, services.cardRunSession(cardID: run.card.id) == run.nodeID {
        runPanel(run).frame(width: 400)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else if let dashboard = selected, showsPanel,
        office.session(path: OfficeStore.dashboardKey(dashboard.id)) != nil
      {
        panel(dashboard).frame(width: 400)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
    .foregroundStyle(palette.paper)
    .alert("New dashboard", isPresented: $naming) {
      TextField("Name, e.g. Revenue", text: $draftName)
      Button("Create") { create(named: draftName) }
      Button("Cancel", role: .cancel) {}
    }
    .alert(
      "Rename dashboard",
      isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $draftName)
      Button("Rename") {
        if let renaming { attempt { try cards.renameDashboard(id: renaming.id, to: draftName) } }
      }
      Button("Cancel", role: .cancel) {}
    }
    .ottoUndoToast(
      $undo,
      onUndo: {
        if let (dashboard, removed) = pendingDelete {
          attempt { try cards.restoreDashboard(dashboard, cards: removed) }
          selectedRaw = dashboard.id.uuidString
        }
        pendingDelete = nil
      },
      onExpire: { pendingDelete = nil })
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Dashboards").font(.ottoDisplay(26).weight(.semibold))
        Text("Live numbers and charts your agents build and keep up to date.")
          .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
      }
      Spacer()
      Button {
        draftName = ""
        naming = true
      } label: {
        Label("New dashboard", systemImage: "plus")
          .font(.ottoDisplay(12.5).weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .buttonStyle(.ottoPrimary(cornerRadius: 8))
      .accessibilityIdentifier("dashboards.new")
    }
  }

  private var tabs: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(cards.dashboards) { dashboard in
          let active = dashboard.id == selected?.id
          Button {
            selectedRaw = dashboard.id.uuidString
            editing = false
          } label: {
            HStack(spacing: 6) {
              Image(systemName: dashboard.symbol).font(.system(size: 11))
              Text(dashboard.name).font(.ottoDisplay(12.5).weight(active ? .semibold : .regular))
              Text("\(cards.cards(on: dashboard.id).count)").font(.ottoMicro)
                .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
              active ? palette.paper.opacity(0.1) : .clear, in: Capsule()
            )
            .overlay(Capsule().strokeBorder(palette.paper.opacity(active ? 0.16 : 0.08)))
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button("Rename…") {
              draftName = dashboard.name
              renaming = dashboard
            }
            Button("Delete", role: .destructive) { delete(dashboard) }
          }
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private func page(_ dashboard: Dashboard) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .center) {
        Text(dashboard.name).font(.ottoDisplay(20).weight(.semibold))
        Spacer()
        if office.session(path: OfficeStore.dashboardKey(dashboard.id)) != nil {
          Button {
            withAnimation(.easeOut(duration: 0.18)) { showsPanel.toggle() }
          } label: {
            Label(showsPanel ? "Hide AI" : "Show AI", systemImage: "sparkles")
              .font(.ottoDisplay(12))
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.signal)
          .keyboardShortcut("j", modifiers: .command)
        }
        if !cards.cards(on: dashboard.id).isEmpty {
          Button {
            withAnimation(.easeOut(duration: 0.18)) { editing.toggle() }
          } label: {
            Label(
              editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "slider.horizontal.3"
            )
            .font(.ottoDisplay(12).weight(editing ? .semibold : .regular))
            .padding(.horizontal, 10).frame(height: 26)
            .background(palette.paper.opacity(editing ? 0.14 : 0.06), in: Capsule())
            .contentShape(Capsule())
          }
          .buttonStyle(.plain)
          .keyboardShortcut(editing ? .defaultAction : KeyboardShortcut("e", modifiers: .command))
          .help(editing ? "Finish arranging" : "Arrange cards and pick colours")
          .accessibilityIdentifier("dashboards.edit")
        }
        Menu {
          Button("Rename…") {
            draftName = dashboard.name
            renaming = dashboard
          }
          Button(editing ? "Done editing" : "Edit layout and colours…") {
            withAnimation(.easeOut(duration: 0.18)) { editing.toggle() }
          }
          .disabled(cards.cards(on: dashboard.id).isEmpty)
          Button("Delete dashboard", role: .destructive) { delete(dashboard) }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Dashboard options")
      }
      if editing {
        appearance(dashboard)
          .transition(.opacity.combined(with: .move(edge: .top)))
      } else {
        AssistantPromptBar(
          services: services,
          placeholder: "Add a chart, number or list to \(dashboard.name)…",
          target: target
        ) { request in
          await ask(request, dashboard: dashboard)
        }
      }
      if cards.cards(on: dashboard.id).isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Nothing here yet").font(.ottoDisplay(15).weight(.semibold))
          Text(
            "Ask for what you want to see, e.g. “daily signups this month as a line chart” or “top 5 customers by revenue”. Your agent finds the data with your connected apps and builds the cards."
          )
          .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.paper.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
      } else {
        HomeCardsView(
          cards: cards, services: services, dashboardID: dashboard.id, minimumColumnWidth: 340,
          accent: dashboard.accent, editing: editing, openAutomations: openAutomations,
          showRun: { card, nodeID in
            withAnimation(.easeOut(duration: 0.18)) { viewingRun = (card, nodeID) }
          }
        )
        .environment(\.ottoPalette, cardPalette)
        .environment(\.colorScheme, .dark)
        .environment(\.ottoGlassSmoke, (dashboard.cardStyle ?? .smoked).smoke)
      }
    }
  }

  /// The page's look while editing: accent colour, card style and icon.
  private func appearance(_ dashboard: Dashboard) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      appearanceControls(dashboard)
      Text("Drag cards to reorder them. Pick each card’s size and colour on the card.")
        .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .padding(.leading, 4)
    }
  }

  private func appearanceControls(_ dashboard: Dashboard) -> some View {
    HStack(spacing: 22) {
      VStack(alignment: .leading, spacing: 7) {
        Text("ACCENT").font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
        HomeCardColorSwatches(
          selection: Binding(
            get: { cards.dashboard(id: dashboard.id)?.accent },
            set: { accent in
              attempt { try cards.updateDashboard(id: dashboard.id) { $0.accent = accent } }
            }),
          fallback: cardPalette.signal, size: 16)
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("CARDS").font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
        Picker(
          "Cards",
          selection: Binding(
            get: { cards.dashboard(id: dashboard.id)?.cardStyle ?? .smoked },
            set: { style in
              attempt {
                try cards.updateDashboard(id: dashboard.id) {
                  $0.cardStyle = style == .smoked ? nil : style
                }
              }
            })
        ) {
          ForEach(Dashboard.CardStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("ICON").font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
        HStack(spacing: 4) {
          ForEach(Self.symbols, id: \.self) { symbol in
            let active = dashboard.symbol == symbol
            Button {
              attempt { try cards.updateDashboard(id: dashboard.id) { $0.symbol = symbol } }
            } label: {
              Image(systemName: symbol).font(.system(size: 12))
                .frame(width: 26, height: 24)
                .background(
                  palette.paper.opacity(active ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(active ? palette.paper : palette.muted)
            .accessibilityLabel(symbol)
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 18).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(palette.paper.opacity(0.08)))
  }

  static var symbols: [String] {
    [
      "chart.bar.xaxis", "chart.line.uptrend.xyaxis", "person.2", "sterlingsign.circle",
      "calendar", "tray.full", "megaphone", "star",
    ]
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Describe a dashboard and an agent builds it")
          .font(.ottoDisplay(18).weight(.semibold))
        Text(
          "It picks the charts, finds the numbers with your connected apps, shows how each one was made, and can keep it up to date."
        )
        .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
      }
      AssistantPromptBar(
        services: services, placeholder: "e.g. Socials: my followers across LinkedIn and Reddit",
        target: target
      ) { request in
        await build(request)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
        ForEach(Self.examples, id: \.1) { symbol, example in
          Button {
            Task { await build(example) }
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: symbol).foregroundStyle(palette.signal).frame(width: 18)
              Text(example).font(.ottoDisplay(12.5)).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(palette.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .ottoElevated(cornerRadius: 12)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.top, 6)
  }

  // MARK: Actions

  /// The helper chat bound to a dashboard, styled like a session's side panel.
  private func panel(_ dashboard: Dashboard) -> some View {
    let key = OfficeStore.dashboardKey(dashboard.id)
    return WorkAssistantPanel(
      services: services,
      target: Binding(
        get: { target.wrappedValue },
        set: { next in
          if next != target.wrappedValue { office.setSession(nil, path: key) }
          target.wrappedValue = next
        }),
      sessionID: office.session(path: key),
      actions: AssistantPanelActions(
        newChat: { office.setSession(nil, path: key) },
        close: { withAnimation(.easeOut(duration: 0.18)) { showsPanel = false } })
    ) {
      EmptyView()
    } empty: {
      EmptyView()
    } conversation: { nodeID in
      conversation(nodeID)
    }
  }

  /// A card's update while it runs, or what went wrong after it failed.
  private func runPanel(_ run: (card: HomeCard, nodeID: UUID)) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.signal)
        Text("Update · \(run.card.title)").font(.ottoDisplay(12).weight(.semibold))
          .lineLimit(1)
        Spacer(minLength: 0)
        Button(services.cardRunIsWorking(cardID: run.card.id) ? "Stop" : "Dismiss") {
          let card = run.card
          withAnimation(.easeOut(duration: 0.18)) { viewingRun = nil }
          Task { await services.closeCardRun(cardID: card.id) }
        }
        .buttonStyle(.plain)
        .font(.ottoDisplay(11.5))
        .foregroundStyle(palette.muted)
        .help("The card keeps its last numbers.")
        Button {
          withAnimation(.easeOut(duration: 0.18)) { viewingRun = nil }
        } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.ottoChrome)
        .foregroundStyle(palette.muted)
        .accessibilityLabel("Hide update")
      }
      .padding(.horizontal, 12)
      .frame(height: 46)
      Divider().overlay(palette.paper.opacity(0.08))
      conversation(run.nodeID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(palette.paneSurface)
    .overlay(alignment: .leading) {
      Rectangle().fill(palette.paper.opacity(0.08)).frame(width: 1)
    }
  }

  /// "Socials: my followers on LinkedIn…" → a dashboard called Socials, then the helper fills it.
  private func build(_ request: String) async {
    let name = Self.name(from: request)
    do {
      let dashboard = try cards.dashboard(named: name) ?? cards.createDashboard(name: name)
      selectedRaw = dashboard.id.uuidString
      await ask(request, dashboard: dashboard)
    } catch {
      self.error = error.localizedDescription
    }
  }

  static func name(from request: String) -> String {
    let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
    if let colon = trimmed.firstIndex(of: ":"),
      trimmed.distance(from: trimmed.startIndex, to: colon) <= 30
    {
      return String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
    }
    return DocumentsTitle.from(trimmed, words: 3)
  }

  /// Sends to the dashboard's own helper, which stays beside the dashboard.
  private func ask(_ request: String, dashboard: Dashboard) async {
    do {
      _ = try await start(target.wrappedValue, request, OfficeStore.dashboardKey(dashboard.id))
      withAnimation(.easeOut(duration: 0.2)) { showsPanel = true }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func create(named name: String) {
    attempt {
      let dashboard = try cards.createDashboard(name: name)
      selectedRaw = dashboard.id.uuidString
    }
  }

  private func delete(_ dashboard: Dashboard) {
    attempt {
      if let removed = try cards.deleteDashboard(id: dashboard.id) {
        pendingDelete = removed
        undo = OttoUndoToast(title: "Dashboard deleted", detail: "“\(dashboard.name)”")
      }
    }
  }

  private func attempt(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

extension Dashboard.CardStyle {
  var title: String { rawValue.capitalized }
}

import OttoModels
import OttoServices
import SwiftUI

/// The Tickets place: work handed to bots. The list puts what needs the person first; opening
/// a ticket shows its brief and the story of how it went, with the decision to make in place.
struct TicketsView: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var tickets: TicketStore
  /// The open ticket, owned by Chat so Activity can open one.
  @Binding var selection: UUID?
  let avatar: (BotRosterEntry) -> BotAvatarPresentation
  let openAgent: (UUID) -> Void
  /// When set, only this bot's tickets show: the ones it owns and the ones it handed out.
  var scope: AgentProfile?
  @Environment(\.ottoPalette) private var palette
  @State private var filter: Filter = .all
  @State private var botFilter: UUID?
  @State private var composing = false
  /// The bot a new ticket starts out given to, when the form was opened from the CEO's page.
  @State private var composerAssignee: UUID?
  @State private var showingCEO = false
  @State private var status: OttoStatusToast?

  enum Filter: Hashable {
    case all
    case needsYou
    case mine
  }

  var body: some View {
    let roster = services.botRoster()
    Group {
      if showingCEO, scope == nil, selection == nil, let chief = services.ceoProfile {
        TicketCEOView(
          services: services, chief: chief, roster: roster, avatar: avatar,
          close: { showingCEO = false },
          newTicket: {
            showingCEO = false
            composerAssignee = chief.id
            composing = true
          }, report: { status = $0 })
      } else if let id = selection, let ticket = tickets.ticket(id: id) {
        TicketDetailView(
          services: services, tickets: tickets, ticket: ticket, roster: roster, avatar: avatar,
          openAgent: openAgent, open: { selection = $0 }, close: { selection = nil },
          report: { status = $0 })
      } else {
        list(roster: roster)
      }
    }
    .foregroundStyle(palette.paper)
    .background(palette.workspaceSurface)
    .ottoStatusToast($status)
    .accessibilityIdentifier("tickets.place")
    #if DEBUG
      .onReceive(NotificationCenter.default.publisher(for: OttoDevProbe.ticketNotification)) {
        note in
        let command = note.object as? String ?? ""
        if command == "new" {
          selection = nil
          showingCEO = false
          composing = true
        } else if command == "ceo" {
          selection = nil
          showingCEO = true
        } else if command == "list" {
          selection = nil
          showingCEO = false
          composing = false
        } else if command.hasPrefix("open:"), let number = Int(command.dropFirst(5)) {
          selection = tickets.ticket(number: number)?.id
        }
      }
    #endif
  }

  // MARK: List

  private func list(roster: [BotRosterEntry]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(roster: roster)
        .padding(EdgeInsets(top: 26, leading: 32, bottom: 18, trailing: 32))
      filters(roster: roster)
        .padding(.horizontal, 32)
        .padding(.bottom, 18)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if composing {
            TicketComposer(
              services: services, roster: roster, parent: nil,
              presetAssignee: composerAssignee ?? scope?.id,
              done: { ticket in
                composing = false
                composerAssignee = nil
                if let ticket { selection = ticket.id }
              }, report: { status = $0 }
            )
            .padding(.bottom, 16)
          }
          groups(roster: roster)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
      }
    }
  }

  private func header(roster: [BotRosterEntry]) -> some View {
    let waiting = needsYouCount
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text(scope.map { "\($0.name)’s tickets" } ?? "Tickets")
          .font(.ottoDisplay(24).weight(.semibold))
        Text(
          (scope == nil
            ? "Work you have handed to a bot" : "Tickets it owns, and parts it handed out")
            + (waiting == 0 ? "." : " · \(waiting) waiting on you")
        )
        .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      }
      Spacer()
      if scope == nil { ceoEntry(roster: roster) }
      Button {
        composing.toggle()
        if !composing { composerAssignee = nil }
      } label: {
        Label(composing ? "Cancel" : "New ticket", systemImage: composing ? "xmark" : "plus")
          .font(.ottoDisplay(12.5).weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 6)
      }
      .buttonStyle(OttoPrimaryButtonStyle())
      .accessibilityIdentifier("tickets.new")
    }
  }

  /// The way in to the CEO: its page when there is one, otherwise the offer to pick one once
  /// there are enough bots for a manager to be useful.
  @ViewBuilder private func ceoEntry(roster: [BotRosterEntry]) -> some View {
    if let chief = services.ceoProfile {
      Button {
        showingCEO = true
      } label: {
        HStack(spacing: 7) {
          if let entry = roster.first(where: { $0.profile.id == chief.id }) {
            BotAvatarView(presentation: avatar(entry), size: 16, showsStateBadge: false)
          }
          Text(chief.name)
          Text("CEO").font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
            .foregroundStyle(palette.signal)
        }
      }
      .buttonStyle(TicketPillButtonStyle())
      .fixedSize()
      .accessibilityIdentifier("tickets.ceo.open")
    } else if roster.count >= 2 {
      TicketChoice(
        options: roster.map { entry in
          TicketChoice.Option(id: entry.profile.id.uuidString, title: entry.profile.name) {
            do {
              try services.setCEO(profileID: entry.profile.id)
              showingCEO = true
            } catch {
              status = OttoStatusToast(kind: .error, title: error.localizedDescription)
            }
          }
        }
      ) {
        Text("Make a bot your CEO").font(.ottoDisplay(12.5).weight(.medium))
          .padding(.horizontal, 12).padding(.vertical, 6)
          .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      .fixedSize()
      .help("A CEO bot splits tickets up, hands them to your other bots and checks the results")
      .accessibilityIdentifier("tickets.ceo.pick")
    }
  }

  private func filters(roster: [BotRosterEntry]) -> some View {
    HStack(spacing: 6) {
      filterChip("All", count: visible(.all).count, tint: palette.muted, value: .all)
      filterChip(
        "Needs you", count: needsYouCount, tint: palette.signal, value: .needsYou)
      filterChip("Created by me", count: 0, tint: palette.muted, value: .mine)
      if !roster.isEmpty {
        Rectangle().fill(palette.paper.opacity(0.12)).frame(width: 1, height: 16)
          .padding(.horizontal, 4)
        TicketChoice(
          options: [TicketChoice.Option(id: "any", title: "Any bot") { botFilter = nil }]
            + roster.map { entry in
              TicketChoice.Option(id: entry.profile.id.uuidString, title: entry.profile.name) {
                botFilter = entry.profile.id
              }
            }
        ) {
          HStack(spacing: 6) {
            Text(roster.first { $0.profile.id == botFilter }?.profile.name ?? "Any bot")
              .font(.ottoDisplay(12.5))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
          }
          .foregroundStyle(botFilter == nil ? palette.muted : palette.paper)
          .padding(.horizontal, 10).padding(.vertical, 6)
        }
      }
      Spacer()
    }
  }

  private func filterChip(_ title: String, count: Int, tint: Color, value: Filter) -> some View {
    let active = filter == value
    return Button {
      filter = value
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(title).font(.ottoDisplay(12.5).weight(active ? .medium : .regular))
          .foregroundStyle(active ? palette.paper : palette.muted)
        if count > 0 {
          Text("\(count)").font(.ottoMono(9.5, weight: value == .needsYou ? .bold : .regular))
            .foregroundStyle(tint)
        }
      }
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(
        palette.paper.opacity(active ? 0.09 : 0),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var needsYouCount: Int {
    let roster = services.botRoster()
    return visible(.all).filter { needsYou($0, roster: roster) }.count
  }

  /// Waiting on the person: the ticket itself, or its bot stopped on a prompt in its chat.
  private func needsYou(_ ticket: Ticket, roster: [BotRosterEntry]) -> Bool {
    if ticket.needsPerson { return true }
    guard ticket.status == .doing else { return false }
    return roster.first { $0.profile.id == ticket.assigneeProfileID }?.needsYou == true
  }

  private func visible(_ filter: Filter) -> [Ticket] {
    tickets.all.filter { ticket in
      if let scope, ticket.assigneeProfileID != scope.id, ticket.creator != .bot(scope.id) {
        return false
      }
      if let botFilter, ticket.assigneeProfileID != botFilter { return false }
      switch filter {
      case .all: return true
      case .needsYou: return needsYou(ticket, roster: services.botRoster())
      case .mine: return ticket.creator == .person
      }
    }
  }

  @ViewBuilder private func groups(roster: [BotRosterEntry]) -> some View {
    let shown = visible(filter)
    let needs = shown.filter { needsYou($0, roster: roster) }
      .sorted { $0.updatedAt < $1.updatedAt }
    let rest = shown.filter { !needsYou($0, roster: roster) }
    let todo = rest.filter { $0.status == .todo }.sorted { $0.number > $1.number }
    let doing = rest.filter { $0.status == .doing }.sorted { $0.updatedAt > $1.updatedAt }
    let review = rest.filter { $0.status == .review }.sorted { $0.updatedAt > $1.updatedAt }
    let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
    let done = rest.filter { $0.status == .done && ($0.closedAt ?? $0.updatedAt) > weekAgo }
      .sorted { ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt) }

    if shown.isEmpty && !composing {
      empty
    }
    if !needs.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text("NEEDS YOU · \(needs.count)")
          .font(.ottoMono(9.5, weight: .bold)).tracking(1.9)
          .foregroundStyle(palette.signal)
          .padding(.bottom, 8)
        ForEach(needs) { ticket in
          TicketRow(
            ticket: ticket, tickets: tickets, roster: roster, avatar: avatar, prominent: true,
            open: { selection = ticket.id })
        }
      }
      .padding(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 20))
      .ottoGlass(cornerRadius: 12)
      .padding(.bottom, 6)
      .accessibilityIdentifier("tickets.needsYou")
    }
    section("To do", todo, roster: roster)
    section("Doing", doing, roster: roster)
    section("In review", review, roster: roster)
    section("Done · this week", done, roster: roster)
  }

  @ViewBuilder private func section(_ title: String, _ items: [Ticket], roster: [BotRosterEntry])
    -> some View
  {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          Text("\(title.uppercased()) · \(items.count)")
            .font(.ottoMono(9.5)).tracking(1.9).foregroundStyle(palette.muted)
          Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1)
        }
        .padding(.bottom, 2)
        ForEach(items) { ticket in
          TicketRow(
            ticket: ticket, tickets: tickets, roster: roster, avatar: avatar, prominent: false,
            open: { selection = ticket.id })
        }
      }
      .padding(EdgeInsets(top: 18, leading: 20, bottom: 0, trailing: 20))
    }
  }

  private var empty: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(tickets.all.isEmpty ? "No tickets yet." : "Nothing here.")
        .font(.ottoDisplay(15).weight(.semibold))
      Text(
        tickets.all.isEmpty
          ? "Write down a piece of work, give it to a bot, and it starts straight away. "
            + "The ticket keeps the story of how it went and tells you when it needs you."
          : "No tickets match this filter."
      )
      .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 24)
    .padding(.horizontal, 20)
    .accessibilityIdentifier("tickets.empty")
  }
}

// MARK: Row

/// One line in the list. The lanes are fixed widths so every row lines up.
private struct TicketRow: View {
  let ticket: Ticket
  @ObservedObject var tickets: TicketStore
  let roster: [BotRosterEntry]
  let avatar: (BotRosterEntry) -> BotAvatarPresentation
  let prominent: Bool
  let open: () -> Void
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    Button(action: open) {
      HStack(spacing: 14) {
        TicketStatusDot(ticket: ticket)
        Text(ticket.label).font(.ottoMono(10)).foregroundStyle(palette.muted.opacity(0.7))
          .frame(width: 38, alignment: .leading)
        VStack(alignment: .leading, spacing: 3) {
          Text(ticket.title)
            .font(
              .ottoDisplay(ticket.status == .done ? 13.5 : 14).weight(
                ticket.status == .done ? .regular : .semibold)
            )
            .foregroundStyle(palette.paper.opacity(ticket.status == .done ? 0.7 : 0.94))
            .lineLimit(1)
          if ticket.status != .done {
            Text(detail).font(.ottoDisplay(12))
              .foregroundStyle(warning ? palette.amber : palette.muted).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        owner.frame(width: 150, alignment: .leading)
        Text(origin).font(.ottoDisplay(12)).foregroundStyle(palette.muted).lineLimit(1)
          .frame(width: 130, alignment: .leading)
        trailing.frame(width: 84, alignment: .trailing)
      }
      .padding(.vertical, ticket.status == .done ? 9 : 11)
      .overlay(alignment: .top) {
        Rectangle().fill(palette.paper.opacity(prominent ? 0.08 : 0.06)).frame(height: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("tickets.row")
  }

  private var warning: Bool {
    ticket.status == .blocked || ticket.isUnreported || ticket.isUndelivered || ownerWaiting
  }
  /// The bot is asking for permission or an answer in its own chat.
  private var ownerWaiting: Bool { ticket.status == .doing && ownerEntry?.needsYou == true }

  private var detail: String {
    let parts = tickets.children(of: ticket.id)
    switch ticket.status {
    case .blocked:
      return "Stuck. \(ownerName) asks: \(ticket.question ?? "")"
    case .review:
      if ticket.reviewer == .person {
        return "Handed back. Ready for you to check."
      }
      return "Handed back · \(reviewerName) is checking it"
    case .doing:
      if ticket.isUnreported { return ticket.events.last?.text ?? "Went quiet." }
      if ticket.isStarting { return "Starting \(ownerName)…" }
      if ownerWaiting { return "\(ownerName) is asking you something before it can go on" }
      if !parts.isEmpty {
        let done = parts.filter { $0.status == .done }.count
        return "Split into \(parts.count) tickets · \(done) done"
      }
      return ticket.events.last { $0.kind == .note }?.text ?? "\(ownerName) is working on it"
    case .todo:
      if ticket.isHeld {
        return "Waiting for you to start it for \(ownerName)"
      }
      return ticket.assigneeProfileID == nil
        ? "Nobody owns this yet" : "This didn’t reach \(ownerName). Open it to send it again."
    case .done:
      return ""
    }
  }

  private var ownerEntry: BotRosterEntry? {
    roster.first { $0.profile.id == ticket.assigneeProfileID }
  }
  private var ownerName: String { ownerEntry?.profile.name ?? "The bot" }
  private var reviewerName: String {
    if case .bot(let id) = ticket.reviewer {
      return roster.first { $0.profile.id == id }?.profile.name ?? "A bot"
    }
    return "You"
  }

  @ViewBuilder private var owner: some View {
    if let entry = ownerEntry {
      HStack(spacing: 8) {
        BotAvatarView(presentation: avatar(entry), size: 18, showsStateBadge: false)
        Text(entry.profile.name).font(.ottoDisplay(12.5))
          .foregroundStyle(ticket.status == .done ? palette.muted : palette.paper).lineLimit(1)
      }
    } else {
      Text("No owner").font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
    }
  }

  private var origin: String {
    if ticket.status == .done {
      let who = ticket.events.last { $0.kind == .approved }?.actor ?? .person
      return "approved by \(TicketNames.lower(who, roster: roster))"
    }
    return "from \(TicketNames.lower(ticket.creator, roster: roster)) · "
      + TicketNames.ago(ticket.createdAt)
  }

  @ViewBuilder private var trailing: some View {
    if ownerWaiting {
      Text("Allow").font(.ottoDisplay(12.5).weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    } else if ticket.needsPerson {
      Text(
        ticket.status == .blocked
          ? "Answer" : ticket.isHeld ? "Start" : ticket.isUndelivered ? "Retry" : "Review"
      )
      .font(.ottoDisplay(12.5).weight(.medium))
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    } else if ticket.status == .done {
      Text((ticket.closedAt ?? ticket.updatedAt).formatted(.dateTime.weekday(.abbreviated)))
        .font(.ottoMono(10)).textCase(.uppercase).foregroundStyle(palette.muted)
    } else {
      Text("Open").font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
    }
  }
}

struct TicketStatusDot: View {
  let ticket: Ticket
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    Group {
      switch ticket.status {
      case .todo:
        Circle().strokeBorder(palette.muted, lineWidth: 1.5)
      case .doing:
        Circle().fill(ticket.isUnreported ? palette.amber : palette.cyan)
      case .blocked:
        Circle().fill(palette.amber)
      case .review:
        if ticket.reviewer == .person {
          Circle().fill(palette.signal)
        } else {
          Circle().strokeBorder(palette.cyan, lineWidth: 1.5)
        }
      case .done:
        Circle().fill(palette.muted.opacity(0.4))
      }
    }
    .frame(width: 8, height: 8)
  }
}

enum TicketNames {
  /// "you", a bot's name or a session's name, for the middle of a sentence.
  static func lower(_ party: Ticket.Party, roster: [BotRosterEntry]) -> String {
    switch party {
    case .person: "you"
    case .bot(let id): roster.first { $0.profile.id == id }?.profile.name ?? "a removed bot"
    case .session(let name): name
    }
  }

  static func title(_ party: Ticket.Party, roster: [BotRosterEntry]) -> String {
    party == .person ? "You" : lower(party, roster: roster)
  }

  /// A permission request without the harness's internal tool names:
  /// "Wants to use mcp__otto__bot_list" reads as "Use Otto's bot.list tool".
  nonisolated static func plainRequest(_ reason: String) -> String {
    var text = reason
    if text.lowercased().hasPrefix("wants to ") { text = String(text.dropFirst(9)) }
    if let range = text.range(of: #"mcp__otto__([a-z]+)_([a-z_]+)"#, options: .regularExpression) {
      let name = text[range].dropFirst(10)
      let parts = name.split(separator: "_", maxSplits: 1).map(String.init)
      let tool = parts.count == 2 ? "\(parts[0]).\(parts[1])" : String(name)
      text.replaceSubrange(range, with: "Otto’s \(tool) tool")
    }
    guard let first = text.first else { return reason }
    return first.uppercased() + text.dropFirst()
  }

  static func ago(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 90 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
    if seconds < 86_400 { return "\(Int(seconds / 3_600)) h" }
    return "\(Int(seconds / 86_400)) d"
  }
}

/// A quiet pill for card actions: raised fill, same weight for every action.
struct TicketPillButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    StyledLabel(configuration: configuration)
  }

  struct StyledLabel: View {
    @Environment(\.ottoPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
      configuration.label
        .font(.ottoDisplay(12.5).weight(.medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
          palette.raised.opacity(configuration.isPressed ? 0.7 : 1),
          in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .opacity(isEnabled ? 1 : 0.45)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .contentShape(Rectangle())
    }
  }
}

/// A choice from a short list, with a label drawn by the caller. A system Menu redraws its
/// label as plain text, which drops the chosen value and the pill behind it.
struct TicketChoice<Label: View>: View {
  struct Option: Identifiable {
    let id: String
    let title: String
    let action: () -> Void
  }

  let options: [Option]
  var emptyText: String?
  @ViewBuilder let label: () -> Label
  @State private var showing = false

  var body: some View {
    Button {
      showing.toggle()
    } label: {
      label().contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .popover(isPresented: $showing, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        if options.isEmpty, let emptyText {
          Text(emptyText).font(.ottoDisplay(12.5)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        ForEach(options) { option in
          Button {
            showing = false
            option.action()
          } label: {
            Text(option.title).font(.ottoDisplay(13))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10).padding(.vertical, 6)
              .contentShape(Rectangle())
          }
          .buttonStyle(OttoChromeButtonStyle())
        }
      }
      .padding(6)
      .frame(minWidth: 190)
    }
  }
}

// MARK: New ticket

/// The brief, written once: what to do, the limits, what comes back, who does it, who checks.
struct TicketComposer: View {
  @ObservedObject var services: ApplicationServices
  let roster: [BotRosterEntry]
  let parent: Ticket?
  var presetAssignee: UUID?
  let done: (Ticket?) -> Void
  let report: (OttoStatusToast) -> Void
  @Environment(\.ottoPalette) private var palette
  @State private var title = ""
  @State private var task = ""
  @State private var limits = ""
  @State private var handsBack = ""
  @State private var assignee: UUID?
  @State private var reviewer: UUID?
  @State private var working = false
  @FocusState private var titleFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("What needs doing?", text: $title)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(15).weight(.semibold))
        .focused($titleFocused)
        .accessibilityIdentifier("tickets.composer.title")
      field("TASK", "What to do, in a sentence or two", text: $task)
      field("LIMITS", "What it must not do, e.g. Drafts only, never send", text: $limits)
      field("HANDS BACK", "What you expect to get, e.g. A sheet of 20 leads", text: $handsBack)
      // Side by side when there is room; stacked in a narrow column so nothing gets crushed.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          pickers
          Spacer(minLength: 12)
          actions
        }
        VStack(alignment: .leading, spacing: 10) {
          pickers
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            actions
          }
        }
      }
      .padding(.top, 2)
    }
    .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
    .ottoGlass(cornerRadius: 12)
    .onAppear {
      titleFocused = true
      if assignee == nil { assignee = presetAssignee }
    }
    .onChange(of: assignee) { _, value in
      if value != nil, value == reviewer { reviewer = nil }
    }
    .accessibilityIdentifier("tickets.composer")
  }

  @ViewBuilder private var pickers: some View {
    picker("Give to", selection: $assignee, none: "Nobody yet", exclude: nil)
    picker("Reviewed by", selection: $reviewer, none: "You", exclude: assignee)
  }

  @ViewBuilder private var actions: some View {
    Button("Cancel") { done(nil) }
      .buttonStyle(.plain)
      .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      .fixedSize()
    Button {
      create()
    } label: {
      Text(assignee == nil ? "Add ticket" : "Start")
        .font(.ottoDisplay(12.5).weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
    .buttonStyle(OttoPrimaryButtonStyle())
    .fixedSize()
    .disabled(working || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    .accessibilityIdentifier("tickets.composer.create")
  }

  private func field(_ label: String, _ prompt: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.ottoMono(9)).tracking(1.5).foregroundStyle(palette.muted)
      TextField(prompt, text: text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.ottoDisplay(13))
        .lineLimit(1...4)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
          palette.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
  }

  private func picker(_ label: String, selection: Binding<UUID?>, none: String, exclude: UUID?)
    -> some View
  {
    TicketChoice(
      options: [TicketChoice.Option(id: "none", title: none) { selection.wrappedValue = nil }]
        + ceoFirst.filter { $0.profile.id != exclude }.map { entry in
          TicketChoice.Option(
            id: entry.profile.id.uuidString,
            title: services.isCEO(entry.profile.id)
              ? "\(entry.profile.name) · CEO" : entry.profile.name
          ) {
            selection.wrappedValue = entry.profile.id
          }
        }
    ) {
      HStack(spacing: 6) {
        Text(label).foregroundStyle(palette.muted)
        Text(roster.first { $0.profile.id == selection.wrappedValue }?.profile.name ?? none)
          .foregroundStyle(palette.paper)
        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
          .foregroundStyle(palette.muted)
      }
      .font(.ottoDisplay(12.5))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
  }

  /// The roster with the CEO at the top, since a goal usually goes to it.
  private var ceoFirst: [BotRosterEntry] {
    roster.filter { services.isCEO($0.profile.id) }
      + roster.filter { !services.isCEO($0.profile.id) }
  }

  private func create() {
    working = true
    let reviewerParty: Ticket.Party = reviewer.map { .bot($0) } ?? .person
    Task {
      defer { working = false }
      do {
        let ticket = try await services.createTicket(
          title: title, task: task, limits: limits, handsBack: handsBack, assignee: assignee,
          reviewer: reviewerParty, parentID: parent?.id)
        done(ticket)
      } catch {
        report(OttoStatusToast(kind: .error, title: error.localizedDescription))
        // A ticket that was saved but whose bot couldn't start is still on the list.
        if services.tickets.all.contains(where: { $0.title == title }) { done(nil) }
      }
    }
  }
}

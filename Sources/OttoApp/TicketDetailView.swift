import AppKit
import OttoModels
import OttoServices
import SwiftUI

/// One open ticket: how it went on the left, with whatever needs the person at the bottom of
/// the story; the brief, who is on it and its parts on the right.
struct TicketDetailView: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var tickets: TicketStore
  let ticket: Ticket
  let roster: [BotRosterEntry]
  let avatar: (BotRosterEntry) -> BotAvatarPresentation
  let openAgent: (UUID) -> Void
  let open: (UUID) -> Void
  let close: () -> Void
  let report: (OttoStatusToast) -> Void
  @Environment(\.ottoPalette) private var palette
  @State private var reply = ""
  @State private var working = false
  @State private var splitting = false
  @State private var confirmingDelete = false
  /// Standards Otto suggested from the send-back note, and the ones the person ticked.
  @State private var proposals: [StandardProposal] = []
  @State private var chosenProposals: Set<UUID> = []
  @State private var proposing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(EdgeInsets(top: 26, leading: 32, bottom: 22, trailing: 32))
      ScrollView {
        HStack(alignment: .top, spacing: 32) {
          story.frame(maxWidth: .infinity, alignment: .leading)
          rail
            .padding(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
            .frame(width: 320, alignment: .leading)
            .ottoGlass(cornerRadius: 12)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
      }
    }
    .onChange(of: ticket.id) { _, _ in
      reply = ""
      splitting = false
      confirmingDelete = false
      proposals = []
      chosenProposals = []
    }
    .accessibilityIdentifier("tickets.detail")
    #if DEBUG
      .onReceive(NotificationCenter.default.publisher(for: OttoDevProbe.ticketNotification)) {
        note in
        if (note.object as? String) == "part" { splitting = true }
      }
    #endif
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(ticket.title).font(.ottoDisplay(24).weight(.semibold))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          Button("Tickets", action: close)
            .buttonStyle(.plain).foregroundStyle(palette.cyan)
            .accessibilityIdentifier("tickets.back")
          Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            .foregroundStyle(palette.muted)
          if let parent = ticket.parentID.flatMap({ tickets.ticket(id: $0) }) {
            Button(parent.label) { open(parent.id) }
              .buttonStyle(.plain).foregroundStyle(palette.cyan)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
              .foregroundStyle(palette.muted)
          }
          Text("\(ticket.label) · \(statusLine)").foregroundStyle(palette.muted)
        }
        .font(.ottoDisplay(12.5))
      }
      Spacer(minLength: 12)
      if let nodeID = ticket.agentNodeID {
        Button {
          openAgent(nodeID)
        } label: {
          Label("Open chat", systemImage: "bubble.left")
        }
        .buttonStyle(TicketPillButtonStyle())
      }
      Menu {
        if ticket.isOpen {
          Button("Mark as done") { decide(approve: true, note: "Closed by you.") }
        }
        Button("Delete ticket", role: .destructive) { confirmingDelete = true }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
          .frame(width: 30, height: 28)
          .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  private var statusLine: String {
    let from = TicketNames.lower(ticket.creator, roster: roster)
    let when = TicketNames.ago(ticket.createdAt)
    let age = when == "just now" ? when : "\(when) ago"
    switch ticket.status {
    case .todo:
      if ticket.isHeld { return "waiting for you to start it" }
      return ticket.isUndelivered
        ? "this didn’t reach \(ownerName)" : "created by \(from) \(age) · not started"
    case .doing:
      if ticket.isStarting { return "starting \(ownerName)…" }
      if let waiting = ownerWaiting {
        return waiting.state == .waitingPermission
          ? "\(ownerName) is asking to do something" : "\(ownerName) has a question for you"
      }
      return "\(ownerName) is working on it · from \(from), \(age)"
    case .blocked: return "\(ownerName) is stuck and needs you"
    case .review: return "handed back · \(reviewerName) to check"
    case .done: return "done"
    }
  }

  private var ownerEntry: BotRosterEntry? {
    roster.first { $0.profile.id == ticket.assigneeProfileID }
  }
  private var ownerName: String { ownerEntry?.profile.name ?? "Nobody" }
  /// The bot's own chat is stopped on a permission prompt or a question while it works this.
  private var ownerWaiting: AgentAttentionItem? {
    guard ticket.status == .doing else { return nil }
    let nodeID = ownerEntry?.nodeID ?? ticket.agentNodeID
    return services.attentionItems.first {
      $0.nodeID == nodeID && ($0.state == .waitingPermission || $0.state == .waitingUser)
    }
  }
  private var reviewerName: String { TicketNames.lower(ticket.reviewer, roster: roster) }

  // MARK: Story

  /// The ticket as a page: what was asked, what came back, then the short record of who did
  /// what. The output is the thing to read; the record stays out of its way.
  private var story: some View {
    VStack(alignment: .leading, spacing: 0) {
      brief
      resultSection
        .padding(.top, 22)
      TicketCheckView(ticket: ticket)
        .padding(.top, ticket.latestCheck == nil ? 0 : 12)
      decision
        .padding(.top, 12)
      partsSection
        .padding(.top, 22)
      activity
        .padding(.top, 26)
      if confirmingDelete {
        deleteConfirmation.padding(.top, 14)
      }
    }
  }

  private var brief: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(ticket.task).font(.ottoDisplay(14)).lineSpacing(4)
        .foregroundStyle(palette.paper.opacity(0.92))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if let limits = ticket.limits { briefLine("LIMITS", limits) }
      if let handsBack = ticket.handsBack { briefLine("HANDS BACK", handsBack) }
    }
  }

  /// What the bot handed back, set as a document rather than a chat message.
  @ViewBuilder private var resultSection: some View {
    if let result = ticket.result, !result.isEmpty {
      let handed = ticket.events.last { $0.kind == .handedBack }
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("Result").font(.ottoDisplay(17).weight(.semibold))
          if let handed {
            Text(
              "from \(TicketNames.lower(handed.actor, roster: roster)) · "
                + handed.at.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.ottoDisplay(12)).foregroundStyle(palette.muted)
          }
          Spacer(minLength: 8)
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            report(OttoStatusToast(kind: .success, title: "Copied the result"))
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(TicketPillButtonStyle())
          .accessibilityIdentifier("tickets.copyResult")
        }
        MarkdownMessageView(text: result, scale: 1.15, palette: palette)
          .textSelection(.enabled)
      }
      .padding(EdgeInsets(top: 20, leading: 24, bottom: 22, trailing: 24))
      .frame(maxWidth: .infinity, alignment: .leading)
      .ottoGlass(cornerRadius: 12)
      .accessibilityIdentifier("tickets.result")
    }
  }

  @ViewBuilder private var partsSection: some View {
    let children = tickets.children(of: ticket.id)
    let canSplit = ticket.isOpen && tickets.depth(of: ticket.id) + 1 < TicketStore.maximumDepth
    if !children.isEmpty || canSplit || splitting {
      VStack(alignment: .leading, spacing: 0) {
        if !children.isEmpty {
          label("Split into · \(children.count)")
          ForEach(children) { child in
            Button {
              open(child.id)
            } label: {
              HStack(spacing: 10) {
                TicketStatusDot(ticket: child)
                Text(child.label).font(.ottoMono(10)).foregroundStyle(palette.muted)
                  .frame(width: 38, alignment: .leading)
                Text(child.title).font(.ottoDisplay(13).weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(partLine(child)).font(.ottoDisplay(12))
                  .foregroundStyle(child.needsPerson ? palette.signal : palette.muted)
                  .lineLimit(1)
              }
              .frame(height: 38)
              .overlay(alignment: .bottom) {
                Rectangle().fill(palette.paper.opacity(0.06)).frame(height: 1)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        if splitting {
          TicketComposer(
            services: services, roster: roster, parent: ticket,
            done: { _ in splitting = false }, report: report
          )
          .padding(.top, 10)
        } else if canSplit {
          Button {
            splitting = true
          } label: {
            Label("Add a part", systemImage: "plus").font(.ottoDisplay(12.5))
              .foregroundStyle(palette.muted)
          }
          .buttonStyle(.plain)
          .padding(.top, children.isEmpty ? 0 : 10)
          .accessibilityIdentifier("tickets.addPart")
        }
      }
    }
  }

  /// Who did what, one line each. Only things somebody actually said (a reason, a question,
  /// a note with a review) get room; an earlier result that was sent back is kept here too.
  private var activity: some View {
    let latestResult = ticket.events.last { $0.kind == .handedBack }?.id
    return VStack(alignment: .leading, spacing: 0) {
      Text("Activity").font(.ottoDisplay(15).weight(.semibold))
        .padding(.bottom, 8)
      ForEach(ticket.events) { event in
        TicketEventRow(
          event: event, roster: roster, avatar: avatar,
          isLatestResult: event.id == latestResult)
      }
    }
  }

  /// Whatever the person has to do next, in place at the end of the story.
  @ViewBuilder private var decision: some View {
    if ticket.status == .review, ticket.reviewer == .person {
      card(
        title: "Does this do the job?", tag: "Needs you",
        caption: "Approve it, or send it back to \(ownerName) with what should change."
      ) {
        noteField("What should change? (only needed to send it back)")
        if !proposals.isEmpty {
          StandardProposalsView(proposals: proposals, selected: $chosenProposals)
        }
        HStack(spacing: 8) {
          Button {
            decide(approve: true, note: reply)
          } label: {
            Text("Approve").font(.ottoDisplay(12.5).weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(OttoPrimaryButtonStyle())
          .accessibilityIdentifier("tickets.approve")
          Button(sendBackTitle) { sendBack() }
            .buttonStyle(TicketPillButtonStyle())
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("tickets.sendBack")
          if ticket.assigneeProfileID != nil, proposals.isEmpty {
            Spacer(minLength: 8)
            if proposing {
              ProgressView().controlSize(.small)
            } else {
              Button("Keep this for next time?") { proposeStandards() }
                .buttonStyle(.plain)
                .font(.ottoDisplay(12)).foregroundStyle(palette.cyan)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("tickets.proposeStandards")
            }
          }
        }
        .disabled(working)
      }
    } else if ticket.isChecking {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Handed back. Another model is checking it against its standards before review…")
          .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      }
      .accessibilityIdentifier("tickets.checking")
    } else if ticket.status == .blocked {
      card(
        title: "\(ownerName) is stuck", tag: "Needs you",
        caption: "Your answer goes straight back and it carries on."
      ) {
        quoted("QUESTION", ticket.question ?? "")
        noteField("Your answer")
        Button {
          answer(reply)
        } label: {
          Text("Send answer").font(.ottoDisplay(12.5).weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(OttoPrimaryButtonStyle())
        .disabled(working || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("tickets.answer")
      }
    } else if ticket.isUnreported {
      card(
        title: "\(ownerName) went quiet", tag: "Needs you",
        caption: "It stopped without handing this back or saying it was stuck."
      ) {
        HStack(spacing: 8) {
          Button {
            answer(
              "You stopped without reporting on this ticket. Carry on, then hand it back or "
                + "say what you are stuck on.")
          } label: {
            Text("Ask it to carry on").font(.ottoDisplay(12.5).weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(OttoPrimaryButtonStyle())
          if let nodeID = ticket.agentNodeID {
            Button("Open chat") { openAgent(nodeID) }.buttonStyle(TicketPillButtonStyle())
          }
          Button("Mark as done") { decide(approve: true, note: "Closed by you.") }
            .buttonStyle(TicketPillButtonStyle())
        }
        .disabled(working)
      }
    } else if ticket.isHeld {
      card(
        title:
          "\(TicketNames.title(ticket.creator, roster: roster)) wants to give this to "
          + ownerName,
        tag: "Needs you",
        caption: "You asked to start each part yourself. Nothing has been sent to \(ownerName)."
      ) {
        HStack(spacing: 8) {
          Button {
            let id = ticket.id
            run { try await services.startHeldTicket(id: id) }
          } label: {
            Text("Start").font(.ottoDisplay(12.5).weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(OttoPrimaryButtonStyle())
          .accessibilityIdentifier("tickets.start")
          assignMenu(label: "Give to another bot")
          Button("Don’t do this") {
            let id = ticket.id
            run {
              try await services.declineHeldTicket(id: id)
              close()
            }
          }
          .buttonStyle(TicketPillButtonStyle())
          .accessibilityIdentifier("tickets.decline")
        }
        .disabled(working)
      }
    } else if ticket.isUndelivered, let owner = ticket.assigneeProfileID {
      card(
        title: "This didn’t reach \(ownerName)", tag: "Needs you",
        caption: "Nothing has been done yet. Send it again, or give it to another bot."
      ) {
        HStack(spacing: 8) {
          Button {
            assign(owner)
          } label: {
            Text("Send again").font(.ottoDisplay(12.5).weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(OttoPrimaryButtonStyle())
          .accessibilityIdentifier("tickets.sendAgain")
          assignMenu(label: "Give to another bot")
        }
        .disabled(working)
      }
    } else if ticket.status == .doing, let waiting = ownerWaiting {
      if waiting.state == .waitingPermission {
        card(
          title: "\(ownerName) is asking to do something", tag: "Needs you",
          caption: "It can't go on with this ticket until you decide."
        ) {
          quoted("WANTS TO", TicketNames.plainRequest(waiting.reason))
          HStack(spacing: 8) {
            Button {
              answerPermission(waiting.nodeID, allow: true)
            } label: {
              Text("Allow").font(.ottoDisplay(12.5).weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .buttonStyle(OttoPrimaryButtonStyle())
            .accessibilityIdentifier("tickets.allow")
            Button("Deny") { answerPermission(waiting.nodeID, allow: false) }
              .buttonStyle(TicketPillButtonStyle())
              .accessibilityIdentifier("tickets.deny")
            Button("Open its chat") { openAgent(waiting.nodeID) }
              .buttonStyle(TicketPillButtonStyle())
          }
          .disabled(working)
        }
      } else {
        card(
          title: "\(ownerName) has a question", tag: "Needs you",
          caption: "It asked in its own chat and is waiting for your reply."
        ) {
          if !waiting.reason.isEmpty { quoted("ASKS", waiting.reason) }
          Button {
            openAgent(waiting.nodeID)
          } label: {
            Text("Reply in its chat").font(.ottoDisplay(12.5).weight(.semibold))
              .padding(.horizontal, 12).padding(.vertical, 6)
          }
          .buttonStyle(OttoPrimaryButtonStyle())
        }
      }
    } else if ticket.isStarting {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Starting \(ownerName) and handing it the brief…")
          .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
      }

    } else if ticket.status == .todo {
      card(
        title: "Nobody is on this yet", tag: nil,
        caption: "Give it to a bot and it starts straight away."
      ) {
        assignMenu(label: "Give to a bot")
      }
    } else if ticket.status == .review {
      Text("\(TicketNames.title(ticket.reviewer, roster: roster)) is checking the work.")
        .font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)

    }
  }

  private var deleteConfirmation: some View {
    card(
      title: "Delete \(ticket.label)?", tag: nil,
      caption: "The ticket and its story are removed. Work already done stays where it is."
    ) {
      HStack(spacing: 8) {
        Button("Delete") {
          do {
            try services.deleteTicket(id: ticket.id)
            close()
          } catch {
            report(OttoStatusToast(kind: .error, title: error.localizedDescription))
          }
        }
        .buttonStyle(TicketPillButtonStyle())
        .foregroundStyle(palette.red)
        Button("Keep it") { confirmingDelete = false }.buttonStyle(TicketPillButtonStyle())
      }
    }
  }

  private func card<Content: View>(
    title: String, tag: String?, caption: String?, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(title).font(.ottoDisplay(15).weight(.semibold))
        Spacer(minLength: 8)
        if let tag {
          Text(tag.uppercased()).font(.ottoMono(8.5, weight: .bold)).tracking(1.2)
            .foregroundStyle(palette.signal)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(palette.signal.opacity(0.35)))
        }
      }
      if let caption {
        Text(caption).font(.ottoDisplay(12.5)).foregroundStyle(palette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      content()
    }
    .padding(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
    .frame(maxWidth: .infinity, alignment: .leading)
    .ottoGlass(cornerRadius: 12)
  }

  private func quoted(_ label: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.ottoMono(9)).tracking(1.5).foregroundStyle(palette.muted)
      Text(text).font(.ottoDisplay(13)).lineSpacing(3)
        .foregroundStyle(palette.paper.opacity(0.9))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 14).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      palette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private func noteField(_ prompt: String) -> some View {
    TextField(prompt, text: $reply, axis: .vertical)
      .textFieldStyle(.plain)
      .font(.ottoDisplay(13))
      .lineLimit(1...5)
      .padding(.horizontal, 10).padding(.vertical, 8)
      .background(
        palette.ink.opacity(0.48), in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .accessibilityIdentifier("tickets.reply")
  }

  // MARK: Rail

  private var rail: some View {
    VStack(alignment: .leading, spacing: 0) {
      label("Properties")
      whoRow("Status") {
        TicketStatusDot(ticket: ticket)
        Text(statusWord).font(.ottoDisplay(13).weight(.medium))
        Spacer(minLength: 4)
      }
      whoRow("Owner") {
        if let entry = ownerEntry {
          BotAvatarView(presentation: avatar(entry), size: 20, showsStateBadge: false)
          Text(entry.profile.name).font(.ottoDisplay(13).weight(.medium))
        } else {
          Text("Nobody yet").font(.ottoDisplay(13)).foregroundStyle(palette.muted)
        }
        Spacer(minLength: 4)
        if ticket.isOpen { assignMenu(label: "Change", quiet: true) }
      }
      whoRow("Reviewer") {
        partyBadge(ticket.reviewer)
        Text(TicketNames.title(ticket.reviewer, roster: roster))
          .font(.ottoDisplay(13).weight(.medium))
        Spacer(minLength: 4)
      }
      whoRow("From") {
        partyBadge(ticket.creator)
        Text(TicketNames.title(ticket.creator, roster: roster))
          .font(.ottoDisplay(13).weight(.medium))
        Spacer(minLength: 4)
      }
      whoRow("Created") {
        Text(ticket.createdAt.formatted(date: .abbreviated, time: .shortened))
          .font(.ottoDisplay(13))
        Spacer(minLength: 4)
      }
      if let parent = ticket.parentID.flatMap({ tickets.ticket(id: $0) }) {
        whoRow("Part of") {
          Button {
            open(parent.id)
          } label: {
            Text("\(parent.label) \(parent.title)").font(.ottoDisplay(13)).lineLimit(1)
              .foregroundStyle(palette.cyan)
          }
          .buttonStyle(.plain)
          Spacer(minLength: 4)
        }
      }
    }
  }

  private var statusWord: String {
    switch ticket.status {
    case .todo:
      ticket.isHeld ? "Waiting to start" : ticket.isUndelivered ? "Not delivered" : "To do"
    case .doing: ticket.isStarting ? "Starting" : ticket.isUnreported ? "Went quiet" : "Doing"
    case .blocked: "Stuck"
    case .review: "In review"
    case .done: "Done"
    }
  }

  private func partLine(_ child: Ticket) -> String {
    let owner = roster.first { $0.profile.id == child.assigneeProfileID }?.profile.name
    let state: String =
      switch child.status {
      case .todo: "not started"
      case .doing: child.isUnreported ? "went quiet" : "working"
      case .blocked: "stuck, needs you"
      case .review:
        child.reviewer == .person ? "waiting on you" : "in review"
      case .done: "done"
      }
    return [owner, state].compactMap { $0 }.joined(separator: " · ")
  }

  private func briefLine(_ label: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.ottoMono(9)).tracking(1.5).foregroundStyle(palette.muted)
      Text(text).font(.ottoDisplay(13)).lineSpacing(3)
        .foregroundStyle(palette.paper.opacity(0.9))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func whoRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    HStack(spacing: 10) {
      Text(title).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
        .frame(width: 64, alignment: .leading)
      content()
    }
    .frame(height: 40)
  }

  @ViewBuilder private func partyBadge(_ party: Ticket.Party) -> some View {
    if case .bot(let id) = party, let entry = roster.first(where: { $0.profile.id == id }) {
      BotAvatarView(presentation: avatar(entry), size: 20, showsStateBadge: false)
    } else {
      Circle().fill(palette.paper.opacity(0.15)).frame(width: 20, height: 20)
    }
  }

  private func assignMenu(label title: String, quiet: Bool = false) -> some View {
    TicketChoice(
      options: roster.filter { ticket.reviewer != .bot($0.profile.id) }.map { entry in
        TicketChoice.Option(id: entry.profile.id.uuidString, title: entry.profile.name) {
          assign(entry.profile.id)
        }
      },
      emptyText: "Hire a bot first"
    ) {
      if quiet {
        Text(title).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
      } else {
        HStack(spacing: 6) {
          Text(title).font(.ottoDisplay(12.5).weight(.medium))
          Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      }
    }
    .disabled(working)
    .accessibilityIdentifier("tickets.assign")
  }

  private func label(_ text: String) -> some View {
    HStack(spacing: 10) {
      Text(text.uppercased()).font(.ottoMono(9.5)).tracking(1.9).foregroundStyle(palette.muted)
      Rectangle().fill(palette.paper.opacity(0.08)).frame(height: 1)
    }
    .padding(.bottom, 4)
  }

  // MARK: Actions

  private func run(_ work: @escaping @MainActor () async throws -> Void) {
    working = true
    Task {
      defer { working = false }
      do {
        try await work()
        reply = ""
      } catch {
        report(OttoStatusToast(kind: .error, title: error.localizedDescription))
      }
    }
  }

  private func decide(approve: Bool, note: String) {
    let id = ticket.id
    run { try await services.reviewTicket(id: id, approve: approve, note: note) }
  }

  private var sendBackTitle: String {
    chosenProposals.isEmpty
      ? "Send back with a note"
      : "Send back and save \(chosenProposals.count) to \(ownerName)"
  }

  /// Sends the work back, saving any standards the person ticked to the bot first.
  private func sendBack() {
    let id = ticket.id
    let note = reply
    let label = ticket.label
    let owner = ticket.assigneeProfileID
    let keep = proposals.filter { chosenProposals.contains($0.id) }.map(\.text)
    run {
      if let owner, !keep.isEmpty {
        try services.addBotStandards(keep, source: .note(ticket: label), to: owner)
      }
      try await services.reviewTicket(id: id, approve: false, note: note)
      proposals = []
      chosenProposals = []
    }
  }

  private func proposeStandards() {
    let id = ticket.id
    let note = reply
    proposing = true
    Task {
      defer { proposing = false }
      do {
        let found = try await services.proposeStandards(ticketID: id, note: note)
        proposals = found
        chosenProposals = Set(found.filter(\.catchesIt).map(\.id))
        if found.isEmpty {
          report(OttoStatusToast(kind: .info, title: "No standard came out of that note"))
        }
      } catch {
        report(OttoStatusToast(kind: .error, title: error.localizedDescription))
      }
    }
  }

  private func answer(_ text: String) {
    let id = ticket.id
    run { try await services.answerTicket(id: id, text: text) }
  }

  private func answerPermission(_ nodeID: UUID, allow: Bool) {
    run { await services.resolveAgentPermission(agentID: nodeID, approved: allow) }
  }

  private func assign(_ profileID: UUID) {
    let id = ticket.id
    run { try await services.assignTicket(id: id, to: profileID) }
  }
}

// MARK: Activity row

/// One step in a ticket's record. Most are a single quiet line ("Coder handed it back");
/// something a person or bot actually said sits in a small comment under its line.
private struct TicketEventRow: View {
  let event: Ticket.Event
  let roster: [BotRosterEntry]
  let avatar: (BotRosterEntry) -> BotAvatarPresentation
  let isLatestResult: Bool
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        badge.frame(width: 16, height: 16)
        Text(line).font(.ottoDisplay(12.5)).foregroundStyle(tint)
          .fixedSize(horizontal: false, vertical: true)
        Text(event.at.formatted(date: .omitted, time: .shortened))
          .font(.ottoMono(9.5)).foregroundStyle(palette.muted.opacity(0.7))
        Spacer(minLength: 0)
      }
      if let comment {
        Text(comment).font(.ottoDisplay(13)).lineSpacing(3)
          .foregroundStyle(palette.paper.opacity(0.9))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            palette.raised.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(.leading, 24)
      }
    }
    .padding(.vertical, 6)
    .accessibilityIdentifier("tickets.event.\(event.kind.rawValue)")
  }

  private var name: String { TicketNames.title(event.actor, roster: roster) }

  /// The step as a sentence.
  private var line: String {
    switch event.kind {
    case .created: "\(name) created this"
    case .assigned: event.text
    case .note: "\(name) explained a decision"
    case .handedBack:
      isLatestResult ? "\(name) handed it back" : "\(name) handed back an earlier version"
    case .blocked: "\(name) got stuck and asked"
    case .answered: "\(name) answered"
    case .approved: "\(name) approved it"
    case .sentBack: "\(name) sent it back"
    case .unreported, .problem: event.text
    case .checked: "Otto’s checker: \(event.text)"
    }
  }

  /// What was actually said, when it is more than the line already tells.
  private var comment: String? {
    switch event.kind {
    case .note, .blocked, .answered, .sentBack:
      return event.text.isEmpty ? nil : event.text
    case .approved:
      return ["Approved.", "Closed by you."].contains(event.text) || event.text.isEmpty
        ? nil : event.text
    case .handedBack:
      // The latest result is the page's main content; older ones are kept here.
      return isLatestResult ? nil : event.text
    case .created, .assigned, .unreported, .problem, .checked:
      return nil
    }
  }

  /// Otto's own notices, as opposed to something a person or bot did.
  private var quiet: Bool {
    event.kind == .assigned || event.kind == .unreported || event.kind == .problem
      || event.kind == .checked
  }

  private var tint: Color {
    switch event.kind {
    case .unreported: palette.amber
    case .problem: palette.red
    default: palette.paper.opacity(0.8)
    }
  }

  private var badgeSymbol: String {
    switch event.kind {
    case .assigned: "arrow.turn.down.right"
    case .checked: "checkmark.seal"
    default: "exclamationmark"
    }
  }

  @ViewBuilder private var badge: some View {
    if quiet {
      Image(systemName: badgeSymbol)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(event.kind == .assigned || event.kind == .checked ? palette.muted : tint)
    } else if case .bot(let id) = event.actor,
      let entry = roster.first(where: { $0.profile.id == id })
    {
      BotAvatarView(presentation: avatar(entry), size: 16, showsStateBadge: false)
    } else {
      Circle().fill(palette.paper.opacity(0.18))
    }
  }
}

extension String {
  fileprivate var capitalizedFirst: String {
    guard let first else { return self }
    return first.uppercased() + dropFirst()
  }
}

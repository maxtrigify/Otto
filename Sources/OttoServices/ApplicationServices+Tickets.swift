import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools

// MARK: Tickets
//
// A ticket is work handed to a bot. Giving it to a bot starts that bot on it straight away;
// the bot must end by handing it back (ticket.complete) or saying what it is stuck on
// (ticket.block). Handed-back work waits for its reviewer: the person, or another bot, never
// the bot that did it. Every step lands on the ticket as an event, so the ticket reads as the
// story of how the work went.

extension ApplicationServices {
  // MARK: What the person does

  /// Makes a ticket and, when it has an owner, starts that bot on it.
  @discardableResult
  public func createTicket(
    title: String, task: String = "", limits: String? = nil, handsBack: String? = nil,
    assignee: UUID? = nil, reviewer: Ticket.Party = .person, parentID: UUID? = nil,
    creator: Ticket.Party = .person, creatorNodeID: UUID? = nil, why: String? = nil,
    standards: [String] = [], hold: Bool = false
  ) async throws -> Ticket {
    if let assignee, reviewer == .bot(assignee) { throw TicketStore.TicketError.ownReview }
    var ticket = Ticket(
      title: title, task: task, limits: limits, handsBack: handsBack, reviewer: reviewer,
      creator: creator, parentID: parentID)
    let ownStandards = standards.map(StandardsStore.clean).filter { !$0.isEmpty }
    ticket.standards = ownStandards.isEmpty ? nil : Array(ownStandards.prefix(10))
    ticket.events = [Ticket.Event(kind: .created, actor: creator, text: TicketStore.clip(task))]
    if let why = why.map(TicketStore.clip), !why.isEmpty {
      ticket.events.append(Ticket.Event(kind: .note, actor: creator, text: why))
    }
    ticket = try tickets.add(ticket)
    guard let assignee else { return ticket }
    if hold { return try holdTicket(id: ticket.id, for: assignee, by: creator) }
    return try await assignTicket(
      id: ticket.id, to: assignee, by: creator, actorNodeID: creatorNodeID)
  }

  /// Names the bot a ticket is meant for without starting it: the person starts it, gives it
  /// to someone else, or drops it. Used when the CEO is set to ask before handing work out.
  @discardableResult
  func holdTicket(id: UUID, for profileID: UUID, by actor: Ticket.Party) throws -> Ticket {
    guard let profile = agentProfiles.activeProfiles.first(where: { $0.id == profileID }) else {
      throw ToolRegistryError.invalidInput("That bot is no longer available.")
    }
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    guard current.reviewer != .bot(profileID) else { throw TicketStore.TicketError.ownReview }
    let from = Self.ticketPartyName(actor, profiles: agentProfiles.activeProfiles)
    return try tickets.update(id: id) { ticket in
      ticket.assigneeProfileID = profileID
      ticket.status = .todo
      ticket.awaitingGoAhead = true
      ticket.dispatchedAt = nil
      ticket.events.append(
        Ticket.Event(
          kind: .assigned, actor: actor,
          text: "\(from) wants to give this to \(profile.name). Waiting for you to start it."))
    }
  }

  /// The person's go-ahead on a held ticket: it starts as if its creator had just handed it out.
  public func startHeldTicket(id: UUID) async throws {
    guard let current = tickets.ticket(id: id), current.isHeld,
      let profileID = current.assigneeProfileID
    else { throw TicketStore.TicketError.wrongStatus("That ticket isn't waiting to be started.") }
    _ = try tickets.update(id: id) { $0.awaitingGoAhead = nil }
    do {
      try await assignTicket(id: id, to: profileID, by: current.creator)
    } catch {
      // assignTicket has already written why; the ticket now reads as not delivered.
      throw error
    }
  }

  /// The person decides a held ticket shouldn't happen. Its creator is told, so a manager can
  /// carry on without that part instead of waiting for it.
  public func declineHeldTicket(id: UUID) async throws {
    guard let current = tickets.ticket(id: id), current.isHeld else {
      throw TicketStore.TicketError.wrongStatus("That ticket isn't waiting to be started.")
    }
    try tickets.remove(id: id)
    guard case .bot(let creatorID) = current.creator else { return }
    let parent = current.parentID.flatMap { tickets.ticket(id: $0) }
    _ = try? await promptTicketBot(
      profileID: creatorID,
      message: """
        The person decided not to start \(current.label) (\(current.title)), so it has been \
        removed.
        """,
      hidden: parent.map {
        """
        That was a part of \($0.label). Carry on without it: do it another way, or hand \
        \($0.label) back with what you have and say what is missing.
        """
      } ?? "Nothing is required.")
  }

  /// Gives a ticket to a bot and starts it. A bot taking its own ticket just carries on in the
  /// turn it is already in.
  @discardableResult
  public func assignTicket(
    id: UUID, to profileID: UUID, by actor: Ticket.Party = .person, actorNodeID: UUID? = nil
  ) async throws -> Ticket {
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    guard current.isOpen else {
      throw TicketStore.TicketError.wrongStatus("\(current.label) is already done.")
    }
    guard let profile = agentProfiles.activeProfiles.first(where: { $0.id == profileID }) else {
      throw ToolRegistryError.invalidInput("That bot is no longer available.")
    }
    guard current.reviewer != .bot(profileID) else { throw TicketStore.TicketError.ownReview }
    let ticket = try tickets.update(id: id) { ticket in
      ticket.assigneeProfileID = profileID
      ticket.status = .doing
      ticket.question = nil
      // Until the brief reaches the bot the ticket reads as "starting", not "working".
      ticket.dispatchedAt = nil
      ticket.awaitingGoAhead = nil
      ticket.events.append(
        Ticket.Event(kind: .assigned, actor: actor, text: "Given to \(profile.name)."))
    }
    if actor == .bot(profileID) {
      return try tickets.update(id: id) { ticket in
        ticket.agentNodeID = actorNodeID ?? ticket.agentNodeID
        ticket.dispatchedAt = .now
      }
    }
    let from = Self.ticketPartyName(actor, profiles: agentProfiles.activeProfiles)
    do {
      try await dispatchTicket(
        ticket,
        message: """
          New ticket \(ticket.label) from \(from == "You" ? "the person" : from): \(ticket.title)

          \(ticket.brief)
          """)
    } catch {
      _ = try? tickets.update(id: id) { ticket in
        ticket.status = .todo
        ticket.events.append(
          Ticket.Event(
            kind: .problem, actor: .person,
            text: Self.ticketStartFailure(error, bot: profile.name)))
      }
      throw error
    }
    return tickets.ticket(id: id) ?? ticket
  }

  /// The person's answer to a blocked ticket goes back to the bot, which carries on.
  public func answerTicket(id: UUID, text: String) async throws {
    let answer = TicketStore.clip(text)
    guard !answer.isEmpty else { return }
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    guard current.status == .blocked || current.isUnreported else {
      throw TicketStore.TicketError.wrongStatus("\(current.label) isn't waiting on an answer.")
    }
    let ticket = try tickets.update(id: id) { ticket in
      ticket.status = .doing
      ticket.question = nil
      ticket.events.append(Ticket.Event(kind: .answered, actor: .person, text: answer))
    }
    try await redispatch(
      ticket,
      message: """
        The person answered on ticket \(ticket.label) (\(ticket.title)):
        <<<answer>>>
        \(answer)
        <<<end>>>
        Carry on with the ticket.
        """)
  }

  /// Approve or send back handed-back work. `actor` is who decided; a bot can only decide on
  /// tickets it is the reviewer of, and never on its own work.
  public func reviewTicket(
    id: UUID, approve: Bool, note: String? = nil, by actor: Ticket.Party = .person
  ) async throws {
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    let note = note.map(TicketStore.clip).flatMap { $0.isEmpty ? nil : $0 }
    if actor != .person {
      guard current.reviewer == actor || ceoMayReviewForPerson(current, actor: actor) else {
        throw TicketStore.TicketError.wrongStatus(
          "You are not the reviewer of \(current.label).")
      }
      if let assignee = current.assigneeProfileID, actor == .bot(assignee) {
        throw TicketStore.TicketError.ownReview
      }
    }
    if approve {
      // The person can close a ticket at any point; a bot only once the work is handed back.
      guard actor == .person ? current.isOpen : current.status == .review else {
        throw TicketStore.TicketError.wrongStatus("\(current.label) isn't waiting for review.")
      }
      let ticket = try tickets.update(id: id) { ticket in
        ticket.status = .done
        ticket.closedAt = .now
        ticket.question = nil
        ticket.events.append(
          Ticket.Event(kind: .approved, actor: actor, text: note ?? "Approved."))
      }
      await tellCreatorTicketIsDone(ticket, decidedBy: actor)
      return
    }
    guard current.status == .review else {
      throw TicketStore.TicketError.wrongStatus("\(current.label) isn't waiting for review.")
    }
    guard let note else {
      throw ToolRegistryError.invalidInput("Say what needs to change when sending work back.")
    }
    let ticket = try tickets.update(id: id) { ticket in
      ticket.status = .doing
      ticket.events.append(Ticket.Event(kind: .sentBack, actor: actor, text: note))
    }
    let who = Self.ticketPartyName(actor, profiles: agentProfiles.activeProfiles)
    try await redispatch(
      ticket,
      message: """
        \(who == "You" ? "The person" : who) sent ticket \(ticket.label) (\(ticket.title)) back:
        <<<note>>>
        \(note)
        <<<end>>>
        Fix it and hand it back again.
        """)
  }

  public func deleteTicket(id: UUID) throws { try tickets.remove(id: id) }

  // MARK: What the bot does

  func completeTicket(id: UUID, result: String, by actor: Ticket.Party) async throws -> Ticket {
    let result = TicketStore.clip(result)
    guard !result.isEmpty else {
      throw ToolRegistryError.invalidInput("Put the finished output in result.")
    }
    let current = try ticketOwned(id: id, by: actor)
    guard !current.isChecking else {
      throw TicketStore.TicketError.wrongStatus(
        "\(current.label) is being checked. Wait for the result before handing it back again.")
    }
    // A brief that arrived after Otto gave up waiting still counts once the work comes back.
    guard current.status == .doing || current.status == .blocked || current.isUndelivered else {
      throw TicketStore.TicketError.wrongStatus(
        "\(current.label) is \(current.status.rawValue); it can't be handed back now.")
    }
    // With standards to meet, the work is checked before anyone reviews it (#127).
    if !standardsToCheck(current).isEmpty {
      let ticket = try tickets.update(id: id) { ticket in
        ticket.status = .doing
        ticket.result = result
        ticket.question = nil
        ticket.checking = true
        ticket.events.append(Ticket.Event(kind: .handedBack, actor: actor, text: result))
      }
      Task { [weak self] in await self?.runStandardsCheck(ticketID: id) }
      return ticket
    }
    let ticket = try tickets.update(id: id) { ticket in
      ticket.status = .review
      ticket.result = result
      ticket.question = nil
      ticket.events.append(Ticket.Event(kind: .handedBack, actor: actor, text: result))
    }
    return await handToReviewer(ticket)
  }

  /// Handed-back work goes to its reviewer: the person sees it in Tickets; a bot is prompted.
  @discardableResult
  func handToReviewer(_ ticket: Ticket) async -> Ticket {
    // "Done without my review": the CEO's own finished ticket closes as it is handed back.
    if ticket.reviewer == .person, ticket.status == .review,
      let owner = ticket.assigneeProfileID, isCEO(owner), ceo.rules.finish == .auto
    {
      let closed = try? tickets.update(id: ticket.id) { ticket in
        ticket.status = .done
        ticket.closedAt = .now
        ticket.events.append(
          Ticket.Event(
            kind: .approved, actor: .bot(owner),
            text: "Counted as done without your review, as your rule for the CEO allows."))
      }
      return closed ?? ticket
    }
    // "Approve on my behalf": the part is still down to the person, but their CEO may decide
    // it, so the CEO has to hear that it came back.
    if ticket.status == .review, let result = ticket.result,
      case .bot(let creatorID) = ticket.creator,
      ceoMayReviewForPerson(ticket, actor: ticket.creator)
    {
      let worker =
        ticket.assigneeProfileID.map {
          Self.ticketPartyName(.bot($0), profiles: agentProfiles.activeProfiles)
        } ?? "A bot"
      _ = try? await promptTicketBot(
        profileID: creatorID,
        message: """
          \(worker) handed back ticket \(ticket.label) (\(ticket.title)). It is down to the \
          person to review, and they let you decide it for them:
          <<<result>>>
          \(result)
          <<<end>>>
          """,
        hidden: """
          Check the work against its brief:
          \(ticket.brief)
          If it clearly meets the brief, call ticket.review with ticket "\(ticket.label)" and \
          decision "approve"; if it clearly misses, "send_back" with exactly what to fix. If \
          you are not sure, leave it for the person and end your turn.
          """)
      return ticket
    }
    guard case .bot(let reviewerID) = ticket.reviewer, let result = ticket.result else {
      return ticket
    }
    let worker =
      ticket.assigneeProfileID.map {
        Self.ticketPartyName(.bot($0), profiles: agentProfiles.activeProfiles)
      } ?? "A bot"
    var checked = ""
    if let check = ticket.latestCheck {
      checked =
        "\nOtto's checker (\(check.checker)) found: \(check.summary).\n"
        + check.verdicts.map { "- [\($0.outcome.rawValue)] \($0.standard): \($0.evidence)" }
        .joined(separator: "\n")
    }
    do {
      try await promptTicketBot(
        profileID: reviewerID,
        message: """
          \(worker) handed back ticket \(ticket.label) (\(ticket.title)) for your review:
          <<<result>>>
          \(result)
          <<<end>>>\(checked)
          """,
        hidden: """
          You are the reviewer of Otto ticket \(ticket.label). Check the work against its brief:
          \(ticket.brief)
          Then call ticket.review with ticket "\(ticket.label)" and decision "approve", or \
          "send_back" with a note saying exactly what to fix. Do not do the work yourself.
          """)
    } catch {
      // A reviewer that can't be reached must not leave the work stuck; the person decides.
      return
        (try? tickets.update(id: ticket.id) { ticket in
          ticket.reviewer = .person
          ticket.events.append(
            Ticket.Event(
              kind: .problem, actor: .person,
              text: "The reviewer couldn’t be reached, so this comes to you: "
                + error.localizedDescription))
        }) ?? ticket
    }
    return ticket
  }

  func blockTicket(id: UUID, question: String, by actor: Ticket.Party) throws -> Ticket {
    let question = TicketStore.clip(question)
    guard !question.isEmpty else {
      throw ToolRegistryError.invalidInput("Say what you need from the person.")
    }
    let current = try ticketOwned(id: id, by: actor)
    guard current.status == .doing else {
      throw TicketStore.TicketError.wrongStatus(
        "\(current.label) is \(current.status.rawValue); it can't be blocked now.")
    }
    return try tickets.update(id: id) { ticket in
      ticket.status = .blocked
      ticket.question = question
      ticket.events.append(Ticket.Event(kind: .blocked, actor: actor, text: question))
    }
  }

  func noteOnTicket(id: UUID, text: String, by actor: Ticket.Party) throws -> Ticket {
    let text = TicketStore.clip(text)
    guard !text.isEmpty else { throw ToolRegistryError.invalidInput("The note is empty.") }
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    if actor != .person {
      let involved =
        current.creator == actor || current.reviewer == actor
        || current.assigneeProfileID.map { actor == .bot($0) } == true
      guard involved else { throw TicketStore.TicketError.notYours }
    }
    return try tickets.update(id: id) { ticket in
      ticket.events.append(Ticket.Event(kind: .note, actor: actor, text: text))
    }
  }

  private func ticketOwned(id: UUID, by actor: Ticket.Party) throws -> Ticket {
    guard let current = tickets.ticket(id: id) else { throw TicketStore.TicketError.unknown }
    if actor != .person {
      guard let assignee = current.assigneeProfileID, actor == .bot(assignee) else {
        throw TicketStore.TicketError.notYours
      }
    }
    return current
  }

  // MARK: Reaching bots

  func ticketInstructions(_ ticket: Ticket) -> String {
    let reviewer = Self.ticketPartyName(ticket.reviewer, profiles: agentProfiles.activeProfiles)
    return """
      This is Otto ticket \(ticket.label). Work on it now and stay inside its LIMITS.
      - When you finish, call ticket.complete with ticket "\(ticket.label)". Put the finished \
      output itself in result, written for the person to read as a document (Markdown: short \
      headings, bullets, tables where they help). Do not describe what you did, do not \
      address anyone, and do not say "delivered in this chat". If the output is a file or a \
      page, give its path or link and a two-line summary instead. \(reviewer == "You" ? "The person" : reviewer) \
      reviews it before it counts as done.
      - If you can't go on without the person, call ticket.block with your question and stop.
      - When you make a decision worth explaining (why you split the work, why you chose an \
      approach), record it in one or two sentences with ticket.note.
      - You may split it with ticket.create (parent "\(ticket.label)") and give the parts to \
      other bots; you still hand back \(ticket.label) yourself once they are done.
      Do not end your turn without calling ticket.complete or ticket.block, unless you are \
      waiting on tickets you gave to other bots.
      """ + standardsBriefing(ticket)
  }

  private func dispatchTicket(_ ticket: Ticket, message: String) async throws {
    guard let profileID = ticket.assigneeProfileID else { return }
    let nodeID = try await promptTicketBot(
      profileID: profileID, message: message, hidden: ticketInstructions(ticket))
    _ = try tickets.update(id: ticket.id) { ticket in
      ticket.agentNodeID = nodeID
      ticket.dispatchedAt = .now
    }
  }

  /// Sends a follow-up to the bot working a ticket; a failure is written on the ticket.
  func redispatch(_ ticket: Ticket, message: String) async throws {
    do {
      try await dispatchTicket(ticket, message: message)
    } catch {
      _ = try? tickets.update(id: ticket.id) { ticket in
        ticket.events.append(
          Ticket.Event(
            kind: .unreported, actor: .person,
            text: "That didn’t reach the bot: \(error.localizedDescription)"))
      }
      throw error
    }
  }

  /// Opens the bot's own chat if it isn't running and sends it a message with hidden
  /// instructions for this turn only. Returns the chat it went to.
  @discardableResult
  func promptTicketBot(profileID: UUID, message: String, hidden: String) async throws
    -> UUID
  {
    // Starting a bot can hang (a runtime that won't come up, a sign-in that expired). The
    // ticket must not sit there looking busy, so give up after a while and say so.
    // The CEO's brief and the person's rules for it travel with every ticket message. A
    // session that was already running when a rule changed would otherwise never hear it.
    let ceoBrief = ceoBrief(profileID: profileID)
    let hidden = ceoBrief.isEmpty ? hidden : hidden + "\n\n" + ceoBrief
    let gate = TicketDispatchGate()
    let timeout = ticketDispatchTimeout
    return try await withCheckedThrowingContinuation { continuation in
      Task { @MainActor [weak self] in
        do {
          guard let self else { throw CancellationError() }
          let nodeID = try await self.sendToTicketBot(
            profileID: profileID, message: message, hidden: hidden)
          if gate.claim() { continuation.resume(returning: nodeID) }
        } catch {
          if gate.claim() { continuation.resume(throwing: error) }
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeout)
        if gate.claim() {
          continuation.resume(
            throwing: ToolRegistryError.invalidInput(
              "The bot didn’t start within \(Int(timeout.components.seconds)) seconds."))
        }
      }
    }
  }

  private func sendToTicketBot(profileID: UUID, message: String, hidden: String) async throws
    -> UUID
  {
    if let override = ticketDispatchOverride {
      return try await override(profileID, message, hidden)
    }
    guard let entry = botRoster().first(where: { $0.profile.id == profileID }) else {
      throw ToolRegistryError.invalidInput("That bot is no longer available.")
    }
    let nodeID: UUID
    if let live = entry.nodeID {
      nodeID = live
    } else {
      let canvas = store.activeCanvas
      let offset = Double(canvas.nodes.count * 22)
      nodeID = try await openBotChannel(
        entry.profile,
        at: WorldPoint(
          x: canvas.viewport.centerX - 170 + offset, y: canvas.viewport.centerY - 100 + offset))
    }
    try await sendPrompt(agentID: nodeID, prompt: message, hiddenContext: hidden)
    return nodeID
  }

  /// A bot that made a ticket hears when it is done, so it never has to poll.
  private func tellCreatorTicketIsDone(_ ticket: Ticket, decidedBy actor: Ticket.Party) async {
    guard case .bot(let creatorID) = ticket.creator, ticket.creator != actor else { return }
    var message = """
      Ticket \(ticket.label) (\(ticket.title)) is done and approved.
      <<<result>>>
      \(ticket.result ?? "No result was recorded.")
      <<<end>>>
      """
    var hidden = "This is a notice about an Otto ticket you created. Nothing is required."
    if let parentID = ticket.parentID, let parent = tickets.ticket(id: parentID),
      parent.assigneeProfileID == creatorID, parent.isOpen
    {
      let siblings = tickets.children(of: parentID)
      let open = siblings.filter(\.isOpen)
      if open.isEmpty {
        message += "\nEvery part of \(parent.label) (\(parent.title)) is now done."
        hidden = """
          All the tickets you split \(parent.label) into are done. Put the results together \
          and hand \(parent.label) back with ticket.complete.
          """
      } else {
        message +=
          "\n\(open.count) of \(siblings.count) parts of \(parent.label) are still open: "
          + open.map(\.label).joined(separator: ", ") + "."
        hidden = "You are still waiting on the other parts. Nothing is required yet."
      }
    }
    do {
      try await promptTicketBot(profileID: creatorID, message: message, hidden: hidden)
    } catch {
      _ = try? tickets.update(id: ticket.id) { ticket in
        ticket.events.append(
          Ticket.Event(
            kind: .problem, actor: .person,
            text: "Couldn’t tell the bot that created this: \(error.localizedDescription)"))
      }
    }
  }

  // MARK: Bots that go quiet

  /// A bot that ends its turn on a ticket without handing it back or blocking it gets flagged,
  /// so work never silently stalls.
  func startTicketWatch() {
    recoverUndeliveredTickets()
    let bus = supervisor.eventBus
    let cursor = bus.latestSequence
    Task { [weak self] in
      for await event in bus.stream(afterSequence: cursor) {
        guard event.type == .agentRunCompleted || event.type == .agentRunFailed,
          let nodeID = event.nodeID
        else { continue }
        await MainActor.run {
          self?.flagUnreportedTickets(nodeID: nodeID, failed: event.type == .agentRunFailed)
        }
      }
    }
  }

  /// A ticket still "starting" when Otto launches never reached its bot: Otto closed first.
  /// Say so on the ticket, where the person can send it again.
  func recoverUndeliveredTickets() {
    for ticket in tickets.all where ticket.isStarting {
      let name =
        ticket.assigneeProfileID.map {
          Self.ticketPartyName(.bot($0), profiles: agentProfiles.activeProfiles)
        } ?? "the bot"
      _ = try? tickets.update(id: ticket.id) { ticket in
        ticket.status = .todo
        ticket.events.append(
          Ticket.Event(
            kind: .problem, actor: .person,
            text: "Otto closed before this reached \(name). Send it again."))
      }
    }
    // A bot that was in the middle of a ticket when Otto closed has stopped, and no "finished"
    // event will ever come for that run. Say so, or the ticket reads "working" forever. A
    // ticket waiting on its own parts is left alone: those parts carry the work.
    for ticket in tickets.all
    where ticket.status == .doing && ticket.dispatchedAt != nil && !ticket.isUnreported {
      guard !tickets.children(of: ticket.id).contains(where: \.isOpen) else { continue }
      let name =
        ticket.assigneeProfileID.map {
          Self.ticketPartyName(.bot($0), profiles: agentProfiles.activeProfiles)
        } ?? "The bot"
      _ = try? tickets.update(id: ticket.id) { ticket in
        ticket.events.append(
          Ticket.Event(
            kind: .unreported, actor: .person,
            text: "Otto restarted while \(name) was working on this, so it stopped."))
      }
    }
  }

  /// A start-up failure in words a person can act on, not the runtime's own.
  nonisolated static func ticketStartFailure(_ error: Error, bot: String) -> String {
    let raw = "\(error) \(error.localizedDescription)"
    if raw.contains("waitingPermission") || raw.contains("WAITING_PERMISSION") {
      return "\(bot) is waiting for you to allow something in its chat. Answer that, then "
        + "send this again."
    }
    if raw.contains("waitingUser") || raw.contains("WAITING_USER") {
      return "\(bot) is waiting for your reply in its chat. Answer that, then send this again."
    }
    return "Couldn’t start \(bot): \(error.localizedDescription)"
  }

  func flagUnreportedTickets(nodeID: UUID, failed: Bool) {
    for ticket in tickets.all
    where ticket.status == .doing && ticket.agentNodeID == nodeID
      && ticket.dispatchedAt != nil && !ticket.isUnreported && !ticket.isChecking
    {
      // A bot waiting on the parts it handed out has not gone quiet.
      guard !tickets.children(of: ticket.id).contains(where: \.isOpen) else { continue }
      let name =
        ticket.assigneeProfileID.map {
          Self.ticketPartyName(.bot($0), profiles: agentProfiles.activeProfiles)
        } ?? "The bot"
      _ = try? tickets.update(id: ticket.id) { ticket in
        ticket.events.append(
          Ticket.Event(
            kind: .unreported, actor: .person,
            text: failed
              ? "\(name)’s run failed before it reported on this."
              : "\(name) stopped without handing this back or saying it was stuck."))
      }
    }
  }

  // MARK: Names

  public func ticketPartyName(_ party: Ticket.Party) -> String {
    Self.ticketPartyName(party, profiles: agentProfiles.activeProfiles)
  }

  nonisolated static func ticketPartyName(_ party: Ticket.Party, profiles: [AgentProfile])
    -> String
  {
    switch party {
    case .person: "You"
    case .bot(let id): profiles.first { $0.id == id }?.name ?? "A removed bot"
    case .session(let name): name
    }
  }

  // MARK: Tools

  func registerTicketTools() async throws {
    let throttle = AgentControlThrottle()
    try await registry.register(
      TicketCreateTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        if input.assignee != nil { try await throttle.authorizePrompt(context) }
        return try await self.toolCreateTicket(input, context: context)
      })
    try await registry.register(
      TicketAssignTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        try await throttle.authorizePrompt(context)
        return try await self.toolAssignTicket(input, context: context)
      })
    try await registry.register(
      TicketListTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return await self.toolListTickets(input, context: context)
      })
    try await registry.register(
      TicketGetTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.toolGetTicket(input)
      })
    try await registry.register(
      TicketNoteTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.toolNoteTicket(input, context: context)
      })
    try await registry.register(
      TicketCompleteTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.toolCompleteTicket(input, context: context)
      })
    try await registry.register(
      TicketBlockTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.toolBlockTicket(input, context: context)
      })
    try await registry.register(
      TicketReviewTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        try await throttle.authorizePrompt(context)
        return try await self.toolReviewTicket(input, context: context)
      })
  }

  /// Who is calling: a saved bot, a one-off session, or the person (UI, voice, CLI).
  func ticketActor(_ context: ToolContext) -> Ticket.Party {
    guard context.source == .agent || context.source == .automation else { return .person }
    guard let nodeID = context.sourceNodeID else { return .session("An agent") }
    if let profileID = profileID(forNode: nodeID) { return .bot(profileID) }
    let name = store.snapshot.canvases.lazy.flatMap(\.nodes).first { $0.id == nodeID }?
      .displayName
    return .session(name ?? "A session")
  }

  func resolveTicket(_ reference: String) throws -> Ticket {
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = UUID(uuidString: trimmed), let ticket = tickets.ticket(id: id) { return ticket }
    let digits = trimmed.uppercased().replacingOccurrences(of: "T-", with: "")
      .replacingOccurrences(of: "#", with: "")
    if let number = Int(digits), let ticket = tickets.ticket(number: number) { return ticket }
    throw ToolRegistryError.invalidInput(
      "No ticket \(trimmed). Use its label, such as T-14, from ticket.list.")
  }

  func resolveTicketBot(_ name: String) throws -> AgentProfile {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let bare = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    if let id = UUID(uuidString: bare),
      let profile = agentProfiles.activeProfiles.first(where: { $0.id == id })
    {
      return profile
    }
    if let profile = agentProfiles.exactMatch(name: bare) { return profile }
    let handle = AgentProfile.handle(from: bare)
    if !handle.isEmpty,
      let profile = agentProfiles.activeProfiles.first(where: {
        AgentProfile.handle(from: $0.name) == handle
      })
    {
      return profile
    }
    let names = agentProfiles.activeProfiles.map(\.name).joined(separator: ", ")
    throw ToolRegistryError.invalidInput(
      "No bot named \(trimmed). The bots are: \(names.isEmpty ? "none yet" : names).")
  }

  private func resolveReviewer(_ name: String?, creator: Ticket.Party, assignee: UUID?) throws
    -> Ticket.Party
  {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      // A bot that hands work to another bot checks it first; anything else comes to the person.
      if case .bot(let creatorID) = creator, let assignee, assignee != creatorID {
        return creator
      }
      return .person
    }
    if ["person", "user", "me", "you", "human"].contains(name.lowercased()) { return .person }
    return .bot(try resolveTicketBot(name).id)
  }

  private func toolCreateTicket(_ input: TicketCreateInput, context: ToolContext) async throws
    -> TicketOutput
  {
    let actor = ticketActor(context)
    let assigneeProfile = try input.assignee.map(resolveTicketBot)
    if let assigneeProfile { try checkCEOMayAssign(to: assigneeProfile, actor: actor) }
    let assignee = assigneeProfile?.id
    var reviewer = try resolveReviewer(input.reviewer, creator: actor, assignee: assignee)
    let parentID = try input.parent.map(resolveTicket)?.id
    // The person's rules for their CEO apply to everything it hands out.
    var hold = false
    if case .bot(let actorID) = actor, isCEO(actorID) {
      try checkCEOLimits(parentID: parentID, actor: actor)
      if let assignee, assignee != actorID {
        if ceo.rules.reviews == .person { reviewer = .person }
        hold = ceo.rules.handOut == .ask
      }
    }
    let ticket = try await createTicket(
      title: input.title, task: input.task ?? "", limits: input.limits,
      handsBack: input.handsBack, assignee: assignee, reviewer: reviewer, parentID: parentID,
      creator: actor, creatorNodeID: context.sourceNodeID, why: input.why,
      standards: input.standards ?? [], hold: hold)
    let note: String
    if ticket.isHeld, let assignee {
      note =
        "\(ticket.label) is waiting for the person to start it for "
        + "\(ticketPartyName(.bot(assignee))). Otto tells you when it is done, or if they "
        + "decide against it. Don't chase and don't do the work yourself."
    } else if let assignee, actor != .bot(assignee) {
      note =
        "\(ticket.label) is with \(ticketPartyName(.bot(assignee))), who has started on it. "
        + "Otto tells you when it is done; don't poll and don't do the work yourself."
    } else if assignee != nil {
      note = "\(ticket.label) is yours. Hand it back with ticket.complete when it is done."
    } else {
      note = "\(ticket.label) is on the list with no owner. Give it to a bot with ticket.assign."
    }
    return TicketOutput(tickets: [summary(ticket, events: false)], note: note)
  }

  private func toolAssignTicket(_ input: TicketAssignInput, context: ToolContext) async throws
    -> TicketOutput
  {
    let actor = ticketActor(context)
    let current = try resolveTicket(input.ticket)
    if actor != .person {
      let parentOwner = current.parentID.flatMap { tickets.ticket(id: $0)?.assigneeProfileID }
      let allowed = current.creator == actor || parentOwner.map { actor == .bot($0) } == true
      guard allowed else {
        throw ToolRegistryError.invalidInput(
          "Only whoever created \(current.label) can give it to a bot.")
      }
    }
    let profile = try resolveTicketBot(input.assignee)
    try checkCEOMayAssign(to: profile, actor: actor)
    if case .bot(let actorID) = actor, isCEO(actorID), profile.id != actorID,
      ceo.rules.handOut == .ask
    {
      let held = try holdTicket(id: current.id, for: profile.id, by: actor)
      return TicketOutput(
        tickets: [summary(held, events: false)],
        note: "\(held.label) is waiting for the person to start it for \(profile.name).")
    }
    let ticket = try await assignTicket(
      id: current.id, to: profile.id, by: actor, actorNodeID: context.sourceNodeID)
    return TicketOutput(
      tickets: [summary(ticket, events: false)],
      note: "\(ticket.label) is with \(profile.name). Otto tells you when it is done.")
  }

  private func toolListTickets(_ input: TicketListInput, context: ToolContext) -> TicketOutput {
    let actor = ticketActor(context)
    var list = tickets.all
    if let status = input.status.flatMap({ Ticket.Status(rawValue: $0.lowercased()) }) {
      list = list.filter { $0.status == status }
    } else if input.status?.lowercased() != "all" {
      list = list.filter(\.isOpen)
    }
    if input.mine == true, case .bot(let profileID) = actor {
      list = list.filter {
        $0.assigneeProfileID == profileID || $0.creator == actor || $0.reviewer == actor
      }
    }
    let shown = list.sorted { $0.number > $1.number }.prefix(60)
    return TicketOutput(
      tickets: shown.map { summary($0, events: false) },
      note: list.count > shown.count ? "Showing the newest \(shown.count) of \(list.count)." : "")
  }

  private func toolGetTicket(_ input: TicketReferenceInput) throws -> TicketOutput {
    let ticket = try resolveTicket(input.ticket)
    let parts = tickets.children(of: ticket.id).map { summary($0, events: false) }
    return TicketOutput(tickets: [summary(ticket, events: true)] + parts, note: "")
  }

  private func toolNoteTicket(_ input: TicketNoteInput, context: ToolContext) throws
    -> TicketOutput
  {
    let ticket = try noteOnTicket(
      id: try resolveTicket(input.ticket).id, text: input.text, by: ticketActor(context))
    return TicketOutput(tickets: [summary(ticket, events: false)], note: "Noted on the ticket.")
  }

  private func toolCompleteTicket(_ input: TicketCompleteInput, context: ToolContext)
    async throws -> TicketOutput
  {
    let ticket = try await completeTicket(
      id: try resolveTicket(input.ticket).id, result: input.result, by: ticketActor(context))
    let reviewer = ticketPartyName(ticket.reviewer)
    if ticket.isChecking {
      return TicketOutput(
        tickets: [summary(ticket, events: false)],
        note: "Handed back. Another model is checking it against \(standardsToCheck(ticket).count) "
          + "standards before review. If anything fails you get a message saying what to fix. "
          + "You can end your turn.")
    }
    return TicketOutput(
      tickets: [summary(ticket, events: false)],
      note: "Handed back. \(reviewer == "You" ? "The person" : reviewer) reviews it next; "
        + "if it comes back you get a message. You can end your turn.")
  }

  private func toolBlockTicket(_ input: TicketBlockInput, context: ToolContext) throws
    -> TicketOutput
  {
    let ticket = try blockTicket(
      id: try resolveTicket(input.ticket).id, question: input.question,
      by: ticketActor(context))
    return TicketOutput(
      tickets: [summary(ticket, events: false)],
      note: "The person sees your question in Otto. Their answer arrives as a new message. "
        + "Stop here.")
  }

  private func toolReviewTicket(_ input: TicketReviewInput, context: ToolContext) async throws
    -> TicketOutput
  {
    let actor = ticketActor(context)
    // An agent never decides in the person's place, unless the person gave their CEO that rule.
    let asked = try resolveTicket(input.ticket)
    if actor != .person, asked.reviewer == .person, !ceoMayReviewForPerson(asked, actor: actor) {
      throw ToolRegistryError.invalidInput("The person reviews this ticket, not a bot.")
    }
    let decision = input.decision.lowercased().replacingOccurrences(of: " ", with: "_")
    guard ["approve", "send_back"].contains(decision) else {
      throw ToolRegistryError.invalidInput("decision is approve or send_back.")
    }
    let current = try resolveTicket(input.ticket)
    // Through the tool, a review is only ever of work that was handed back. Closing a ticket
    // that is still being worked on is a deliberate act on the ticket itself.
    guard current.status == .review else {
      throw ToolRegistryError.invalidInput(
        "\(current.label) is \(current.status.rawValue), not waiting for review.")
    }
    let id = current.id
    try await reviewTicket(id: id, approve: decision == "approve", note: input.note, by: actor)
    let ticket = tickets.ticket(id: id)
    var note = decision == "approve" ? "Approved and closed." : "Sent back with your note."
    // A manager that approves the last part is told plainly that its own ticket is next.
    if decision == "approve", let parentID = ticket?.parentID,
      let parent = tickets.ticket(id: parentID), parent.isOpen,
      let owner = parent.assigneeProfileID, actor == .bot(owner)
    {
      let open = tickets.children(of: parentID).filter(\.isOpen)
      note +=
        open.isEmpty
        ? " Every part of \(parent.label) is now done: put the results together and hand "
          + "\(parent.label) back with ticket.complete."
        : " Still open for \(parent.label): " + open.map(\.label).joined(separator: ", ") + "."
    }
    return TicketOutput(tickets: ticket.map { [summary($0, events: false)] } ?? [], note: note)
  }

  func summary(_ ticket: Ticket, events: Bool) -> TicketSummary {
    let profiles = agentProfiles.activeProfiles
    return TicketSummary(
      ticket: ticket.label, id: ticket.id, title: ticket.title, status: ticket.status.rawValue,
      assignee: ticket.assigneeProfileID.map {
        Self.ticketPartyName(.bot($0), profiles: profiles)
      },
      reviewer: Self.ticketPartyName(ticket.reviewer, profiles: profiles),
      createdBy: Self.ticketPartyName(ticket.creator, profiles: profiles),
      parent: ticket.parentID.flatMap { tickets.ticket(id: $0)?.label },
      task: ticket.task, limits: ticket.limits, handsBack: ticket.handsBack,
      result: ticket.result.map { String($0.prefix(1_200)) }, question: ticket.question,
      needsPerson: ticket.needsPerson,
      events: events
        ? ticket.events.suffix(40).map { event in
          "\(event.kind.rawValue) · \(Self.ticketPartyName(event.actor, profiles: profiles)): "
            + String(event.text.prefix(400))
        } : nil,
      checked: ticket.isChecking ? "Being checked now" : ticket.latestCheck?.summary)
  }
}

/// Lets whichever finishes first, the send or the timeout, settle a dispatch exactly once.
@MainActor
private final class TicketDispatchGate {
  private var claimed = false
  func claim() -> Bool {
    guard !claimed else { return false }
    claimed = true
    return true
  }
}

// MARK: Tool types

public struct TicketSummary: Codable, Sendable, Equatable {
  public var ticket: String
  public var id: UUID
  public var title: String
  public var status: String
  public var assignee: String?
  public var reviewer: String
  public var createdBy: String
  public var parent: String?
  public var task: String
  public var limits: String?
  public var handsBack: String?
  public var result: String?
  public var question: String?
  public var needsPerson: Bool
  public var events: [String]?
  /// What the checker found on the newest check, e.g. "6 of 7 passed · 1 failed".
  public var checked: String?
}

public struct TicketOutput: Codable, Sendable, Equatable {
  public var tickets: [TicketSummary]
  public var note: String
}

public struct TicketCreateInput: Codable, Sendable {
  public var title: String
  public var task: String?
  public var limits: String?
  public var handsBack: String?
  public var assignee: String?
  public var reviewer: String?
  public var parent: String?
  public var why: String?
  /// Standards for this ticket only, on top of the bot's own.
  public var standards: [String]?
  public init(
    title: String, task: String? = nil, limits: String? = nil, handsBack: String? = nil,
    assignee: String? = nil, reviewer: String? = nil, parent: String? = nil, why: String? = nil,
    standards: [String]? = nil
  ) {
    self.standards = standards
    self.title = title
    self.task = task
    self.limits = limits
    self.handsBack = handsBack
    self.assignee = assignee
    self.reviewer = reviewer
    self.parent = parent
    self.why = why
  }
}

public struct TicketAssignInput: Codable, Sendable {
  public var ticket: String
  public var assignee: String
  public init(ticket: String, assignee: String) {
    self.ticket = ticket
    self.assignee = assignee
  }
}

public struct TicketListInput: Codable, Sendable {
  public var status: String?
  public var mine: Bool?
  public init(status: String? = nil, mine: Bool? = nil) {
    self.status = status
    self.mine = mine
  }
}

public struct TicketReferenceInput: Codable, Sendable {
  public var ticket: String
  public init(ticket: String) { self.ticket = ticket }
}

public struct TicketNoteInput: Codable, Sendable {
  public var ticket: String
  public var text: String
  public init(ticket: String, text: String) {
    self.ticket = ticket
    self.text = text
  }
}

public struct TicketCompleteInput: Codable, Sendable {
  public var ticket: String
  public var result: String
  public init(ticket: String, result: String) {
    self.ticket = ticket
    self.result = result
  }
}

public struct TicketBlockInput: Codable, Sendable {
  public var ticket: String
  public var question: String
  public init(ticket: String, question: String) {
    self.ticket = ticket
    self.question = question
  }
}

public struct TicketReviewInput: Codable, Sendable {
  public var ticket: String
  public var decision: String
  public var note: String?
  public init(ticket: String, decision: String, note: String? = nil) {
    self.ticket = ticket
    self.decision = decision
    self.note = note
  }
}

private let ticketReferenceProperty = JSONValue.stringSchema(
  description: "The ticket's label, such as T-14")

public struct TicketCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.create",
    description: """
      Creates a ticket in Otto's Tickets: one piece of work with a brief. Give it an assignee \
      (a bot's name) and that bot is started on it straight away; Otto messages you when it \
      is done, so never poll and never do the work yourself. Write the brief as task (what to \
      do), limits (what it must not do) and handsBack (what you expect to get). To split a \
      ticket you own, pass parent with its label. Pass why to record, in one or two \
      sentences, why you split the work or chose that bot; the person reads it on the ticket. \
      By default you review work you hand to another bot, and the person reviews everything \
      else; a bot never reviews its own work.
      """,
    inputSchema: .objectSchema(
      properties: [
        "title": .stringSchema(description: "Short title, e.g. Find 20 leads on LinkedIn"),
        "task": .stringSchema(description: "What to do"),
        "limits": .stringSchema(description: "What it must not do, e.g. Read only, never send"),
        "handsBack": .stringSchema(description: "What comes back, e.g. A sheet of 20 leads"),
        "assignee": .stringSchema(description: "Name of the bot to give it to"),
        "reviewer": .stringSchema(description: "A bot's name, or person"),
        "parent": .stringSchema(description: "Label of the ticket this is a part of"),
        "why": .stringSchema(description: "Your reason, shown on the ticket"),
        "standards": .arraySchema(
          of: .stringSchema(),
          description: """
            Yes/no checks for this ticket only, e.g. "Under 60 seconds". Another model checks \
            the work against these and the bot's own standards before review.
            """),
      ], required: ["title"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketCreateInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketCreateInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketCreateInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

public struct TicketAssignTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.assign",
    description: """
      Gives a ticket you created to a bot, by name, and starts that bot on it. Otto messages \
      you when the ticket is done; don't poll.
      """,
    inputSchema: .objectSchema(
      properties: [
        "ticket": ticketReferenceProperty,
        "assignee": .stringSchema(description: "Name of the bot to give it to"),
      ], required: ["ticket", "assignee"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketAssignInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketAssignInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketAssignInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

public struct TicketListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.list",
    description: """
      Lists Otto tickets, newest first: open ones by default, or pass status (todo, doing, \
      blocked, review, done, all). Pass mine true for tickets you own, created or review.
      """,
    inputSchema: .objectSchema(
      properties: [
        "status": .stringSchema(description: "todo, doing, blocked, review, done or all"),
        "mine": .booleanSchema(description: "Only tickets you own, created or review"),
      ]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  private let handler: @Sendable (TicketListInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketListInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketListInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

public struct TicketGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.get",
    description:
      "Reads one Otto ticket: its brief, status, result, the story so far, and its parts.",
    inputSchema: .objectSchema(
      properties: ["ticket": ticketReferenceProperty], required: ["ticket"]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  private let handler: @Sendable (TicketReferenceInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketReferenceInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketReferenceInput, context: ToolContext) async throws
    -> TicketOutput
  { try await handler(input, context) }
}

public struct TicketNoteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.note",
    description: """
      Records a decision on a ticket you are working, created or review, in one or two \
      sentences: why you split it, why you chose an approach, what you ruled out. The person \
      reads these to follow your thinking without opening the chat.
      """,
    inputSchema: .objectSchema(
      properties: [
        "ticket": ticketReferenceProperty,
        "text": .stringSchema(description: "The decision and the reason"),
      ], required: ["ticket", "text"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketNoteInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketNoteInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketNoteInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

public struct TicketCompleteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.complete",
    description: """
      Hands back a ticket assigned to you once the work is finished. result is the finished \
      output itself, written as a document the person reads on the ticket (Markdown), not a \
      description of what you did; for a file or page, give its path or link and a short \
      summary. It then waits for its reviewer; if it is sent back you get a message with what \
      to fix.
      """,
    inputSchema: .objectSchema(
      properties: [
        "ticket": ticketReferenceProperty,
        "result": .stringSchema(
          description: "The finished output as Markdown, or the file path or link plus a summary"),
      ], required: ["ticket", "result"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketCompleteInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketCompleteInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketCompleteInput, context: ToolContext) async throws
    -> TicketOutput
  { try await handler(input, context) }
}

public struct TicketBlockTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.block",
    description: """
      Says you can't go on with a ticket assigned to you without the person: a decision, a \
      sign-in, a missing file. question is exactly what you need. Their answer arrives as a \
      new message. Stop after calling it.
      """,
    inputSchema: .objectSchema(
      properties: [
        "ticket": ticketReferenceProperty,
        "question": .stringSchema(description: "Exactly what you need from the person"),
      ], required: ["ticket", "question"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketBlockInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketBlockInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketBlockInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

public struct TicketReviewTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "ticket.review",
    description: """
      Decides on handed-back work for a ticket you are the reviewer of: decision approve \
      closes it, send_back returns it to the bot with a note saying exactly what to fix. You \
      can't review your own work or a ticket the person reviews.
      """,
    inputSchema: .objectSchema(
      properties: [
        "ticket": ticketReferenceProperty,
        "decision": .stringSchema(description: "approve or send_back"),
        "note": .stringSchema(description: "What to fix (required for send_back)"),
      ], required: ["ticket", "decision"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (TicketReviewInput, ToolContext) async throws -> TicketOutput
  public init(
    handler: @escaping @Sendable (TicketReviewInput, ToolContext) async throws -> TicketOutput
  ) { self.handler = handler }
  public func call(_ input: TicketReviewInput, context: ToolContext) async throws -> TicketOutput {
    try await handler(input, context)
  }
}

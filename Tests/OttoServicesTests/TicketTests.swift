import Foundation
import OttoCore
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

/// Tickets: work handed to a bot starts it, the bot hands it back or says it is stuck, and
/// nothing counts as done until its reviewer (never the bot that did it) says so.
@MainActor
@Suite("Tickets", .serialized)
struct TicketTests {
  @MainActor private final class Harness {
    let root: URL
    let services: ApplicationServices
    let chief: AgentProfile
    let researcher: AgentProfile
    let writer: AgentProfile
    /// Every message Otto sent a bot about a ticket: who, the message, the hidden brief.
    var sent: [(profile: UUID, message: String, hidden: String)] = []
    var nodes: [UUID: UUID] = [:]
    var failDispatch = false

    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "tickets-\(UUID())")
      services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
      await services.start()
      chief = try services.saveAgentProfile(
        AgentProfile(name: "Chief", instructions: "Run the team.", provider: .claudeCode))
      researcher = try services.saveAgentProfile(
        AgentProfile(name: "Researcher", instructions: "Find things.", provider: .claudeCode))
      writer = try services.saveAgentProfile(
        AgentProfile(name: "Social Guru", instructions: "Write posts.", provider: .codex))
      services.ticketDispatchOverride = { [unowned self] profile, message, hidden in
        if self.failDispatch {
          throw ToolRegistryError.invalidInput("The bot's account is signed out.")
        }
        self.sent.append((profile, message, hidden))
        if let node = self.nodes[profile] { return node }
        let node = UUID()
        self.nodes[profile] = node
        return node
      }
    }

    func stop() {
      services.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test("Giving a ticket to a bot starts it with the brief and how to report back")
  func assigningStartsTheBot() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let ticket = try await harness.services.createTicket(
      title: "Find 20 leads", task: "Find 20 people who asked about pricing",
      limits: "Read only", handsBack: "A sheet of leads", assignee: harness.researcher.id)

    #expect(ticket.label == "T-1")
    #expect(ticket.status == .doing)
    #expect(ticket.agentNodeID == harness.nodes[harness.researcher.id])
    #expect(ticket.events.map(\.kind) == [.created, .assigned])
    let sent = try #require(harness.sent.first)
    #expect(sent.profile == harness.researcher.id)
    #expect(sent.message.contains("New ticket T-1 from the person: Find 20 leads"))
    #expect(sent.message.contains("LIMITS: Read only"))
    #expect(sent.message.contains("HANDS BACK: A sheet of leads"))
    #expect(sent.hidden.contains("ticket.complete"))
    #expect(sent.hidden.contains("ticket.block"))
    #expect(!ticket.needsPerson)
  }

  @Test("Handed-back work waits for the person, who approves or sends it back with a note")
  func personReviews() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let ticket = try await services.createTicket(
      title: "Draft the post", assignee: harness.writer.id)
    let writer = Ticket.Party.bot(harness.writer.id)

    // Another bot can't report on it.
    await #expect(throws: TicketStore.TicketError.notYours) {
      _ = try await services.completeTicket(
        id: ticket.id, result: "Done", by: .bot(harness.researcher.id))
    }
    let handed = try await services.completeTicket(
      id: ticket.id, result: "Draft is in Documents/Post.md", by: writer)
    #expect(handed.status == .review)
    #expect(handed.needsPerson)
    #expect(services.tickets.needingPerson.map(\.id) == [ticket.id])

    // Sending back needs a reason, and the reason reaches the bot.
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(id: ticket.id, approve: false, note: " ")
    }
    try await services.reviewTicket(id: ticket.id, approve: false, note: "Too long. Halve it.")
    #expect(services.tickets.ticket(id: ticket.id)?.status == .doing)
    #expect(harness.sent.last?.message.contains("Too long. Halve it.") == true)

    _ = try await services.completeTicket(id: ticket.id, result: "Halved.", by: writer)
    try await services.reviewTicket(id: ticket.id, approve: true)
    let done = try #require(services.tickets.ticket(id: ticket.id))
    #expect(done.status == .done)
    #expect(done.closedAt != nil)
    #expect(!done.needsPerson)
    #expect(
      done.events.map(\.kind)
        == [.created, .assigned, .handedBack, .sentBack, .handedBack, .approved])
  }

  @Test("A bot never reviews its own work, and never decides in the person's place")
  func reviewRules() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let writer = Ticket.Party.bot(harness.writer.id)

    await #expect(throws: TicketStore.TicketError.ownReview) {
      _ = try await services.createTicket(
        title: "Self review", assignee: harness.writer.id, reviewer: writer)
    }
    let ticket = try await services.createTicket(
      title: "Draft", reviewer: .bot(harness.researcher.id))
    await #expect(throws: TicketStore.TicketError.ownReview) {
      _ = try await services.assignTicket(id: ticket.id, to: harness.researcher.id)
    }

    let personal = try await services.createTicket(title: "Post it", assignee: harness.writer.id)
    _ = try await services.completeTicket(id: personal.id, result: "Ready.", by: writer)
    // The bot that did the work, or any bot that isn't the reviewer, can't approve it.
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(id: personal.id, approve: true, by: writer)
    }
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(
        id: personal.id, approve: true, by: .bot(harness.chief.id))
    }
    #expect(services.tickets.ticket(id: personal.id)?.status == .review)
  }

  @Test("A manager bot splits its ticket, reviews the parts and hears when they are done")
  func managerSplitsAndReviews() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let chief = Ticket.Party.bot(harness.chief.id)
    let parent = try await services.createTicket(
      title: "Get 20 leads for Clippng", assignee: harness.chief.id)

    let find = try await services.createTicket(
      title: "Find 20 people", assignee: harness.researcher.id, reviewer: chief,
      parentID: parent.id, creator: chief, why: "Researcher already has the sign-in.")
    let send = try await services.createTicket(
      title: "Send the requests", assignee: harness.writer.id, reviewer: .person,
      parentID: parent.id, creator: chief)
    #expect(find.events.map(\.kind) == [.created, .note, .assigned])
    #expect(services.tickets.children(of: parent.id).map(\.label) == ["T-2", "T-3"])

    // Chief's turn ending while its parts are open is not "going quiet".
    let chiefNode = try #require(harness.nodes[harness.chief.id])
    services.flagUnreportedTickets(nodeID: chiefNode, failed: false)
    #expect(services.tickets.ticket(id: parent.id)?.isUnreported == false)

    // Researcher hands back; the review goes to Chief, not the person.
    harness.sent.removeAll()
    _ = try await services.completeTicket(
      id: find.id, result: "24 leads in the sheet", by: .bot(harness.researcher.id))
    #expect(services.tickets.ticket(id: find.id)?.needsPerson == false)
    #expect(harness.sent.last?.profile == harness.chief.id)
    #expect(harness.sent.last?.hidden.contains("ticket.review") == true)

    try await services.reviewTicket(
      id: find.id, approve: false, note: "Four are competitors. Replace them.", by: chief)
    #expect(harness.sent.last?.profile == harness.researcher.id)
    _ = try await services.completeTicket(
      id: find.id, result: "Replaced.", by: .bot(harness.researcher.id))
    try await services.reviewTicket(id: find.id, approve: true, by: chief)
    #expect(services.tickets.ticket(id: find.id)?.status == .done)

    // The part the person reviews: approving it wakes Chief with "every part is done".
    harness.sent.removeAll()
    _ = try await services.completeTicket(
      id: send.id, result: "12 requests ready to send", by: .bot(harness.writer.id))
    #expect(harness.sent.isEmpty)
    #expect(services.tickets.ticket(id: send.id)?.needsPerson == true)
    try await services.reviewTicket(id: send.id, approve: true)
    let notice = try #require(harness.sent.last)
    #expect(notice.profile == harness.chief.id)
    #expect(notice.message.contains("T-3"))
    #expect(notice.message.contains("Every part of T-1"))
    #expect(notice.hidden.contains("ticket.complete"))

    _ = try await services.completeTicket(id: parent.id, result: "20 leads contacted.", by: chief)
    #expect(services.tickets.ticket(id: parent.id)?.needsPerson == true)
  }

  @Test("A stuck bot's question reaches the person and the answer goes back")
  func blockedAndAnswered() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let ticket = try await services.createTicket(
      title: "Wire the webhook", assignee: harness.researcher.id)
    let blocked = try services.blockTicket(
      id: ticket.id, question: "Which Stripe account?", by: .bot(harness.researcher.id))
    #expect(blocked.status == .blocked)
    #expect(blocked.needsPerson)
    #expect(blocked.question == "Which Stripe account?")

    try await services.answerTicket(id: ticket.id, text: "The Clippng one.")
    let resumed = try #require(services.tickets.ticket(id: ticket.id))
    #expect(resumed.status == .doing)
    #expect(resumed.question == nil)
    #expect(harness.sent.last?.message.contains("The Clippng one.") == true)
  }

  @Test("A bot that ends its turn without reporting is flagged for the person")
  func goingQuietIsFlagged() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let ticket = try await services.createTicket(
      title: "Fix the link", assignee: harness.writer.id)
    let node = try #require(harness.nodes[harness.writer.id])

    services.flagUnreportedTickets(nodeID: UUID(), failed: false)
    #expect(services.tickets.ticket(id: ticket.id)?.isUnreported == false)
    services.flagUnreportedTickets(nodeID: node, failed: false)
    let flagged = try #require(services.tickets.ticket(id: ticket.id))
    #expect(flagged.isUnreported)
    #expect(flagged.needsPerson)
    // Flagged once, not once per finished turn.
    services.flagUnreportedTickets(nodeID: node, failed: false)
    #expect(services.tickets.ticket(id: ticket.id)?.events.count == flagged.events.count)

    try await services.answerTicket(id: ticket.id, text: "Carry on.")
    #expect(services.tickets.ticket(id: ticket.id)?.isUnreported == false)
  }

  @Test("A bot that can't be started leaves the ticket unowned with the reason on it")
  func failedStartIsRecorded() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    harness.failDispatch = true
    await #expect(throws: (any Error).self) {
      _ = try await harness.services.createTicket(
        title: "Find leads", assignee: harness.researcher.id)
    }
    let ticket = try #require(harness.services.tickets.all.first)
    #expect(ticket.status == .todo)
    #expect(ticket.events.last?.kind == .problem)
    #expect(ticket.events.last?.text.contains("signed out") == true)
    // It shows as needing the person, who can send it again once the bot is reachable.
    #expect(ticket.isUndelivered)
    #expect(ticket.needsPerson)
    harness.failDispatch = false
    let sent = try await harness.services.assignTicket(
      id: ticket.id, to: harness.researcher.id)
    #expect(sent.status == .doing)
    #expect(!sent.isStarting)
    #expect(!sent.needsPerson)
  }

  @Test("A bot that never takes the brief, or an Otto that closed first, is not left looking busy")
  func undeliveredIsNeverSilent() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services

    // The bot hangs while starting: Otto gives up and says so instead of waiting forever.
    services.ticketDispatchTimeout = .milliseconds(80)
    services.ticketDispatchOverride = { _, _, _ in
      try await Task.sleep(for: .seconds(30))
      return UUID()
    }
    await #expect(throws: (any Error).self) {
      _ = try await services.createTicket(title: "Say hello", assignee: harness.writer.id)
    }
    let hung = try #require(services.tickets.ticket(number: 1))
    #expect(hung.isUndelivered)
    #expect(hung.needsPerson)
    #expect(hung.events.last?.text.contains("didn’t start") == true)
    // The brief arrived late after all and the bot did the work: that still counts.
    let late = try await services.completeTicket(
      id: hung.id, result: "Hello.", by: .bot(harness.writer.id))
    #expect(late.status == .review)

    // Otto closed between "given to" and the brief arriving: caught on the next launch.
    let lost = try services.tickets.add(Ticket(title: "Lost", task: "Lost"))
    _ = try services.tickets.update(id: lost.id) { ticket in
      ticket.assigneeProfileID = harness.researcher.id
      ticket.status = .doing
    }
    #expect(services.tickets.ticket(id: lost.id)?.isStarting == true)
    services.recoverUndeliveredTickets()
    let recovered = try #require(services.tickets.ticket(id: lost.id))
    #expect(recovered.isUndelivered)
    #expect(recovered.needsPerson)
    #expect(
      recovered.events.last?.text.contains("Otto closed before this reached Researcher") == true)
  }

  @Test("A bot cut off by an Otto restart is flagged, but not one waiting on its parts")
  func restartStopsAreFlagged() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let working = try await services.createTicket(
      title: "Write the post", assignee: harness.writer.id)
    let parent = try await services.createTicket(
      title: "Launch plan", assignee: harness.chief.id)
    let part = try await services.createTicket(
      title: "Part", assignee: harness.researcher.id, reviewer: .bot(harness.chief.id),
      parentID: parent.id, creator: .bot(harness.chief.id))

    services.recoverUndeliveredTickets()
    let flagged = try #require(services.tickets.ticket(id: working.id))
    #expect(flagged.isUnreported)
    #expect(flagged.needsPerson)
    #expect(flagged.events.last?.text.contains("Otto restarted while Social Guru") == true)
    // The part was being worked on too; its parent is only waiting on it.
    #expect(services.tickets.ticket(id: part.id)?.isUnreported == true)
    #expect(services.tickets.ticket(id: parent.id)?.isUnreported == false)
    // A second launch doesn't pile on more notices.
    let count = flagged.events.count
    services.recoverUndeliveredTickets()
    #expect(services.tickets.ticket(id: working.id)?.events.count == count)
  }

  @Test("A bot that is busy on a prompt gives a reason the person can act on")
  func startFailureWording() {
    struct Transition: Error, CustomStringConvertible {
      var description: String { "invalidTransition(from: waitingPermission, to: working)" }
    }
    #expect(
      ApplicationServices.ticketStartFailure(Transition(), bot: "Scout")
        == "Scout is waiting for you to allow something in its chat. Answer that, then send "
        + "this again.")
    #expect(
      ApplicationServices.ticketStartFailure(
        ToolRegistryError.invalidInput("signed out"), bot: "Scout"
      ).hasPrefix("Couldn’t start Scout:"))
  }

  @Test("Tickets can only be split three levels deep, and survive a restart")
  func depthAndPersistence() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let one = try await services.createTicket(title: "One")
    let two = try await services.createTicket(title: "Two", parentID: one.id)
    let three = try await services.createTicket(title: "Three", parentID: two.id)
    await #expect(throws: TicketStore.TicketError.tooDeep) {
      _ = try await services.createTicket(title: "Four", parentID: three.id)
    }
    await #expect(throws: TicketStore.TicketError.emptyTitle) {
      _ = try await services.createTicket(title: "  ")
    }

    let reloaded = TicketStore(workspacePath: harness.root.path)
    #expect(reloaded.all.map(\.label) == ["T-1", "T-2", "T-3"])
    #expect(reloaded.ticket(number: 3)?.parentID == two.id)
    #expect(reloaded.depth(of: three.id) == 2)
  }

  @Test("The ticket tools create, list and read, and refuse an agent reviewing for the person")
  func tools() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    let person = ToolContext(
      actorID: "user", scopes: [.canvasWrite, .agentRead], source: .userInterface)
    let agent = ToolContext(actorID: "agent", scopes: [.canvasWrite, .agentRead], source: .agent)
    func call(_ name: String, _ input: some Encodable & Sendable, _ context: ToolContext)
      async throws -> TicketOutput
    {
      try await services.registry.call(
        name: name, input: try JSONValue.encode(input), context: context
      ).decode(TicketOutput.self)
    }

    let created = try await call(
      "ticket.create",
      TicketCreateInput(
        title: "Draft the post", task: "Write it", limits: "Drafts only",
        assignee: "@socialguru"), person)
    #expect(created.tickets.first?.ticket == "T-1")
    #expect(created.tickets.first?.assignee == "Social Guru")
    #expect(created.tickets.first?.reviewer == "You")
    #expect(created.tickets.first?.status == "doing")

    let listed = try await call("ticket.list", TicketListInput(), agent)
    #expect(listed.tickets.map(\.ticket) == ["T-1"])
    let read = try await call("ticket.get", TicketReferenceInput(ticket: "t-1"), agent)
    #expect(read.tickets.first?.events?.count == 2)

    _ = try await services.completeTicket(
      id: try #require(services.tickets.ticket(number: 1)).id, result: "Done.",
      by: .bot(harness.writer.id))
    await #expect(throws: (any Error).self) {
      _ = try await call(
        "ticket.review", TicketReviewInput(ticket: "T-1", decision: "approve"), agent)
    }
    #expect(services.tickets.ticket(number: 1)?.status == .review)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        "ticket.create", TicketCreateInput(title: "Nope", assignee: "Nobody"), agent)
    }

    // Through the tool, a review is only of handed-back work: it can't close a ticket a bot
    // is still working on.
    let busy = try await call(
      "ticket.create", TicketCreateInput(title: "Still going", assignee: "Researcher"), person)
    let label = try #require(busy.tickets.first?.ticket)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        "ticket.review", TicketReviewInput(ticket: label, decision: "approve"), person)
    }
    #expect(services.tickets.ticket(number: 2)?.status == .doing)
  }
}

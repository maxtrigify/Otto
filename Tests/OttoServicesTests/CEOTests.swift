import Foundation
import OttoCore
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

/// The CEO role: one bot that Otto briefs as a manager, lets run tickets for its team without
/// a prompt each time, and stops from handing work to anyone else.
@MainActor
@Suite("CEO bot", .serialized)
struct CEOTests {
  @MainActor private final class Harness {
    let root: URL
    let services: ApplicationServices
    let chief: AgentProfile
    let researcher: AgentProfile
    let writer: AgentProfile

    init() async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "ceo-\(UUID())")
      services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
      await services.start()
      chief = try services.saveAgentProfile(
        AgentProfile(name: "Chief", instructions: "Run the team.", provider: .claudeCode))
      researcher = try services.saveAgentProfile(
        AgentProfile(
          name: "Researcher", jobTitle: "Finds things on the web",
          instructions: "Find things.", provider: .claudeCode))
      writer = try services.saveAgentProfile(
        AgentProfile(name: "Social Guru", instructions: "Write posts.", provider: .codex))
      services.ticketDispatchOverride = { _, _, _ in UUID() }
    }

    func stop() {
      services.stop()
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test(
    "Ticking a bot makes it the CEO with every other bot on its team, and it survives a restart")
  func givingTheRole() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    #expect(services.ceoProfile == nil)
    #expect(services.ceoBrief(profileID: harness.chief.id).isEmpty)

    try services.setCEO(profileID: harness.chief.id)
    #expect(services.isCEO(harness.chief.id))
    #expect(!services.isCEO(harness.researcher.id))
    #expect(services.ceoReports().map(\.name) == ["Researcher", "Social Guru"])

    // The manager's brief names the team and is only ever given to the CEO.
    let brief = services.ceoBrief(profileID: harness.chief.id)
    #expect(brief.contains("You are this workspace's CEO"))
    #expect(brief.contains("- Researcher: Finds things on the web"))
    #expect(brief.contains("- Social Guru"))
    #expect(brief.contains("ticket.review"))
    #expect(services.ceoBrief(profileID: harness.researcher.id).isEmpty)

    let reloaded = CEOStore(workspacePath: harness.root.path)
    #expect(reloaded.profileID == harness.chief.id)
    #expect(reloaded.reportIDs == nil)
  }

  @Test("The CEO can only give tickets to the bots on its team")
  func teamLimitsWhoGetsWork() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    try services.setReportsToCEO(harness.writer.id, false)
    #expect(services.ceoReports().map(\.name) == ["Researcher"])
    #expect(!services.ceoBrief(profileID: harness.chief.id).contains("Social Guru"))

    let chief = Ticket.Party.bot(harness.chief.id)
    try services.checkCEOMayAssign(to: harness.researcher, actor: chief)
    #expect(throws: (any Error).self) {
      try services.checkCEOMayAssign(to: harness.writer, actor: chief)
    }
    // The person, and bots that aren't the CEO, are not limited by the CEO's team.
    try services.checkCEOMayAssign(to: harness.writer, actor: .person)
    try services.checkCEOMayAssign(to: harness.writer, actor: .bot(harness.researcher.id))

    // Putting everyone back on the team keeps it open, so a bot hired later joins it.
    try services.setReportsToCEO(harness.writer.id, true)
    #expect(services.ceo.reportIDs == nil)
    let hire = try services.saveAgentProfile(
      AgentProfile(name: "Editor", instructions: "Cut video.", provider: .claudeCode))
    #expect(services.reportsToCEO(hire.id))
  }

  @Test("The role moves to another bot, comes off cleanly, and a deleted CEO leaves nobody in it")
  func movingAndRemovingTheRole() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    try services.setReportsToCEO(harness.writer.id, false)

    try services.setCEO(profileID: harness.researcher.id)
    #expect(services.isCEO(harness.researcher.id))
    #expect(!services.isCEO(harness.chief.id))
    // The new CEO starts with everyone, not the old CEO's hand-picked team.
    #expect(services.ceoReports().map(\.name) == ["Chief", "Social Guru"])

    try services.deleteAgentProfile(id: harness.researcher.id)
    #expect(services.ceoProfile == nil)
    #expect(services.ceoReports().isEmpty)

    try services.setCEO(profileID: harness.chief.id)
    try services.setCEO(profileID: nil)
    #expect(services.ceoProfile == nil)
    #expect(services.ceoBrief(profileID: harness.chief.id).isEmpty)
  }

  @Test("Ask me first: a part the CEO hands out waits until the person starts or drops it")
  func handOutCanWaitForThePerson() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    var sent: [(UUID, String)] = []
    services.ticketDispatchOverride = { profile, message, _ in
      sent.append((profile, message))
      return UUID()
    }
    try services.setCEO(profileID: harness.chief.id)
    try services.setCEOPower(.handOut, choice: "ask")
    #expect(services.ceoRules.handOut == .ask)
    #expect(services.ceoBrief(profileID: harness.chief.id).contains("press Start"))

    let chief = Ticket.Party.bot(harness.chief.id)
    let goal = try await services.createTicket(title: "Goal", assignee: harness.chief.id)
    sent.removeAll()
    let part = try await services.createTicket(
      title: "Find leads", assignee: harness.researcher.id, reviewer: chief,
      parentID: goal.id, creator: chief, hold: true)
    #expect(part.isHeld)
    #expect(part.needsPerson)
    #expect(!part.isUndelivered)
    #expect(part.status == .todo)
    // Nothing reached the bot.
    #expect(sent.isEmpty)
    #expect(part.events.last?.text.contains("Waiting for you to start it") == true)

    try await services.startHeldTicket(id: part.id)
    let started = try #require(services.tickets.ticket(id: part.id))
    #expect(started.status == .doing)
    #expect(!started.isHeld)
    #expect(sent.map(\.0) == [harness.researcher.id])
    #expect(sent.first?.1.contains("from Chief") == true)

    // Dropping a held part removes it and tells the CEO, so it doesn't wait for it.
    let second = try await services.createTicket(
      title: "Send messages", assignee: harness.writer.id, reviewer: .person,
      parentID: goal.id, creator: chief, hold: true)
    sent.removeAll()
    try await services.declineHeldTicket(id: second.id)
    #expect(services.tickets.ticket(id: second.id) == nil)
    #expect(sent.map(\.0) == [harness.chief.id])
    #expect(sent.first?.1.contains("decided not to start") == true)
  }

  @Test("The person's limits stop the CEO: parts per ticket, tickets per day, and who reviews")
  func limitsAreEnforced() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    let chief = Ticket.Party.bot(harness.chief.id)
    let goal = try await services.createTicket(title: "Goal", assignee: harness.chief.id)

    try services.setCEOPower(.maxParts, choice: "3")
    for index in 1...3 {
      try services.checkCEOLimits(parentID: goal.id, actor: chief)
      _ = try await services.createTicket(
        title: "Part \(index)", assignee: harness.researcher.id, reviewer: chief,
        parentID: goal.id, creator: chief)
    }
    #expect(throws: (any Error).self) {
      try services.checkCEOLimits(parentID: goal.id, actor: chief)
    }
    // Anyone else is not held to the CEO's limits.
    try services.checkCEOLimits(parentID: goal.id, actor: .person)
    try services.checkCEOLimits(parentID: goal.id, actor: .bot(harness.researcher.id))

    // The daily limit counts what the CEO itself created today.
    #expect(services.ceoTicketsToday() == 3)
    try services.setCEOPower(.maxParts, choice: "10")
    try services.setCEOPower(.maxPerDay, choice: "10")
    try services.checkCEOLimits(parentID: goal.id, actor: chief)
    for index in 4...10 {
      _ = try await services.createTicket(
        title: "Extra \(index)", creator: chief)
    }
    #expect(throws: (any Error).self) {
      try services.checkCEOLimits(parentID: nil, actor: chief)
    }

    // Choices outside the offered ones are ignored, and the rules survive a restart.
    try services.setCEOPower(.maxPerDay, choice: "9999")
    #expect(services.ceoRules.maxPerDay == 10)
    try services.setCEOPower(.reviews, choice: "person")
    let reloaded = CEOStore(workspacePath: harness.root.path)
    #expect(
      reloaded.rules == CEORules(handOut: .auto, reviews: .person, maxParts: 10, maxPerDay: 10))

    // The powers move between the lists as the rules change.
    let powers = services.ceoPowers()
    #expect(powers.first { $0.control == .reviews }?.level == .asks)
    #expect(powers.first { $0.control == .handOut }?.level == .does)
    #expect(powers.first { $0.control == .maxPerDay }?.text.contains("10 tickets") == true)

    // "Everything else" is the bot's own permission mode.
    try services.setCEOPower(.everythingElse, choice: "unrestricted")
    #expect(services.ceoProfile?.permissionMode == "unrestricted")
    #expect(services.ceoPowers().first { $0.control == .everythingElse }?.level == .does)
    try services.setCEOPower(.everythingElse, choice: "workspaceWrite")
    #expect(services.ceoProfile?.permissionMode == "workspaceWrite")
  }

  @Test("The person can let the CEO finish without review, and approve parts on their behalf")
  func approvalRulesCanBeLoosened() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    let chief = Ticket.Party.bot(harness.chief.id)

    // By default a part the person reviews is not the CEO's to approve.
    let goal = try await services.createTicket(title: "Goal", assignee: harness.chief.id)
    let part = try await services.createTicket(
      title: "Send it", assignee: harness.writer.id, reviewer: .person, parentID: goal.id,
      creator: chief)
    _ = try await services.completeTicket(
      id: part.id, result: "Ready.", by: .bot(harness.writer.id))
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(id: part.id, approve: true, by: chief)
    }
    try services.setCEOPower(.approvesForPerson, choice: "yes")
    #expect(services.ceoPowers().first { $0.control == .approvesForPerson }?.level == .does)
    try await services.reviewTicket(id: part.id, approve: true, by: chief)
    #expect(services.tickets.ticket(id: part.id)?.status == .done)
    // With the rule on, the CEO hears when such a part comes back, or it could never use it.
    var told: [(UUID, String)] = []
    services.ticketDispatchOverride = { profile, _, hidden in
      told.append((profile, hidden))
      return UUID()
    }
    let next = try await services.createTicket(
      title: "Send another", assignee: harness.writer.id, reviewer: .person, parentID: goal.id,
      creator: chief)
    told.removeAll()
    _ = try await services.completeTicket(
      id: next.id, result: "Ready.", by: .bot(harness.writer.id))
    #expect(told.map(\.0) == [harness.chief.id])
    #expect(told.first?.1.contains("ticket.review") == true)
    #expect(services.tickets.ticket(id: next.id)?.needsPerson == true)
    // Another bot still can't, and the CEO still can't approve its own work this way.
    let other = try await services.createTicket(
      title: "Other", assignee: harness.writer.id, reviewer: .person)
    _ = try await services.completeTicket(
      id: other.id, result: "Ready.", by: .bot(harness.writer.id))
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(
        id: other.id, approve: true, by: .bot(harness.researcher.id))
    }

    // The CEO's own result waits for the person unless they chose otherwise.
    let handed = try await services.completeTicket(id: goal.id, result: "All done.", by: chief)
    #expect(handed.status == .review)
    #expect(handed.needsPerson)
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(id: goal.id, approve: true, by: chief)
    }
    try services.setCEOPower(.finish, choice: "auto")
    let second = try await services.createTicket(title: "Second goal", assignee: harness.chief.id)
    let closed = try await services.completeTicket(id: second.id, result: "Done.", by: chief)
    #expect(closed.status == .done)
    #expect(closed.events.last?.text.contains("without your review") == true)
    // Only the CEO's own tickets: another bot's work still waits for the person.
    let plain = try await services.createTicket(title: "Plain", assignee: harness.writer.id)
    let waiting = try await services.completeTicket(
      id: plain.id, result: "Done.", by: .bot(harness.writer.id))
    #expect(waiting.status == .review)
  }

  @Test("Rules in the person's own words are kept, told to the CEO, and removable")
  func ownRules() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    try services.addCEORule(level: .never, text: "  Post on LinkedIn without me seeing it  ")
    try services.addCEORule(level: .asks, text: "Spending more than £20")
    try services.addCEORule(level: .does, text: "Rename files in the Clippng folder")
    try services.addCEORule(level: .never, text: "Post on LinkedIn without me seeing it")
    try services.addCEORule(level: .never, text: "   ")
    #expect(services.ceoRules.custom.count == 3)

    let brief = services.ceoBrief(profileID: harness.chief.id)
    #expect(brief.contains("The person's own rules for you"))
    #expect(brief.contains("Never do these:"))
    #expect(brief.contains("- Post on LinkedIn without me seeing it"))
    #expect(brief.contains("ticket.block"))
    #expect(brief.contains("- Spending more than £20"))

    // The rules go with every ticket message to the CEO, not only when its session starts, so
    // a rule added while it is running still reaches it. Other bots never see them.
    var hiddenByBot: [UUID: String] = [:]
    services.ticketDispatchOverride = { profile, _, hidden in
      hiddenByBot[profile] = hidden
      return UUID()
    }
    _ = try await services.createTicket(title: "Goal", assignee: harness.chief.id)
    _ = try await services.createTicket(title: "Other", assignee: harness.writer.id)
    #expect(hiddenByBot[harness.chief.id]?.contains("- Spending more than £20") == true)
    #expect(hiddenByBot[harness.chief.id]?.contains("You are this workspace's CEO") == true)
    #expect(hiddenByBot[harness.writer.id]?.contains("Spending more than") == false)

    let powers = services.ceoPowers()
    let own = powers.filter { $0.customID != nil }
    #expect(own.map(\.level) == [.never, .asks, .does])
    #expect(own.allSatisfy { $0.control == nil })

    let reloaded = CEOStore(workspacePath: harness.root.path)
    #expect(reloaded.rules.custom.map(\.text).contains("Spending more than £20"))
    // A file saved before these rules existed still loads, with the defaults.
    let old = try JSONDecoder().decode(
      CEORules.self,
      from: Data(#"{"handOut":"ask","reviews":"ceo","maxParts":3,"maxPerDay":10}"#.utf8))
    #expect(old.handOut == .ask)
    #expect(old.finish == .review)
    #expect(!old.approvesForPerson)
    #expect(old.custom.isEmpty)

    let id = try #require(services.ceoRules.custom.first?.id)
    try services.removeCEORule(id: id)
    #expect(services.ceoRules.custom.count == 2)
    #expect(!services.ceoBrief(profileID: harness.chief.id).contains("LinkedIn"))
  }

  @Test("The powers shown are the rules Otto enforces, and say so when the bot bypasses prompts")
  func powersMatchTheRules() async throws {
    let harness = try await Harness()
    defer { harness.stop() }
    let services = harness.services
    try services.setCEO(profileID: harness.chief.id)
    let powers = services.ceoPowers()
    #expect(powers.contains { $0.level == .does && $0.text.contains("Give tickets") })
    #expect(powers.contains { $0.level == .never && $0.text == "Review its own work" })
    #expect(
      powers.contains {
        $0.level == .never && $0.text == "Approve its team's work on your behalf"
      })
    #expect(powers.contains { $0.level == .asks && $0.text.contains("Everything else") })
    #expect(
      ApplicationServices.ceoTicketTools == ["ticket.create", "ticket.assign", "ticket.review"])

    // What "never" promises is what the ticket rules actually refuse.
    let chief = Ticket.Party.bot(harness.chief.id)
    let own = try await services.createTicket(title: "Goal", assignee: harness.chief.id)
    _ = try await services.completeTicket(id: own.id, result: "Done.", by: chief)
    await #expect(throws: (any Error).self) {
      try await services.reviewTicket(id: own.id, approve: true, by: chief)
    }
    #expect(services.tickets.ticket(id: own.id)?.status == .review)
  }
}

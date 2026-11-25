import Foundation
import OttoModels
import OttoTools

// MARK: The CEO bot
//
// One bot in a space can be its CEO. It is an ordinary bot with a role: Otto adds a manager's
// brief to what it is told, lets it create, hand out and review tickets without a prompt each
// time, and limits who it may give work to. Everything else about it (its chat, memory and
// own instructions) stays as it was, and taking the role away puts it back.

/// One rule in the CEO's powers, in the words shown to the person.
public struct CEOPower: Identifiable, Equatable, Sendable {
  public enum Level: String, Sendable, CaseIterable {
    case does
    case asks
    case never
  }
  /// A rule the person can change, and the choices it offers.
  public enum Control: String, Sendable {
    case handOut
    case reviews
    case maxParts
    case maxPerDay
    case everythingElse
    case finish
    case approvesForPerson
  }
  public struct Choice: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var selected: Bool
  }
  public var id: String { text }
  public var level: Level
  public var text: String
  public var detail: String?
  /// Nil for the rules Otto builds in.
  public var control: Control?
  public var choices: [Choice] = []
  /// Set for a rule the person wrote: the CEO is told it, Otto doesn't enforce it.
  public var customID: UUID?
}

extension ApplicationServices {
  /// Tools the CEO uses to run its team. Otto lets these through without a prompt for the CEO
  /// only; each still enforces its own rules (who may assign, who may review).
  nonisolated static let ceoTicketTools = ["ticket.create", "ticket.assign", "ticket.review"]

  /// The CEO's profile, if the role is set and that bot still exists.
  public var ceoProfile: AgentProfile? {
    guard let id = ceo.profileID else { return nil }
    return agentProfiles.activeProfiles.first { $0.id == id }
  }

  public func isCEO(_ profileID: UUID?) -> Bool {
    guard let profileID else { return false }
    return ceoProfile?.id == profileID
  }

  /// Gives a bot the CEO role, moves it from the current CEO, or (with nil) removes it.
  public func setCEO(profileID: UUID?) throws {
    if let profileID {
      guard agentProfiles.activeProfiles.contains(where: { $0.id == profileID }) else {
        throw ToolRegistryError.invalidInput("That bot is no longer available.")
      }
    }
    try ceo.set(profileID: profileID)
    objectWillChange.send()
  }

  /// The bots the CEO may give work to: every other bot unless the person picked a team.
  public func ceoReports() -> [AgentProfile] {
    guard let chief = ceoProfile else { return [] }
    let others = agentProfiles.activeProfiles.filter { $0.id != chief.id }
    guard let picked = ceo.reportIDs else { return others }
    return others.filter { picked.contains($0.id) }
  }

  public func reportsToCEO(_ profileID: UUID) -> Bool {
    ceoReports().contains { $0.id == profileID }
  }

  /// Adds a bot to the CEO's team or takes it off.
  public func setReportsToCEO(_ profileID: UUID, _ reports: Bool) throws {
    guard let chief = ceoProfile, chief.id != profileID else { return }
    var ids = Set(ceoReports().map(\.id))
    if reports { ids.insert(profileID) } else { ids.remove(profileID) }
    let everyone = Set(agentProfiles.activeProfiles.map(\.id)).subtracting([chief.id])
    // "Everyone" stays open-ended so a bot hired later joins the team by default.
    try ceo.setReports(ids == everyone ? nil : Array(ids))
    objectWillChange.send()
  }

  /// The manager's brief, added to the CEO's instructions by Otto on every turn.
  func ceoBrief(profileID: UUID) -> String {
    guard isCEO(profileID) else { return "" }
    let team = ceoReports()
    let rows =
      team.isEmpty
      ? "- Nobody reports to you yet. Tell the person, and do small jobs yourself."
      : team.map { bot in
        let job = (bot.jobTitle ?? bot.role).trimmingCharacters(in: .whitespacesAndNewlines)
        return "- \(bot.name)\(job.isEmpty ? "" : ": \(job)")"
      }.joined(separator: "\n")
    return """
      ## You are this workspace's CEO
      The person has made you the manager of their bots. Your job is to get work done through \
      your team with Otto tickets, not to do it yourself.
      - When the person gives you a goal, in chat or as a ticket, first make sure it is a \
      ticket you own: if it arrived in chat, call ticket.create with yourself as assignee.
      - Split it into parts with ticket.create (parent = your ticket) and give each part to \
      the bot best suited to it. Always pass `why`: one or two sentences on why you split it \
      that way and chose that bot. The person reads this to follow your thinking.
      - Write each brief as task, limits and handsBack. Limits matter: say what the bot must \
      not do (for example "drafts only, never send").
      - Prefer the bots you have. A job one bot can do in one go needs no splitting; give it \
      to that bot, or do a small one yourself.
      - Otto messages you when a part is handed back. Check it against its brief and call \
      ticket.review: approve, or send_back with exactly what to fix. Never fix it yourself.
      - Anything that posts, sends, publishes or spends money must be reviewed by the \
      person: set reviewer to person on that part.
      - When every part is done, put the results together into one finished output and hand \
      your own ticket back with ticket.complete. The person reviews it.
      \(Self.ceoRuleLines(ceo.rules))
      - Never poll and never wait in a loop. After handing out work, end your turn.
      You cannot hire new bots yet. If the work needs a bot you do not have, say so in your \
      result or block the ticket with what is missing.

      Your team (you may only give tickets to these bots):
      \(rows)
      """
  }

  /// The person's rules, said to the CEO so it plans around them instead of hitting them.
  nonisolated static func ceoRuleLines(_ rules: CEORules) -> String {
    var lines = [
      "- You may split one ticket into at most \(rules.maxParts) parts and create at most "
        + "\(rules.maxPerDay) tickets a day. Plan within that."
    ]
    if rules.handOut == .ask {
      lines.append(
        "- The person starts each part themselves. A part you create waits until they press "
          + "Start; that is expected, so end your turn and do not do the part yourself.")
    }
    if rules.reviews == .person {
      lines.append(
        "- The person reviews every part. You are not the reviewer of your team's work; you "
          + "hear when each part is approved.")
    }
    if rules.finish == .auto {
      lines.append(
        "- Your own finished ticket counts as done as soon as you hand it back; the person "
          + "does not check it first. Be sure it is right.")
    }
    if rules.approvesForPerson {
      lines.append(
        "- The person lets you approve or send back parts that are down to them to review. "
          + "Use ticket.review on those as you would on your own. Never on your own work.")
    }
    func own(_ level: CEORules.Custom.Level) -> [String] {
      rules.custom.filter { $0.level == level }.map { "  - \($0.text)" }
    }
    let does = own(.does)
    let asks = own(.asks)
    let never = own(.never)
    if !(does + asks + never).isEmpty {
      lines.append("- The person's own rules for you, which you must follow:")
      if !does.isEmpty {
        lines.append("  You may do these without asking:")
        lines += does
      }
      if !asks.isEmpty {
        lines.append(
          "  Ask the person first (call ticket.block on your ticket with the question and "
            + "wait) before any of these:")
        lines += asks
      }
      if !never.isEmpty {
        lines.append("  Never do these:")
        lines += never
      }
    }
    return lines.joined(separator: "\n      ")
  }

  /// Extra Otto tools a bot may use without a provider prompt: the CEO's ticket tools.
  func preapprovedTools(forNode nodeID: UUID) -> [String] {
    isCEO(profileID(forNode: nodeID)) ? Self.ceoTicketTools : []
  }

  /// The CEO may only hand work to its own team. Anyone else is free to choose.
  func checkCEOMayAssign(to profile: AgentProfile, actor: Ticket.Party) throws {
    guard case .bot(let actorID) = actor, isCEO(actorID), profile.id != actorID else { return }
    guard reportsToCEO(profile.id) else {
      let names = ceoReports().map(\.name).joined(separator: ", ")
      throw ToolRegistryError.invalidInput(
        "\(profile.name) is not on your team. You can give tickets to: "
          + (names.isEmpty ? "nobody yet" : names) + ".")
    }
  }

  /// The CEO's rules as the person set them.
  public var ceoRules: CEORules { ceo.rules }

  /// Changes one of the CEO's rules. `choice` is the id of one of the rule's choices.
  public func setCEOPower(_ control: CEOPower.Control, choice: String) throws {
    var rules = ceo.rules
    switch control {
    case .handOut:
      guard let value = CEORules.HandOut(rawValue: choice) else { return }
      rules.handOut = value
    case .reviews:
      guard let value = CEORules.Reviews(rawValue: choice) else { return }
      rules.reviews = value
    case .maxParts:
      guard let value = Int(choice), CEORules.partChoices.contains(value) else { return }
      rules.maxParts = value
    case .maxPerDay:
      guard let value = Int(choice), CEORules.dailyChoices.contains(value) else { return }
      rules.maxPerDay = value
    case .finish:
      guard let value = CEORules.Finish(rawValue: choice) else { return }
      rules.finish = value
    case .approvesForPerson:
      guard ["yes", "no"].contains(choice) else { return }
      rules.approvesForPerson = choice == "yes"
    case .everythingElse:
      // This one is the bot's own permission mode, the same setting as in Edit bot.
      guard var profile = ceoProfile, ["workspaceWrite", "unrestricted"].contains(choice) else {
        return
      }
      profile.permissionMode = choice
      _ = try saveAgentProfile(profile)
      objectWillChange.send()
      return
    }
    try ceo.setRules(rules)
    objectWillChange.send()
  }

  /// Adds a rule in the person's own words. The CEO is told it on every turn.
  public func addCEORule(level: CEORules.Custom.Level, text: String) throws {
    let clean = String(
      text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
        .prefix(CEORules.maximumCustomCharacters))
    guard !clean.isEmpty else { return }
    var rules = ceo.rules
    guard rules.custom.count < CEORules.maximumCustomRules else {
      throw ToolRegistryError.invalidInput(
        "That is \(CEORules.maximumCustomRules) rules of your own already. Remove one first.")
    }
    guard !rules.custom.contains(where: { $0.level == level && $0.text == clean }) else { return }
    rules.custom.append(CEORules.Custom(level: level, text: clean))
    try ceo.setRules(rules)
    objectWillChange.send()
  }

  public func removeCEORule(id: UUID) throws {
    var rules = ceo.rules
    rules.custom.removeAll { $0.id == id }
    try ceo.setRules(rules)
    objectWillChange.send()
  }

  /// Whether the CEO may decide on a ticket the person was down to review. Never its own work.
  func ceoMayReviewForPerson(_ ticket: Ticket, actor: Ticket.Party) -> Bool {
    guard case .bot(let actorID) = actor, isCEO(actorID), ceo.rules.approvesForPerson,
      ticket.reviewer == .person, ticket.assigneeProfileID != actorID
    else { return false }
    return true
  }

  /// How many tickets the CEO has created since midnight.
  func ceoTicketsToday(now: Date = .now, calendar: Calendar = .current) -> Int {
    guard let chief = ceoProfile else { return 0 }
    let start = calendar.startOfDay(for: now)
    return tickets.all.filter { $0.creator == .bot(chief.id) && $0.createdAt >= start }.count
  }

  /// The person's limits on how much the CEO may hand out. A refusal says what to do instead,
  /// because the reader is the bot.
  func checkCEOLimits(parentID: UUID?, actor: Ticket.Party) throws {
    guard case .bot(let actorID) = actor, isCEO(actorID) else { return }
    let rules = ceo.rules
    if let parentID, tickets.children(of: parentID).count >= rules.maxParts {
      throw ToolRegistryError.invalidInput(
        "The person lets you split a ticket into at most \(rules.maxParts) parts, and this "
          + "one already has that many. Work with the parts you have.")
    }
    if ceoTicketsToday() >= rules.maxPerDay {
      throw ToolRegistryError.invalidInput(
        "You have reached the person's limit of \(rules.maxPerDay) tickets a day. Stop "
          + "creating tickets, and hand back or block your ticket saying the limit was reached.")
    }
  }

  /// What the CEO can do, in plain words. Each line is a rule Otto enforces; the ones with a
  /// control are the person's to change.
  public func ceoPowers() -> [CEOPower] {
    let name = ceoProfile?.name ?? "The CEO"
    let rules = ceo.rules
    let unrestricted = ceoProfile?.permissionMode == "unrestricted"
    func pick(_ pairs: [(String, String)], _ current: String) -> [CEOPower.Choice] {
      pairs.map { CEOPower.Choice(id: $0.0, title: $0.1, selected: $0.0 == current) }
    }
    let handOut = CEOPower(
      level: rules.handOut == .auto ? .does : .asks,
      text: "Give tickets to the bots on its team",
      detail: rules.handOut == .auto
        ? "They start straight away."
        : "Each part waits on the ticket until you press Start.",
      control: .handOut,
      choices: pick(
        [("auto", "Without asking"), ("ask", "Ask me first")], rules.handOut.rawValue))
    let reviews = CEOPower(
      level: rules.reviews == .ceo ? .does : .asks,
      text: "Review its team's work",
      detail: rules.reviews == .ceo
        ? "\(name) checks each part and sends it back if it misses the brief."
        : "Every part comes to you to approve.",
      control: .reviews,
      choices: pick(
        [("ceo", "\(name) reviews"), ("person", "I review every part")],
        rules.reviews.rawValue))
    let everythingElse = CEOPower(
      level: unrestricted ? .does : .asks,
      text: "Everything else that changes something",
      detail: unrestricted
        ? "Commands, files and your apps, with no prompts. This is \(name)’s permission mode."
        : "Commands, files and your apps ask in its chat or on the ticket.",
      control: .everythingElse,
      choices: pick(
        [("workspaceWrite", "Ask me first"), ("unrestricted", "Without asking")],
        unrestricted ? "unrestricted" : "workspaceWrite"))
    let fixed = [
      CEOPower(level: .does, text: "Create tickets and split them into parts"),
      CEOPower(level: .does, text: "Read tickets and note why it made a decision"),
      CEOPower(
        level: rules.finish == .review ? .asks : .does,
        text: "Finish its own ticket",
        detail: rules.finish == .review
          ? "You review the finished result before it counts as done."
          : "Its finished result counts as done without you checking it.",
        control: .finish,
        choices: pick(
          [("review", "I review it"), ("auto", "Done without my review")],
          rules.finish.rawValue)),
      CEOPower(
        level: .asks, text: "Send email or anything else Otto confirms",
        detail: "Otto shows its own confirmation before these run."),
      CEOPower(
        level: rules.approvesForPerson ? .does : .never,
        text: "Approve its team's work on your behalf",
        detail: rules.approvesForPerson
          ? "\(name) may approve or send back a part that was down to you to review."
          : "A part you are down to review waits for you.",
        control: .approvesForPerson,
        choices: pick(
          [("no", "Never"), ("yes", "\(name) may")], rules.approvesForPerson ? "yes" : "no")),
      CEOPower(level: .never, text: "Review its own work"),
      CEOPower(level: .never, text: "Give work to a bot that isn't on its team"),
      CEOPower(
        level: .never, text: "Split a ticket into more than \(rules.maxParts) parts",
        detail: nil, control: .maxParts,
        choices: pick(
          CEORules.partChoices.map { ("\($0)", "\($0) parts") }, "\(rules.maxParts)")),
      CEOPower(
        level: .never, text: "Create more than \(rules.maxPerDay) tickets in a day",
        detail: "\(ceoTicketsToday()) so far today. At the limit it stops and tells you.",
        control: .maxPerDay,
        choices: pick(
          CEORules.dailyChoices.map { ("\($0)", "\($0) a day") }, "\(rules.maxPerDay)")),
      CEOPower(
        level: .never, text: "Split a ticket more than \(TicketStore.maximumDepth) levels deep"),
      CEOPower(level: .never, text: "Hire a new bot", detail: "Not built yet."),
    ]
    let own = rules.custom.map { rule in
      CEOPower(
        level: CEOPower.Level(rawValue: rule.level.rawValue) ?? .asks, text: rule.text,
        detail: nil, customID: rule.id)
    }
    // Editable rules first in their column, so what can be changed is what you see first.
    return [handOut, reviews, everythingElse] + fixed + own
  }
}

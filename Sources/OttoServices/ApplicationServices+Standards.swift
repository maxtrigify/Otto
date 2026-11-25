import Foundation
import OttoModels
import OttoRuntime
import OttoTools

// MARK: Standards and the checker (#127)
//
// A bot keeps standards: what its work must get right, in the person's words. A ticket can add
// its own. When the bot hands the ticket back, a model from another family checks the work
// against them, seeing the brief, the work and what Otto measured, never the bot's chat.
// Anything that fails goes back to the bot to fix, at most twice; then the work reaches the
// reviewer with what was checked. What the checker can't judge always goes to the person.

extension ApplicationServices {
  // MARK: A bot's standards

  public func botStandards(_ profileID: UUID) -> [BotStandard] {
    standards.standards(for: profileID)
  }

  public func setBotStandards(_ list: [BotStandard], for profileID: UUID) throws {
    try standards.set(list, for: profileID)
    objectWillChange.send()
  }

  public func addBotStandards(
    _ texts: [String], source: BotStandard.Source = .person, to profileID: UUID
  ) throws {
    try standards.add(texts, source: source, to: profileID)
    objectWillChange.send()
  }

  /// The bot's standards, then the ticket's own.
  func standardsToCheck(_ ticket: Ticket) -> [(text: String, ticketOnly: Bool)] {
    let kept = ticket.assigneeProfileID.map { standards.standards(for: $0) } ?? []
    return kept.map { ($0.text, false) }
      + (ticket.standards ?? []).map { (StandardsStore.clean($0), true) }.filter {
        !$0.0.isEmpty
      }
  }

  /// Told to the bot with the brief, so it aims at the same bar it is checked against.
  func standardsBriefing(_ ticket: Ticket) -> String {
    let list = standardsToCheck(ticket)
    guard !list.isEmpty else { return "" }
    return "\nBefore anyone reviews it, another model checks your work against these "
      + "standards. Anything that fails comes back to you to fix:\n"
      + list.map { "- \($0.text)" }.joined(separator: "\n")
  }

  // MARK: Picking the checker

  func keyedCheckerProviders() async -> Set<OttoHarnessProvider> {
    if let checkerKeysOverride { return checkerKeysOverride }
    var keyed = Set<OttoHarnessProvider>()
    for provider in StandardsChecker.preference {
      if let key = try? await OpenAIDirectAdapter.defaultCredential(for: provider),
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        keyed.insert(provider)
      }
    }
    return keyed
  }

  /// The model that would check this bot's work, or nil when no key is saved.
  public func checkerModel(forBot profileID: UUID?) async -> CheckerModel? {
    let profile = profileID.flatMap { id in agentProfiles.activeProfiles.first { $0.id == id } }
    return StandardsChecker.choose(
      botFamily: profile.flatMap(StandardsChecker.family(of:)),
      keyed: await keyedCheckerProviders())
  }

  func standardsJudge(for model: CheckerModel) async throws -> any StandardsJudge {
    if let standardsJudgeOverride { return standardsJudgeOverride }
    guard
      let key = try await OpenAIDirectAdapter.defaultCredential(for: model.provider)?
        .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
    else { throw StandardsCheckError.noChecker }
    return HarnessStandardsJudge(model: model, apiKey: key)
  }

  // MARK: Checking

  /// One pass of the checker over a ticket's handed-back work.
  func checkWork(_ ticket: Ticket) async throws -> StandardsCheck {
    let list = standardsToCheck(ticket)
    guard let model = await checkerModel(forBot: ticket.assigneeProfileID) else {
      throw StandardsCheckError.noChecker
    }
    let judge = try await standardsJudge(for: model)
    let result = ticket.result ?? ""
    let facts = await StandardsChecker.facts(forResult: result, workspacePath: workspacePath)
    let reply = try await judge.ask(
      system: StandardsChecker.checkInstructions,
      prompt: StandardsChecker.checkPrompt(
        brief: ticket.brief, result: result, facts: facts, standards: list.map(\.text)))
    let verdicts = try StandardsChecker.parseVerdicts(reply, standards: list)
    return StandardsCheck(
      checker: model.label + (model.sameFamily ? " (same family as the bot)" : ""),
      attempt: ticket.checksThisRound + 1, verdicts: verdicts)
  }

  /// Checks handed-back work, then sends failures back to the bot or the work on to review.
  func runStandardsCheck(ticketID: UUID) async {
    guard let ticket = tickets.ticket(id: ticketID), ticket.isChecking else { return }
    let check: StandardsCheck
    do {
      check = try await checkWork(ticket)
    } catch {
      // A check that can't run must never hold the work up; the reviewer decides as before.
      guard
        let moved = try? tickets.update(
          id: ticketID,
          { ticket in
            ticket.checking = nil
            ticket.status = .review
            ticket.events.append(
              Ticket.Event(
                kind: .problem, actor: .person,
                text: "Couldn’t check this against its standards: \(error.localizedDescription)"))
          })
      else { return }
      await handToReviewer(moved)
      return
    }
    let tooManyTries = check.attempt >= StandardsChecker.maximumChecksPerRound
    let sendBack = !check.failures.isEmpty && !tooManyTries
    let text =
      check.summary
      + (sendBack
        ? ". Sent back to fix: " + check.failures.map(\.standard).joined(separator: "; ")
        : "")
    guard
      let updated = try? tickets.update(
        id: ticketID,
        { ticket in
          ticket.checking = nil
          ticket.checks = (ticket.checks ?? []) + [check]
          ticket.status = sendBack ? .doing : .review
          ticket.events.append(
            Ticket.Event(kind: .checked, actor: .session("Checker"), text: text))
        })
    else { return }
    guard sendBack else {
      await handToReviewer(updated)
      return
    }
    let fixes = check.failures.map { "- \($0.standard)\n  What's wrong: \($0.evidence)" }
      .joined(separator: "\n")
    try? await redispatch(
      updated,
      message: """
        Otto's checker went over ticket \(updated.label) (\(updated.title)) before review. \
        These standards failed:
        \(fixes)
        Fix them and hand it back again with ticket.complete. \
        \(StandardsChecker.maximumChecksPerRound - check.attempt) more \
        \(StandardsChecker.maximumChecksPerRound - check.attempt == 1 ? "try" : "tries") \
        before it goes to review as it is.
        """)
  }

  // MARK: Learning from a send-back

  /// Turns the person's send-back note into standards and tries each on the work that was sent
  /// back. Only ones that fail that work would have caught the problem.
  public func proposeStandards(ticketID: UUID, note: String) async throws -> [StandardProposal] {
    guard let ticket = tickets.ticket(id: ticketID) else { throw TicketStore.TicketError.unknown }
    let note = TicketStore.clip(note)
    guard !note.isEmpty else { return [] }
    guard let model = await checkerModel(forBot: ticket.assigneeProfileID) else {
      throw StandardsCheckError.noChecker
    }
    let judge = try await standardsJudge(for: model)
    let result = ticket.result ?? ""
    let facts = await StandardsChecker.facts(forResult: result, workspacePath: workspacePath)
    let reply = try await judge.ask(
      system: StandardsChecker.proposalInstructions,
      prompt: StandardsChecker.proposalPrompt(
        note: note, brief: ticket.brief, result: result, facts: facts))
    return try StandardsChecker.parseProposals(reply)
  }
}

// MARK: The tool

extension ApplicationServices {
  func registerStandardsTools() async throws {
    try await registry.register(
      BotStandardsTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.toolBotStandards(input, context: context)
      })
  }

  private func toolBotStandards(_ input: BotStandardsInput, context: ToolContext) throws
    -> BotStandardsOutput
  {
    let profile = try resolveTicketBot(input.bot)
    let action = (input.action ?? "list").lowercased()
    if action != "list" {
      // A bot never sets its own bar.
      if ticketActor(context) == .bot(profile.id) {
        throw ToolRegistryError.invalidInput(
          "A bot can't change its own standards. Ask the person.")
      }
      let texts = (input.standards ?? []).map(StandardsStore.clean).filter { !$0.isEmpty }
      guard !texts.isEmpty else {
        throw ToolRegistryError.invalidInput("Pass the standards to \(action) in standards.")
      }
      switch action {
      case "add":
        try addBotStandards(texts, to: profile.id)
      case "remove":
        let drop = Set(texts.map { $0.lowercased() })
        try setBotStandards(
          botStandards(profile.id).filter { !drop.contains($0.text.lowercased()) },
          for: profile.id)
      default:
        throw ToolRegistryError.invalidInput("action is list, add or remove.")
      }
    }
    let list = botStandards(profile.id)
    return BotStandardsOutput(
      bot: profile.name, standards: list.map(\.text),
      note: list.isEmpty
        ? "\(profile.name) has no standards yet."
        : "Another model checks \(profile.name)'s ticket work against these before review.")
  }
}

public struct BotStandardsInput: Codable, Sendable {
  public var bot: String
  public var action: String?
  public var standards: [String]?
  public init(bot: String, action: String? = nil, standards: [String]? = nil) {
    self.bot = bot
    self.action = action
    self.standards = standards
  }
}

public struct BotStandardsOutput: Codable, Sendable, Equatable {
  public var bot: String
  public var standards: [String]
  public var note: String
}

public struct BotStandardsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "bot.standards",
    description: """
      Lists, adds or removes a bot's standards: short yes/no checks its work must pass, in the \
      person's words, such as "Under 60 seconds" or "Spell Clippng with two p's". When the bot \
      hands a ticket back, another model checks the work against them before review and sends \
      failures back to the bot to fix. Add standards only when the person asks. A bot can't \
      change its own.
      """,
    inputSchema: .objectSchema(
      properties: [
        "bot": .stringSchema(description: "The bot's name"),
        "action": .stringSchema(description: "list (default), add or remove"),
        "standards": .arraySchema(
          of: .stringSchema(), description: "The standards to add or remove"),
      ], required: ["bot"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (BotStandardsInput, ToolContext) async throws -> BotStandardsOutput
  public init(
    handler:
      @escaping @Sendable (BotStandardsInput, ToolContext) async throws
      -> BotStandardsOutput
  ) { self.handler = handler }
  public func call(_ input: BotStandardsInput, context: ToolContext) async throws
    -> BotStandardsOutput
  { try await handler(input, context) }
}

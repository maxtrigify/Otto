import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoServices

/// Issue #127: work is checked against the bot's standards by a model from another family
/// before anyone reviews it; failures go back to the bot, at most twice.
@MainActor
@Suite("Standards and the checker", .serialized)
struct StandardsCheckerTests {
  /// Answers in turn with the replies it was given, and remembers what it was asked.
  final class ScriptedJudge: StandardsJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var prompts: [String] = []

    init(_ replies: [String]) { self.replies = replies }

    func ask(system: String, prompt: String) async throws -> String { next(prompt) }

    private func next(_ prompt: String) -> String {
      lock.withLock {
        prompts.append(prompt)
        return replies.count > 1 ? replies.removeFirst() : (replies.first ?? "")
      }
    }
  }

  @MainActor private final class Harness {
    let root: URL
    let services: ApplicationServices
    let guru: AgentProfile
    var sent: [(profile: UUID, message: String, hidden: String)] = []

    init(judge: ScriptedJudge?, keyed: Set<OttoHarnessProvider> = [.openAI]) async throws {
      root = FileManager.default.temporaryDirectory.appending(path: "standards-\(UUID())")
      services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
      await services.start()
      guru = try services.saveAgentProfile(
        AgentProfile(name: "Social Guru", instructions: "Write posts.", provider: .claudeCode))
      services.standardsJudgeOverride = judge
      services.checkerKeysOverride = keyed
      services.ticketDispatchOverride = { [unowned self] profile, message, hidden in
        self.sent.append((profile, message, hidden))
        return UUID()
      }
    }

    func stop() {
      services.stop()
      try? FileManager.default.removeItem(at: root)
    }

    /// Waits for the background check to finish.
    func settled(_ id: UUID) async throws -> Ticket {
      for _ in 0..<200 {
        if let ticket = services.tickets.ticket(id: id), !ticket.isChecking { return ticket }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw CancellationError()
    }

    /// Waits for a message to the bot that contains `text`: the send-back is delivered just
    /// after the ticket settles, so reading `sent.last` straight away can be too early.
    func message(containing text: String) async throws -> (
      profile: UUID, message: String, hidden: String
    ) {
      for _ in 0..<300 {
        if let found = sent.last(where: { $0.message.contains(text) }) { return found }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw CancellationError()
    }
  }

  static func reply(_ outcomes: [String]) -> String {
    let items = outcomes.enumerated().map {
      #"{"index":\#($0.offset + 1),"outcome":"\#($0.element)","evidence":"seen"}"#
    }
    return #"{"verdicts":[\#(items.joined(separator: ","))]}"#
  }

  // MARK: Picking the checker

  @Test("The checker comes from a different family to the bot when a key allows")
  func checkerFromAnotherFamily() {
    let picked = StandardsChecker.choose(botFamily: .anthropic, keyed: [.anthropic, .openAI])
    #expect(picked?.provider == .openAI)
    #expect(picked?.sameFamily == false)
    #expect(
      StandardsChecker.choose(botFamily: .openAI, keyed: [.openAI, .gemini])?.provider == .gemini)
  }

  @Test("With only the bot's own family keyed, it says the check is weaker; with none, no check")
  func checkerFallbacks() {
    let same = StandardsChecker.choose(botFamily: .anthropic, keyed: [.anthropic])
    #expect(same?.provider == .anthropic)
    #expect(same?.sameFamily == true)
    #expect(StandardsChecker.choose(botFamily: .anthropic, keyed: []) == nil)
  }

  @Test("A bot's model family follows its harness and, for Otto Harness, its chosen model")
  func families() {
    #expect(
      StandardsChecker.family(of: AgentProfile(name: "A", instructions: "", provider: .claudeCode))
        == .anthropic)
    #expect(
      StandardsChecker.family(of: AgentProfile(name: "B", instructions: "", provider: .codex))
        == .openAI)
    #expect(
      StandardsChecker.family(
        of: AgentProfile(name: "C", instructions: "", provider: .openAI, model: "gemini/x"))
        == .gemini)
  }

  // MARK: Reading the checker

  @Test("A verdict the checker skipped or garbled counts as unsure, never as a pass")
  func skippedIsUnsure() throws {
    let reply = """
      Here you go:
      ```json
      {"verdicts":[{"index":1,"outcome":"PASS","evidence":"0:52"},{"index":3,"outcome":"maybe"}]}
      ```
      """
    let verdicts = try StandardsChecker.parseVerdicts(
      reply, standards: [("Under 60s", false), ("Logo at end", false), ("Use Priya", true)])
    #expect(verdicts.map(\.outcome) == [.pass, .unsure, .unsure])
    #expect(verdicts[0].evidence == "0:52")
    #expect(verdicts[2].ticketOnly)
    #expect(throws: StandardsCheckError.unreadableReply) {
      _ = try StandardsChecker.parseVerdicts("no json here", standards: [("A", false)])
    }
  }

  @Test("Otto measures the files the work mentions; the checker reads them, not the claim")
  func factsFromFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "facts-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "# Launch post\nClippng saves your Sundays.".write(
      to: root.appending(path: "post.md"), atomically: true, encoding: .utf8)
    let result = "Draft is at [post](\(root.path)/post.md) and the cut is at /nowhere/reel.mp4."
    let facts = await StandardsChecker.facts(forResult: result, workspacePath: root.path)
    #expect(facts.count == 2)
    #expect(facts[0].contains("Clippng saves your Sundays."))
    #expect(facts[1].contains("no file at /nowhere/reel.mp4"))
    // A relative name counts only when it is a real file in the workspace.
    let relative = await StandardsChecker.facts(
      forResult: "See post.md, not ghost.md", workspacePath: root.path)
    #expect(relative.count == 1)
  }

  @Test("A path with a space is read whole when it is quoted, in backticks or a link")
  func pathsWithSpaces() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "facts \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "clippng post.md")
    try "Clippng now adds captions.".write(to: file, atomically: true, encoding: .utf8)
    for result in [
      "**File:** `\(file.path)`", "[post](<\(file.path)>)", "Saved to \"\(file.path)\".",
    ] {
      let paths = StandardsChecker.mentionedPaths(in: result, workspacePath: "/")
      #expect(paths == [file.path], "\(result)")
    }
    let facts = await StandardsChecker.facts(
      forResult: "**File:** `\(file.path)`", workspacePath: "/")
    #expect(facts.first?.contains("Clippng now adds captions.") == true)
  }

  // MARK: The loop

  @Test("Failures go back to the bot with what to fix; once fixed the work reaches review")
  func failThenFix() async throws {
    let judge = ScriptedJudge([Self.reply(["pass", "fail"]), Self.reply(["pass", "pass"])])
    let harness = try await Harness(judge: judge)
    defer { harness.stop() }
    let services = harness.services
    try services.addBotStandards(["Spell Clippng with two p's"], to: harness.guru.id)
    let ticket = try await services.createTicket(
      title: "Reel script", assignee: harness.guru.id, standards: ["Under 60 seconds"])
    // The bot is told the bar it will be checked against.
    #expect(harness.sent.last?.hidden.contains("Spell Clippng with two p's") == true)
    #expect(harness.sent.last?.hidden.contains("Under 60 seconds") == true)

    let worker = Ticket.Party.bot(harness.guru.id)
    let handed = try await services.completeTicket(
      id: ticket.id, result: "A 75-second script", by: worker)
    #expect(handed.isChecking)
    #expect(!handed.needsPerson)
    var checked = try await harness.settled(ticket.id)
    #expect(checked.status == .doing)
    #expect(checked.checks?.count == 1)
    #expect(checked.events.last?.kind == .checked)
    let back = try await harness.message(containing: "These standards failed")
    #expect(back.message.contains("Under 60 seconds"))
    #expect(!back.message.contains("Spell Clippng"))
    // The checker saw the brief and the work, never the bot's chat.
    #expect(judge.prompts[0].contains("A 75-second script"))
    #expect(judge.prompts[0].contains("TASK: Reel script"))

    _ = try await services.completeTicket(
      id: ticket.id, result: "A 52-second script", by: worker)
    checked = try await harness.settled(ticket.id)
    #expect(checked.status == .review)
    #expect(checked.needsPerson)
    #expect(checked.checksThisRound == 2)
    #expect(checked.latestCheck?.verdicts.last?.ticketOnly == true)
    #expect(checked.latestCheck?.checker == "OpenAI gpt-5.6")
  }

  @Test("After two fixes that still fail, the work goes to review as it is, with the failures")
  func triesRunOut() async throws {
    let harness = try await Harness(judge: ScriptedJudge([Self.reply(["fail"])]))
    defer { harness.stop() }
    let services = harness.services
    try services.addBotStandards(["Under 60 seconds"], to: harness.guru.id)
    let ticket = try await services.createTicket(title: "Reel", assignee: harness.guru.id)
    let worker = Ticket.Party.bot(harness.guru.id)
    var current = ticket
    for attempt in 1...3 {
      _ = try await services.completeTicket(
        id: ticket.id, result: "Try \(attempt)", by: worker)
      current = try await harness.settled(ticket.id)
    }
    #expect(current.status == .review)
    #expect(current.checksThisRound == 3)
    #expect(current.latestCheck?.failures.count == 1)
    #expect(harness.sent.filter { $0.message.contains("These standards failed") }.count == 2)
  }

  @Test("What the checker can't judge comes to the person instead of going back to the bot")
  func unsureGoesToPerson() async throws {
    let harness = try await Harness(judge: ScriptedJudge([Self.reply(["unsure"])]))
    defer { harness.stop() }
    try harness.services.addBotStandards(["Ends on the brand orange"], to: harness.guru.id)
    let ticket = try await harness.services.createTicket(
      title: "Reel", assignee: harness.guru.id)
    let sentBefore = harness.sent.count
    _ = try await harness.services.completeTicket(
      id: ticket.id, result: "reel.mp4", by: .bot(harness.guru.id))
    let checked = try await harness.settled(ticket.id)
    #expect(checked.status == .review)
    #expect(checked.latestCheck?.unsure.count == 1)
    #expect(harness.sent.count == sentBefore)
  }

  @Test("With no model to check with, the work still reaches review and the ticket says why")
  func noCheckerNeverBlocks() async throws {
    let harness = try await Harness(judge: nil, keyed: [])
    defer { harness.stop() }
    try harness.services.addBotStandards(["Under 60 seconds"], to: harness.guru.id)
    let ticket = try await harness.services.createTicket(
      title: "Reel", assignee: harness.guru.id)
    _ = try await harness.services.completeTicket(
      id: ticket.id, result: "Done", by: .bot(harness.guru.id))
    let checked = try await harness.settled(ticket.id)
    #expect(checked.status == .review)
    #expect(checked.events.last?.kind == .problem)
    #expect(checked.events.last?.text.contains("Settings → Models") == true)
  }

  @Test("Without standards nothing changes: the work goes straight to review")
  func noStandardsNoCheck() async throws {
    let judge = ScriptedJudge([Self.reply(["fail"])])
    let harness = try await Harness(judge: judge)
    defer { harness.stop() }
    let ticket = try await harness.services.createTicket(
      title: "Reel", assignee: harness.guru.id)
    let handed = try await harness.services.completeTicket(
      id: ticket.id, result: "Done", by: .bot(harness.guru.id))
    #expect(handed.status == .review)
    #expect(!handed.isChecking)
    #expect(judge.prompts.isEmpty)
  }

  @Test("While it is being checked the bot can't hand it back again, and isn't flagged as quiet")
  func checkingIsNotQuiet() async throws {
    let harness = try await Harness(judge: ScriptedJudge([Self.reply(["pass"])]))
    defer { harness.stop() }
    let services = harness.services
    try services.addBotStandards(["Under 60 seconds"], to: harness.guru.id)
    let ticket = try await services.createTicket(title: "Reel", assignee: harness.guru.id)
    let handed = try await services.completeTicket(
      id: ticket.id, result: "Done", by: .bot(harness.guru.id))
    // The bot's turn ends while the check runs.
    services.flagUnreportedTickets(nodeID: try #require(handed.agentNodeID), failed: false)
    #expect(services.tickets.ticket(id: ticket.id)?.isUnreported == false)
    await #expect(throws: TicketStore.TicketError.self) {
      _ = try await services.completeTicket(
        id: ticket.id, result: "Again", by: .bot(harness.guru.id))
    }
    _ = try await harness.settled(ticket.id)
  }

  // MARK: Learning from a send-back

  @Test("A send-back note becomes standards tried on that work; ticked ones are kept")
  func proposalsFromNote() async throws {
    let judge = ScriptedJudge([
      #"{"standards":[{"text":"The end card stays on screen for at least 2 seconds","catches":true,"evidence":"0.8s"},{"text":"The ending feels polished","catches":false,"evidence":"passes"}]}"#
    ])
    let harness = try await Harness(judge: judge)
    defer { harness.stop() }
    let services = harness.services
    let ticket = try await services.createTicket(title: "Reel", assignee: harness.guru.id)
    _ = try await services.completeTicket(
      id: ticket.id, result: "reel.mp4", by: .bot(harness.guru.id))
    let proposals = try await services.proposeStandards(
      ticketID: ticket.id, note: "Hold the end card longer")
    #expect(proposals.map(\.catchesIt) == [true, false])
    #expect(judge.prompts[0].contains("Hold the end card longer"))
    try services.addBotStandards(
      proposals.filter(\.catchesIt).map(\.text), source: .note(ticket: ticket.label),
      to: harness.guru.id)
    let kept = services.botStandards(harness.guru.id)
    #expect(kept.map(\.text) == ["The end card stays on screen for at least 2 seconds"])
    #expect(kept.first?.source == .note(ticket: "T-1"))
  }

  @Test("Standards are kept per bot, without blanks or repeats, and survive a restart")
  func storeKeepsStandards() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let bot = UUID()
    let store = StandardsStore(workspacePath: root.path)
    try store.add(
      ["Under 60 seconds", "  ", "under 60 seconds", "Line one\nline two"], source: .person, to: bot
    )
    #expect(store.standards(for: bot).map(\.text) == ["Under 60 seconds", "Line one line two"])
    let reopened = StandardsStore(workspacePath: root.path)
    #expect(reopened.standards(for: bot).count == 2)
    #expect(reopened.standards(for: UUID()).isEmpty)
  }
}

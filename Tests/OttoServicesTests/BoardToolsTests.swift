import Foundation
import OttoCore
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Whiteboards")
struct BoardToolsTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "board-\(UUID())")
  }

  private let caller = ToolContext(
    actorID: "agent", scopes: [.canvasWrite, .agentRead], source: .agent)

  private func call(
    _ services: ApplicationServices, _ name: String, _ input: some Encodable & Sendable
  ) async throws -> OfficeOutput {
    try await services.registry.call(
      name: name, input: try JSONValue.encode(input), context: caller
    ).decode(OfficeOutput.self)
  }

  @Test("An agent lays out a board, joins notes with arrows, moves and removes them")
  func boardFlow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    let created = try await call(
      services, "docs.create", OfficeCreateInput(title: "Launch plan", kind: "whiteboard"))
    #expect(created.file?.path == "Documents/Launch plan.ottoboard")
    #expect(created.file?.kind == "whiteboard")
    let path = "Documents/Launch plan.ottoboard"
    #expect(try services.office.loadBoard(path: path).items.isEmpty)

    let added = try await call(
      services, "board.add",
      BoardItemsInput(
        doc: "Launch plan",
        items: [
          BoardItemInput(id: "now", kind: "frame", text: "Now", x: 0, y: 0, w: 440, h: 300),
          BoardItemInput(id: "draft", kind: "sticky", text: "Draft the post", x: 20, y: 60),
          BoardItemInput(
            id: "ship", kind: "note", text: "Ship 0.3", x: 220, y: 60, color: "green"),
          BoardItemInput(kind: "arrow", text: "then", from: "draft", to: "ship"),
          BoardItemInput(kind: "diamond", text: "Ready?", x: 600, y: 60),
        ]))
    #expect(added.applied)
    var board = try services.office.loadBoard(path: path)
    #expect(board.items.count == 5)
    #expect(board.item("draft")?.kind == .note)
    #expect(board.item("draft")?.tint == .yellow)
    #expect(board.item("ship")?.tint == .green)
    #expect(board.items.last?.shape == .diamond)
    // What the agent touched glows on the open board, and the board is told to reload.
    #expect(services.office.agentTouched[path]?.contains("ship") == true)
    #expect(services.office.revisions[path] == 1)

    let read = try await call(services, "docs.read", OfficeDocRef(doc: "Launch plan"))
    let outline = try #require(read.content)
    #expect(outline.contains("[now] frame at 0,0 440x300 \"Now\" contains:"))
    #expect(outline.contains("  [draft] note yellow at 20,60 180x120 \"Draft the post\""))
    #expect(outline.contains("arrow draft → ship \"then\""))
    #expect(outline.contains("Outside any frame:"))

    _ = try await call(
      services, "board.update",
      BoardItemsInput(
        doc: "Launch plan",
        items: [BoardItemInput(id: "ship", text: "Ship 0.3 on Friday", x: 240, color: "pink")]))
    board = try services.office.loadBoard(path: path)
    #expect(board.item("ship")?.text == "Ship 0.3 on Friday")
    #expect(board.item("ship")?.x == 240)
    #expect(board.item("ship")?.y == 60)
    #expect(board.item("ship")?.tint == .pink)

    // Removing a note takes the arrow joined to it as well.
    let removed = try await call(
      services, "board.remove", BoardRemoveInput(doc: "Launch plan", ids: ["draft"]))
    #expect(removed.note.contains("Removed 2 items"))
    board = try services.office.loadBoard(path: path)
    #expect(board.items.map(\.id).sorted() == ["i2", "now", "ship"])
  }

  @Test("Bad board input is refused and leaves the board as it was")
  func refusals() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    _ = try await call(
      services, "docs.create", OfficeCreateInput(title: "Retro", kind: "board"))
    _ = try await call(
      services, "docs.create", OfficeCreateInput(title: "Budget", kind: "spreadsheet"))
    let path = "Documents/Retro.ottoboard"

    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.add",
        BoardItemsInput(
          doc: "Retro",
          items: [
            BoardItemInput(kind: "note", text: "Kept"),
            BoardItemInput(kind: "arrow", from: "nowhere", to: "i1"),
          ]))
    }
    #expect(try services.office.loadBoard(path: path).items.isEmpty)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.add",
        BoardItemsInput(doc: "Retro", items: [BoardItemInput(kind: "hologram")]))
    }
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.add",
        BoardItemsInput(doc: "Budget", items: [BoardItemInput(kind: "note")]))
    }
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.update",
        BoardItemsInput(doc: "Retro", items: [BoardItemInput(id: "i9", text: "x")]))
    }
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.remove", BoardRemoveInput(doc: "Retro", ids: ["i9"]))
    }
  }

  @Test("Items without a place line up beside what is there; an id in use gets a fresh one")
  func placement() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    _ = try await call(services, "docs.create", OfficeCreateInput(title: "Ideas", kind: "board"))
    _ = try await call(
      services, "board.add",
      BoardItemsInput(
        doc: "Ideas", items: [BoardItemInput(id: "a", kind: "note", text: "One", x: 0, y: 0)]))
    _ = try await call(
      services, "board.add",
      BoardItemsInput(
        doc: "Ideas",
        items: [
          BoardItemInput(id: "a", kind: "note", text: "Two"),
          BoardItemInput(kind: "note", text: "Three"),
        ]))
    let board = try services.office.loadBoard(path: "Documents/Ideas.ottoboard")
    #expect(Set(board.items.map(\.id)).count == 3)
    let two = try #require(board.items.first { $0.text == "Two" })
    let three = try #require(board.items.first { $0.text == "Three" })
    #expect(two.id != "a")
    #expect(two.x == 240)
    #expect(three.x == 240)
    #expect(three.y == two.y + 140)
  }

  @Test("The board model: frames hold what sits in them, arrows meet at edges, files round-trip")
  func model() throws {
    var board = Whiteboard()
    board.items = [
      BoardItem(id: "f", kind: .frame, text: "Lane", x: 0, y: 0, w: 400, h: 300),
      BoardItem(id: "a", kind: .note, text: "A", x: 20, y: 60),
      BoardItem(id: "b", kind: .note, text: "B", x: 600, y: 60),
      BoardItem(id: "ab", kind: .arrow, from: "a", to: "b"),
    ]
    #expect(board.frame(containing: board.item("a")!)?.id == "f")
    #expect(board.frame(containing: board.item("b")!) == nil)
    let ends = try #require(board.arrowEnds(board.item("ab")!))
    // From the right edge of A to the left edge of B, a little clear of each.
    #expect(ends.start.x == 206)
    #expect(ends.end.x == 594)
    #expect(ends.start.y == 120)
    #expect(board.items(in: CGRect(x: 550, y: 0, width: 300, height: 300)).map(\.id) == ["b", "ab"])
    #expect(board.issueID() == "i1")
    #expect(board.bounds == CGRect(x: 0, y: 0, width: 780, height: 300))

    let data = try JSONEncoder().encode(board)
    #expect(try JSONDecoder().decode(Whiteboard.self, from: data) == board)
    // A file written by hand, or by a later version, with fields missing still opens.
    let sparse = #"{"items":[{"id":"x","kind":"note"}]}"#
    let opened = try JSONDecoder().decode(Whiteboard.self, from: Data(sparse.utf8))
    #expect(opened.items[0].w == 180)

    board.remove(["b"])
    #expect(board.items.map(\.id) == ["f", "a"])
  }

  @Test("Agents mark where work stands, and a board can be kept fresh by an automation")
  func statusAndFresh() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    _ = try await call(services, "docs.create", OfficeCreateInput(title: "Sprint", kind: "board"))
    let path = "Documents/Sprint.ottoboard"
    _ = try await call(
      services, "board.add",
      BoardItemsInput(
        doc: "Sprint",
        items: [BoardItemInput(id: "fix", kind: "note", text: "Fix login", status: "in progress")]))
    #expect(try services.office.loadBoard(path: path).item("fix")?.status == .doing)
    _ = try await call(
      services, "board.update",
      BoardItemsInput(doc: "Sprint", items: [BoardItemInput(id: "fix", status: "done")]))
    var board = try services.office.loadBoard(path: path)
    #expect(board.item("fix")?.status == .done)
    #expect(board.outline.contains("\"Fix login\" status done"))
    _ = try await call(
      services, "board.update",
      BoardItemsInput(doc: "Sprint", items: [BoardItemInput(id: "fix", status: "none")]))
    #expect(try services.office.loadBoard(path: path).item("fix")?.status == nil)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.update",
        BoardItemsInput(doc: "Sprint", items: [BoardItemInput(id: "fix", status: "purple")]))
    }

    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "board.keep_fresh",
        BoardFreshInput(doc: "Sprint", task: "Open GitHub issues by label", cron: "every day"))
    }
    let fresh = try await call(
      services, "board.keep_fresh",
      BoardFreshInput(doc: "Sprint", task: "Open GitHub issues by label", cron: "0 8 * * *"))
    #expect(fresh.applied)
    board = try services.office.loadBoard(path: path)
    let routine = try #require(services.boardAutomation(path: path))
    #expect(board.automationID == routine.id)
    #expect(routine.enabled)
    #expect(routine.instruction.hasPrefix("Open GitHub issues by label"))
    #expect(routine.instruction.contains("whiteboard \"Sprint\""))
    // The run must be able to write to the board.
    #expect(routine.permissionMode == "workspaceWrite")
    // Asking again re-schedules the same automation rather than adding a second.
    _ = try await call(
      services, "board.keep_fresh",
      BoardFreshInput(doc: "Sprint", task: "Open PRs", cron: "30 7 * * 1-5"))
    #expect(services.routines.routines.count == 1)
    #expect(services.boardAutomation(path: path)?.instruction.hasPrefix("Open PRs") == true)

    try services.stopKeepingBoardFresh(path: path)
    #expect(services.routines.routines.isEmpty)
    #expect(try services.office.loadBoard(path: path).automationID == nil)
    #expect(try services.office.loadBoard(path: path).items.count == 1)
  }

  @Test("Every template gives a board whose arrows join things that are there")
  func templates() {
    for template in BoardTemplate.allCases {
      let board = template.board
      #expect(!board.items.isEmpty)
      #expect(Set(board.items.map(\.id)).count == board.items.count)
      for arrow in board.items where arrow.kind == .arrow {
        #expect(board.arrowEnds(arrow) != nil)
      }
      // Notes sit inside a frame wherever the template has frames.
      if board.items.contains(where: { $0.kind == .frame }) {
        for note in board.items where note.kind == .note {
          #expect(board.frame(containing: note) != nil)
        }
      }
    }
  }

  @Test("Home can tell which board note an agent's work came from")
  func taskOrigin() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let office = OfficeStore(workspacePath: root.path)
    let file = try office.create(.whiteboard, title: "Launch plan")
    let agent = UUID()
    var board = Whiteboard()
    var note = BoardItem(id: "i1", kind: .note, text: "Reply to issue #47\nMax · Fri")
    note.task = BoardItem.Task(agentID: agent, assignee: "Coder")
    note.status = .doing
    board.items = [note, BoardItem(id: "i2", kind: .note, text: "Not handed to anyone")]
    try office.saveBoard(board, path: file.path)

    let origin = try #require(office.boardTaskOrigin(agentID: agent))
    #expect(origin.path == "Documents/Launch plan.ottoboard")
    #expect(origin.itemID == "i1")
    #expect(origin.sentence == "From your board “Launch plan”: Reply to issue #47.")
    #expect(office.boardTaskOrigin(agentID: UUID()) == nil)

    // Once the note is done the agent's later questions are no longer about it, but a
    // "finished" line still is.
    board.items[0].status = .done
    try office.saveBoard(board, path: file.path)
    #expect(office.boardTaskOrigin(agentID: agent) == nil)
    #expect(office.boardTaskOrigin(agentID: agent, includingFinished: true)?.itemID == "i1")

    let action = try JSONDecoder().decode(
      BriefAction.self, from: JSONEncoder().encode(BriefAction.openDocument(file.path)))
    #expect(action == .openDocument("Documents/Launch plan.ottoboard"))
  }

  @Test("A question from an agent working on a board note says so on Home and links back")
  func homeLineNamesTheBoard() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    let agent = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    _ = try await call(
      services, "docs.create", OfficeCreateInput(title: "Launch plan", kind: "whiteboard"))
    _ = try await call(
      services, "board.add",
      BoardItemsInput(
        doc: "Launch plan",
        items: [BoardItemInput(id: "reply", kind: "note", text: "Reply to issue #47")]))
    let path = "Documents/Launch plan.ottoboard"

    // An agent with a question that has nothing to do with a board reads as before.
    services.queueAttention(
      nodeID: agent, canvasID: canvas.activeCanvas.id, state: .waitingUser,
      reason: "Which reply do you want?")
    var line = try #require(services.derivedBriefItems().first { $0.id == "attention:\(agent)" })
    #expect(line.reason == "Which reply do you want?")
    #expect(line.secondaryAction == nil)

    // What the board does when the person picks "Give this to…".
    var board = try services.office.loadBoard(path: path)
    board.items[0].task = BoardItem.Task(agentID: agent, assignee: "Coder")
    board.items[0].status = .doing
    try services.office.saveBoard(board, path: path)
    line = try #require(services.derivedBriefItems().first { $0.id == "attention:\(agent)" })
    #expect(
      line.reason == "From your board “Launch plan”: Reply to issue #47. Which reply do you want?")
    #expect(line.action == .openAgent(agent))
    #expect(line.secondaryAction == .openDocument(path))

    // The agent marks the note done, as its brief tells it to; later questions are its own.
    _ = try await call(
      services, "board.update",
      BoardItemsInput(doc: "Launch plan", items: [BoardItemInput(id: "reply", status: "done")]))
    let after = try services.office.loadBoard(path: path)
    #expect(after.item("reply")?.task?.assignee == "Coder")
    line = try #require(services.derivedBriefItems().first { $0.id == "attention:\(agent)" })
    #expect(line.reason == "Which reply do you want?")
    #expect(line.secondaryAction == nil)
  }

  @Test("A whiteboard is a .ottoboard file that Documents lists")
  func kind() {
    #expect(OfficeKind.whiteboard.fileExtension == "ottoboard")
    #expect(OfficeKind(fileExtension: "ottoboard") == .whiteboard)
    #expect(OfficeKind(loose: "Board") == .whiteboard)
    #expect(OfficeKind(loose: "sheet") == .spreadsheet)
  }
}

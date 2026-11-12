import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools

// Agent tools for Otto whiteboards. Agents place and move things directly, like on a sheet;
// what they touched glows on the board so the person can see what changed, and the open board
// keeps the earlier state in its undo history.

public struct BoardItemInput: Codable, Sendable {
  public var id: String?
  public var kind: String?
  public var text: String?
  public var x: Double?
  public var y: Double?
  public var w: Double?
  public var h: Double?
  public var color: String?
  public var shape: String?
  public var from: String?
  public var to: String?
  public var status: String?
  public init(
    id: String? = nil, kind: String? = nil, text: String? = nil, x: Double? = nil,
    y: Double? = nil, w: Double? = nil, h: Double? = nil, color: String? = nil,
    shape: String? = nil, from: String? = nil, to: String? = nil, status: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.x = x
    self.y = y
    self.w = w
    self.h = h
    self.color = color
    self.shape = shape
    self.from = from
    self.to = to
    self.status = status
  }
}

public struct BoardFreshInput: Codable, Sendable {
  public var doc: String
  public var task: String
  public var cron: String
  public var agent: String?
  public init(doc: String, task: String, cron: String, agent: String? = nil) {
    self.doc = doc
    self.task = task
    self.cron = cron
    self.agent = agent
  }
}

public struct BoardItemsInput: Codable, Sendable {
  public var doc: String
  public var items: [BoardItemInput]
  public init(doc: String, items: [BoardItemInput]) {
    self.doc = doc
    self.items = items
  }
}

public struct BoardRemoveInput: Codable, Sendable {
  public var doc: String
  public var ids: [String]
  public init(doc: String, ids: [String]) {
    self.doc = doc
    self.ids = ids
  }
}

private let boardDocProperty = JSONValue.stringSchema(
  description: "The whiteboard's title or its path from docs.list")

private let boardItemProperties: [String: JSONValue] = [
  "id": .stringSchema(
    description:
      "For board.add: optional id of your own (letters and digits) so arrows in the same call can point at it; otherwise one is issued. For board.update: the item's id from docs.read."
  ),
  "kind": .stringSchema(description: "note, text, shape, frame or arrow"),
  "text": .stringSchema(
    description: "What it says. A frame's text is its title; an arrow's is its label."),
  "x": .numberSchema(description: "Left edge in board points; x grows to the right"),
  "y": .numberSchema(description: "Top edge in board points; y grows downwards"),
  "w": .numberSchema(description: "Width (a note is 180 by default)"),
  "h": .numberSchema(description: "Height (a note is 120 by default)"),
  "color": .stringSchema(description: "yellow, green, blue, pink, orange, purple or grey"),
  "shape": .stringSchema(description: "For kind shape: rectangle, ellipse or diamond"),
  "from": .stringSchema(description: "For an arrow: id of the item it starts at"),
  "to": .stringSchema(description: "For an arrow: id of the item it points to"),
  "status": .stringSchema(
    description:
      "Where a piece of work stands, shown as a small label on the item: todo, doing, done or blocked. Pass none to clear it."
  ),
]

public struct BoardAddTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "board.add",
    description: """
      Puts things on an Otto whiteboard: sticky notes, text, shapes, frames and arrows, up to \
      200 in a call. The user watches them appear. Give each an x,y (top-left, in points; x \
      grows right, y grows down) so the layout reads at a glance: frames as columns or lanes \
      with a short title, notes (180x120) inside them on a grid with 20 points between and 50 \
      below the frame's top edge, one idea per note in a few words. Arrows join two items by \
      id (from, to); give items your own id to join them in the same call. Read the board \
      with docs.read first so new things do not land on top of old ones.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": boardDocProperty,
        "items": .arraySchema(
          of: .objectSchema(properties: boardItemProperties, required: ["kind"])),
      ], required: ["doc", "items"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (BoardItemsInput) async throws -> OfficeOutput
  public init(handler: @escaping @Sendable (BoardItemsInput) async throws -> OfficeOutput) {
    self.handler = handler
  }
  public func call(_ input: BoardItemsInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input)
  }
}

public struct BoardUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "board.update",
    description: """
      Changes things already on an Otto whiteboard: move (x, y), resize (w, h), reword (text), \
      recolour (color) or re-join an arrow (from, to). Each item needs its id from docs.read; \
      only the fields you pass change. Use it to tidy a board, group notes by theme or turn a \
      rough plan into a timeline.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": boardDocProperty,
        "items": .arraySchema(
          of: .objectSchema(properties: boardItemProperties, required: ["id"])),
      ], required: ["doc", "items"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (BoardItemsInput) async throws -> OfficeOutput
  public init(handler: @escaping @Sendable (BoardItemsInput) async throws -> OfficeOutput) {
    self.handler = handler
  }
  public func call(_ input: BoardItemsInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input)
  }
}

public struct BoardRemoveTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "board.remove",
    description:
      "Takes items off an Otto whiteboard by id (from docs.read). Arrows joined to them go too. Only when the user asks, or to replace something you are redrawing.",
    inputSchema: .objectSchema(
      properties: [
        "doc": boardDocProperty,
        "ids": .arraySchema(of: .stringSchema(description: "Item id")),
      ], required: ["doc", "ids"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (BoardRemoveInput) async throws -> OfficeOutput
  public init(handler: @escaping @Sendable (BoardRemoveInput) async throws -> OfficeOutput) {
    self.handler = handler
  }
  public func call(_ input: BoardRemoveInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input)
  }
}

public struct BoardFreshTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "board.keep_fresh",
    description: """
      Keeps an Otto whiteboard up to date by linking an automation to it. Use when the user \
      says things like "keep this current" or "update it every morning". task says in plain \
      words what the board should show and where the facts come from (Otto adds how to write \
      to the board). cron is a 5-field schedule in the user's time zone, e.g. "0 8 * * *" for \
      8am daily. agent is a bot name, "Claude Code" or "Codex" (default Claude Code). Calling \
      it again re-schedules the same automation.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": boardDocProperty,
        "task": .stringSchema(description: "What the board should show, and from where"),
        "cron": .stringSchema(description: "5-field cron schedule"),
        "agent": .stringSchema(description: "Bot name, Claude Code or Codex"),
      ], required: ["doc", "task", "cron"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .consequential)
  private let handler: @Sendable (BoardFreshInput) async throws -> OfficeOutput
  public init(handler: @escaping @Sendable (BoardFreshInput) async throws -> OfficeOutput) {
    self.handler = handler
  }
  public func call(_ input: BoardFreshInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input)
  }
}

extension ApplicationServices {
  /// What an agent is told when the person hands it a note from a board: do the work, then
  /// mark the note so the board shows where things stand.
  public static func boardTaskBrief(boardTitle: String, itemID: String) -> String {
    """
    This task was handed to you from a note (id \(itemID)) on the user's Otto whiteboard \
    "\(boardTitle)". They are tracking it there. Do the work as you normally would. When you \
    finish, call board.update with doc "\(boardTitle)" and the note's id, setting status to \
    done (or blocked if you could not finish, and say why in your reply). If the result is \
    short enough to be useful at a glance, put it beside the note with board.add as one grey \
    note joined by an arrow. Do not move or change anything else on the board.
    """
  }

  /// What the automation that keeps a board fresh is told on every run, after the person's task.
  static func boardFreshInstruction(task: String, boardTitle: String) -> String {
    """
    \(task)

    Put the result on the Otto whiteboard "\(boardTitle)". Read it with docs.read first. \
    Change items that are already there with board.update rather than adding copies, add what \
    is new with board.add, and take away what no longer applies with board.remove. Keep the \
    layout tidy and inside its frames, and use status (todo, doing, done, blocked) where it \
    fits. Never invent facts: if a source is unreachable, leave the board as it is and say \
    which source failed. Reply with one line saying what changed.
    """
  }

  /// The automation keeping a board fresh, if it still exists.
  @MainActor
  public func boardAutomation(path: String) -> Routine? {
    guard let id = (try? office.loadBoard(path: path))?.automationID else { return nil }
    return routines.routine(id: id)
  }

  /// Stops keeping a board fresh and removes its automation.
  @MainActor
  public func stopKeepingBoardFresh(path: String) throws {
    var board = try office.loadBoard(path: path)
    if let id = board.automationID, routines.routine(id: id) != nil { try deleteRoutine(id: id) }
    board.automationID = nil
    try office.saveBoard(board, path: path, touched: [])
  }

  @MainActor
  private func keepBoardFresh(_ input: BoardFreshInput) async throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .whiteboard)
    let task = input.task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !task.isEmpty else {
      throw ToolRegistryError.invalidInput("Say what the board should show")
    }
    let cron = input.cron.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CronExpression(cron) != nil else {
      throw ToolRegistryError.invalidInput("Use a 5-field cron schedule, e.g. 0 8 * * *")
    }
    let target = try homeCardTarget(input.agent)
    var board = try office.loadBoard(path: file.path)
    let instruction = Self.boardFreshInstruction(task: task, boardTitle: file.title)
    var routine =
      board.automationID.flatMap { routines.routine(id: $0) }
      ?? Routine(
        name: "Update \(file.title) board", instruction: instruction,
        trigger: .schedule(cron: cron, intervalSeconds: nil), target: target)
    routine.instruction = instruction
    routine.trigger = .schedule(cron: cron, intervalSeconds: nil)
    routine.target = target
    routine.delivery = .canvas
    routine.enabled = true
    // The run has to write to the board, which a read-only run cannot.
    routine.permissionMode = AgentPermissionMode.workspaceWrite.rawValue
    routine.quietWhenUnchanged = false
    routine.timeZoneIdentifier = TimeZone.current.identifier
    let saved = try await saveRoutine(routine)
    board.automationID = saved.id
    try office.saveBoard(board, path: file.path, touched: [])
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note:
        "\"\(saved.name)\" now runs on \(saved.trigger.summary) and updates the board. The user can change it under Automations."
    )
  }

  func registerBoardTools() async throws {
    try await registry.register(
      BoardFreshTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.keepBoardFresh(input)
      })
    try await registry.register(
      BoardAddTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.addBoardItems(input)
      })
    try await registry.register(
      BoardUpdateTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.updateBoardItems(input)
      })
    try await registry.register(
      BoardRemoveTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.removeBoardItems(input)
      })
  }

  /// The largest side an agent may give an item, and how far from the origin it may sit.
  private static let boardSizeLimit = 6_000.0
  private static let boardReach = 100_000.0

  private static func boardCoordinate(_ value: Double?, name: String) throws -> Double? {
    guard let value else { return nil }
    guard value.isFinite, abs(value) <= boardReach else {
      throw ToolRegistryError.invalidInput("\(name) must be a number within ±\(Int(boardReach))")
    }
    return value
  }

  private static func boardLength(_ value: Double?, minimum: Double, name: String) throws
    -> Double?
  {
    guard let value else { return nil }
    guard value.isFinite, value >= 0 else {
      throw ToolRegistryError.invalidInput("\(name) must be zero or more")
    }
    return min(max(value, minimum), boardSizeLimit)
  }

  @MainActor
  private func addBoardItems(_ input: BoardItemsInput) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .whiteboard)
    guard !input.items.isEmpty, input.items.count <= 200 else {
      throw ToolRegistryError.invalidInput("Add between 1 and 200 items at a time")
    }
    var board = try office.loadBoard(path: file.path)
    guard board.items.count + input.items.count <= Whiteboard.itemLimit else {
      throw ToolRegistryError.invalidInput(
        "This whiteboard is full (\(Whiteboard.itemLimit) items). Remove some first.")
    }
    // Things without a place line up to the right of what is already there.
    var cursor = board.nextFreeOrigin
    var added: [String] = []
    for entry in input.items {
      let named = entry.kind ?? entry.shape ?? "note"
      guard let kind = BoardItem.Kind(loose: named) else {
        throw ToolRegistryError.invalidInput(
          "\"\(named)\" is not a kind. Use note, text, shape, frame or arrow.")
      }
      var id = Self.boardID(entry.id)
      if id == nil || board.item(id!) != nil { id = board.issueID() }
      let shape =
        kind == .shape
        ? (entry.shape.flatMap(BoardItem.Shape.init(loose:))
          ?? BoardItem.Shape(loose: named) ?? .rectangle) : nil
      var item = BoardItem(
        id: id!, kind: kind, text: String((entry.text ?? "").prefix(2_000)),
        tint: entry.color.flatMap(BoardItem.Tint.init(loose:)), shape: shape,
        from: kind == .arrow ? entry.from : nil, to: kind == .arrow ? entry.to : nil)
      item.status = try Self.boardStatus(entry.status) ?? nil
      let minimum = item.minimumSize
      if let w = try Self.boardLength(entry.w, minimum: minimum.width, name: "w") { item.w = w }
      if let h = try Self.boardLength(entry.h, minimum: minimum.height, name: "h") { item.h = h }
      let x = try Self.boardCoordinate(entry.x, name: "x")
      let y = try Self.boardCoordinate(entry.y, name: "y")
      if let x, let y {
        item.x = x
        item.y = y
      } else if kind != .arrow || (item.from == nil && item.to == nil) {
        item.x = x ?? cursor.x
        item.y = y ?? cursor.y
        cursor.y += item.h + 20
      }
      board.items.append(item)
      added.append(item.id)
    }
    // Arrows may point at items added later in the same call, so check once all are in.
    for id in added {
      guard let arrow = board.item(id), arrow.kind == .arrow else { continue }
      for end in [arrow.from, arrow.to].compactMap({ $0 }) where board.item(end) == nil {
        throw ToolRegistryError.invalidInput(
          "Arrow \(arrow.id) points at \"\(end)\", which is not on the board. Use ids from docs.read or ids you gave in this call."
        )
      }
      if arrow.from != nil, arrow.from == arrow.to {
        throw ToolRegistryError.invalidInput("Arrow \(arrow.id) joins an item to itself")
      }
    }
    try office.saveBoard(board, path: file.path, touched: Set(added))
    let lines = added.compactMap(board.item).map(board.line)
    return OfficeOutput(
      file: summary(file), content: lines.joined(separator: "\n"), applied: true,
      note:
        "Added \(added.count) item\(added.count == 1 ? "" : "s"). The user is watching the board; it now has \(board.items.count)."
    )
  }

  @MainActor
  private func updateBoardItems(_ input: BoardItemsInput) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .whiteboard)
    guard !input.items.isEmpty, input.items.count <= 500 else {
      throw ToolRegistryError.invalidInput("Change between 1 and 500 items at a time")
    }
    var board = try office.loadBoard(path: file.path)
    var touched: Set<String> = []
    for entry in input.items {
      guard let id = entry.id, let index = board.index(of: id) else {
        throw ToolRegistryError.invalidInput(
          "There is no item \"\(entry.id ?? "")\" on this board. Read the ids with docs.read.")
      }
      var item = board.items[index]
      if let text = entry.text { item.text = String(text.prefix(2_000)) }
      if let x = try Self.boardCoordinate(entry.x, name: "x") { item.x = x }
      if let y = try Self.boardCoordinate(entry.y, name: "y") { item.y = y }
      let minimum = item.minimumSize
      if let w = try Self.boardLength(entry.w, minimum: minimum.width, name: "w") { item.w = w }
      if let h = try Self.boardLength(entry.h, minimum: minimum.height, name: "h") { item.h = h }
      if let color = entry.color {
        guard let tint = BoardItem.Tint(loose: color) else {
          throw ToolRegistryError.invalidInput(
            "\"\(color)\" is not a colour. Use yellow, green, blue, pink, orange, purple or grey.")
        }
        item.tint = tint
      }
      if item.kind == .shape, let shape = entry.shape.flatMap(BoardItem.Shape.init(loose:)) {
        item.shape = shape
      }
      if let status = try Self.boardStatus(entry.status) { item.status = status }
      if item.kind == .arrow {
        for end in [entry.from, entry.to].compactMap({ $0 }) where board.item(end) == nil {
          throw ToolRegistryError.invalidInput("\"\(end)\" is not on the board")
        }
        if let from = entry.from { item.from = from }
        if let to = entry.to { item.to = to }
        if item.from != nil, item.from == item.to {
          throw ToolRegistryError.invalidInput("Arrow \(item.id) would join an item to itself")
        }
      }
      board.items[index] = item
      touched.insert(id)
    }
    try office.saveBoard(board, path: file.path, touched: touched)
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note: "Changed \(touched.count) item\(touched.count == 1 ? "" : "s").")
  }

  @MainActor
  private func removeBoardItems(_ input: BoardRemoveInput) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .whiteboard)
    var board = try office.loadBoard(path: file.path)
    let ids = Set(input.ids)
    let missing = ids.filter { board.item($0) == nil }.sorted()
    guard !ids.isEmpty, missing.isEmpty else {
      throw ToolRegistryError.invalidInput(
        ids.isEmpty
          ? "Give the ids to remove"
          : "Not on the board: \(missing.joined(separator: ", ")). Read the ids with docs.read.")
    }
    let before = board.items.count
    board.remove(ids)
    try office.saveBoard(board, path: file.path, touched: [])
    let gone = before - board.items.count
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note:
        "Removed \(gone) item\(gone == 1 ? "" : "s"). The user can bring them back with Undo on the board."
    )
  }

  /// The status an agent named: nil when it gave none, `.some(nil)` to clear it.
  private static func boardStatus(_ raw: String?) throws -> BoardItem.Status?? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    if ["none", "clear", "no status"].contains(raw.lowercased()) { return .some(nil) }
    guard let status = BoardItem.Status(loose: raw) else {
      throw ToolRegistryError.invalidInput(
        "\"\(raw)\" is not a status. Use todo, doing, done, blocked or none.")
    }
    return status
  }

  /// An id an agent chose, if it is usable: short, letters, digits, dashes and underscores.
  private static func boardID(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.count <= 32,
      raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    else { return nil }
    return raw
  }
}

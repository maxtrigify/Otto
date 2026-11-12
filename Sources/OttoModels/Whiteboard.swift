import Foundation

/// A whiteboard: sticky notes, text, shapes, frames and arrows on an endless surface. The person
/// and their agents both place things on it; it is saved as a small JSON file (`.ottoboard`).
///
/// Coordinates are board points: `x` grows to the right and `y` grows downwards, and an item's
/// `x`,`y` is its top-left corner.
public struct Whiteboard: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var items: [BoardItem]
  /// The last number handed out for an item id ("i12").
  public var counter: Int
  /// The automation that keeps this board up to date, if the person set one up.
  public var automationID: UUID?

  public init(items: [BoardItem] = []) {
    schemaVersion = 1
    self.items = items
    counter = 0
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    items = try container.decodeIfPresent([BoardItem].self, forKey: .items) ?? []
    counter = try container.decodeIfPresent(Int.self, forKey: .counter) ?? 0
    automationID = try container.decodeIfPresent(UUID.self, forKey: .automationID)
  }

  /// The most items one board holds. Far above what reads well; it only stops a runaway agent.
  public static let itemLimit = 1_500

  public func item(_ id: String) -> BoardItem? { items.first { $0.id == id } }

  public func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }

  /// A fresh short id that agents can quote back ("i7").
  public mutating func issueID() -> String {
    let taken = Set(items.map(\.id))
    repeat { counter += 1 } while taken.contains("i\(counter)")
    return "i\(counter)"
  }

  /// Where an item sits. A connected arrow has no place of its own: it spans its two ends.
  public func rect(of item: BoardItem) -> CGRect {
    guard item.kind == .arrow, let ends = arrowEnds(item) else { return item.rect }
    return CGRect(
      x: min(ends.start.x, ends.end.x), y: min(ends.start.y, ends.end.y),
      width: abs(ends.end.x - ends.start.x), height: abs(ends.end.y - ends.start.y))
  }

  /// The two points an arrow is drawn between: the edges of the items it joins, or its own
  /// stored start and end when it is free-standing. Nil when a joined item has gone.
  public func arrowEnds(_ arrow: BoardItem) -> (start: CGPoint, end: CGPoint)? {
    let stored = (
      start: CGPoint(x: arrow.x, y: arrow.y), end: CGPoint(x: arrow.x + arrow.w, y: arrow.y + arrow.h)
    )
    let source = arrow.from.flatMap(item)
    let target = arrow.to.flatMap(item)
    if arrow.from != nil, source == nil { return nil }
    if arrow.to != nil, target == nil { return nil }
    let startCentre = source.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? stored.start
    let endCentre = target.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? stored.end
    let start = source.map { Self.edgePoint(of: $0.rect.insetBy(dx: -6, dy: -6), toward: endCentre) }
      ?? stored.start
    let end = target.map { Self.edgePoint(of: $0.rect.insetBy(dx: -6, dy: -6), toward: startCentre) }
      ?? stored.end
    return (start, end)
  }

  /// Where the line from a rectangle's centre to `point` leaves the rectangle.
  static func edgePoint(of rect: CGRect, toward point: CGPoint) -> CGPoint {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let dx = point.x - centre.x
    let dy = point.y - centre.y
    guard dx != 0 || dy != 0 else { return centre }
    let scaleX = dx == 0 ? Double.infinity : (rect.width / 2) / abs(dx)
    let scaleY = dy == 0 ? Double.infinity : (rect.height / 2) / abs(dy)
    let scale = min(scaleX, scaleY, 1)
    return CGPoint(x: centre.x + dx * scale, y: centre.y + dy * scale)
  }

  /// The smallest rectangle around everything, or nil for an empty board.
  public var bounds: CGRect? {
    let rects = items.map(rect(of:))
    guard var union = rects.first else { return nil }
    for rect in rects.dropFirst() { union = union.union(rect) }
    return union
  }

  /// Everything that touches a rectangle the person drew, in drawing order.
  public func items(in area: CGRect) -> [BoardItem] {
    items.filter { item in
      let rect = rect(of: item)
      // A hairline arrow has no area, so give it a little.
      return area.intersects(rect.insetBy(dx: -1, dy: -1))
    }
  }

  /// The frame an item sits in: the smallest frame holding its centre.
  public func frame(containing item: BoardItem) -> BoardItem? {
    guard item.kind != .frame, item.kind != .arrow else { return nil }
    let centre = CGPoint(x: item.rect.midX, y: item.rect.midY)
    return items.filter { $0.kind == .frame && $0.rect.contains(centre) }
      .min { $0.w * $0.h < $1.w * $1.h }
  }

  /// Removes items, and any arrow that was joined to one of them.
  public mutating func remove(_ ids: Set<String>) {
    items.removeAll { item in
      ids.contains(item.id)
        || (item.kind == .arrow
          && (item.from.map(ids.contains) == true || item.to.map(ids.contains) == true))
    }
  }

  /// A free spot to the right of everything, for new things nobody gave a place.
  public var nextFreeOrigin: CGPoint {
    guard let bounds else { return CGPoint(x: 80, y: 80) }
    return CGPoint(x: bounds.maxX + 60, y: bounds.minY)
  }

  // MARK: Reading it out

  /// One line an agent can act on: the id, what it is, where it is and what it says.
  public func line(_ item: BoardItem) -> String {
    var parts = ["[\(item.id)]"]
    switch item.kind {
    case .note: parts.append("note" + (item.tint.map { " \($0.rawValue)" } ?? ""))
    case .text: parts.append("text")
    case .shape:
      parts.append((item.shape ?? .rectangle).rawValue + (item.tint.map { " \($0.rawValue)" } ?? ""))
    case .frame: parts.append("frame")
    case .arrow:
      parts.append("arrow \(item.from ?? "(free)") → \(item.to ?? "(free)")")
    }
    if item.kind != .arrow || (item.from == nil && item.to == nil) {
      parts.append(
        "at \(Self.number(item.x)),\(Self.number(item.y)) \(Self.number(item.w))x\(Self.number(item.h))"
      )
    }
    let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      parts.append("\"" + text.replacingOccurrences(of: "\n", with: " / ") + "\"")
    }
    if let status = item.status { parts.append("status \(status.rawValue)") }
    if let task = item.task { parts.append("given to \(task.assignee)") }
    return parts.joined(separator: " ")
  }

  /// The listing for a handful of items, e.g. the ones inside a box the person drew.
  public func listing(_ chosen: [BoardItem]) -> String {
    chosen.map(line).joined(separator: "\n")
  }

  /// The whole board for an agent: frames with what sits in them, then everything else.
  public var outline: String {
    guard !items.isEmpty else { return "(empty whiteboard)" }
    var inside: [String: [BoardItem]] = [:]
    var loose: [BoardItem] = []
    for item in items where item.kind != .frame {
      if let frame = frame(containing: item) {
        inside[frame.id, default: []].append(item)
      } else {
        loose.append(item)
      }
    }
    var lines = [
      "\(items.count) item\(items.count == 1 ? "" : "s"). Positions are x,y of the top-left corner then width x height; x grows right, y grows down."
    ]
    for frame in items where frame.kind == .frame {
      lines.append(line(frame) + (inside[frame.id] == nil ? " (empty)" : " contains:"))
      for item in inside[frame.id] ?? [] { lines.append("  " + line(item)) }
    }
    if !loose.isEmpty {
      if lines.count > 1 { lines.append("Outside any frame:") }
      lines.append(contentsOf: loose.map(line))
    }
    return lines.joined(separator: "\n")
  }

  static func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}

/// One thing on a whiteboard.
public struct BoardItem: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case note, text, shape, frame, arrow

    /// Accepts "sticky", "box", "section", "connector" and the like from agents.
    public init?(loose: String) {
      switch loose.lowercased().trimmingCharacters(in: .whitespaces) {
      case "note", "sticky", "sticky note", "stickynote", "card", "postit", "post-it": self = .note
      case "text", "label", "heading", "title": self = .text
      case "shape", "box", "rectangle", "rect", "ellipse", "circle", "oval", "diamond", "decision":
        self = .shape
      case "frame", "section", "group", "area", "column", "lane": self = .frame
      case "arrow", "connector", "line", "link", "edge": self = .arrow
      default: return nil
      }
    }

    public var defaultSize: CGSize {
      switch self {
      case .note: CGSize(width: 180, height: 120)
      case .text: CGSize(width: 260, height: 40)
      case .shape: CGSize(width: 180, height: 96)
      case .frame: CGSize(width: 460, height: 320)
      case .arrow: CGSize(width: 160, height: 0)
      }
    }
  }

  public enum Shape: String, Codable, Sendable, CaseIterable {
    case rectangle, ellipse, diamond

    public init?(loose: String) {
      switch loose.lowercased().trimmingCharacters(in: .whitespaces) {
      case "rectangle", "rect", "box", "square", "shape": self = .rectangle
      case "ellipse", "circle", "oval": self = .ellipse
      case "diamond", "decision", "rhombus": self = .diamond
      default: return nil
      }
    }
  }

  public enum Tint: String, Codable, Sendable, CaseIterable {
    case yellow, green, blue, pink, orange, purple, grey

    public init?(loose: String) {
      switch loose.lowercased().trimmingCharacters(in: .whitespaces) {
      case "yellow", "gold", "amber": self = .yellow
      case "green", "mint", "lime": self = .green
      case "blue", "cyan", "teal", "sky": self = .blue
      case "pink", "red", "rose", "magenta": self = .pink
      case "orange", "peach", "coral": self = .orange
      case "purple", "violet", "lilac", "indigo": self = .purple
      case "grey", "gray", "white", "neutral", "silver": self = .grey
      default: return nil
      }
    }
  }

  /// Where a piece of work stands. Agents set it as they go; the person can too.
  public enum Status: String, Codable, Sendable, CaseIterable {
    case todo, doing, done, blocked

    public init?(loose: String) {
      switch loose.lowercased().trimmingCharacters(in: .whitespaces) {
      case "todo", "to do", "to-do", "open", "next", "planned", "not started": self = .todo
      case "doing", "in progress", "in-progress", "working", "started", "wip": self = .doing
      case "done", "complete", "completed", "finished", "shipped": self = .done
      case "blocked", "stuck", "waiting", "needs you", "failed": self = .blocked
      default: return nil
      }
    }

    public var label: String {
      switch self {
      case .todo: "To do"
      case .doing: "Doing"
      case .done: "Done"
      case .blocked: "Blocked"
      }
    }
  }

  /// A note the person handed to an agent or bot: who has it and which session is doing it.
  public struct Task: Codable, Equatable, Sendable {
    public var agentID: UUID
    public var assignee: String
    public var assignedAt: Date
    public init(agentID: UUID, assignee: String, assignedAt: Date = .now) {
      self.agentID = agentID
      self.assignee = assignee
      self.assignedAt = assignedAt
    }
  }

  public var id: String
  public var kind: Kind
  public var text: String
  public var x: Double
  public var y: Double
  public var w: Double
  public var h: Double
  public var tint: Tint?
  public var shape: Shape?
  /// For arrows: the ids of the items it joins. A free arrow runs from x,y to x+w,y+h.
  public var from: String?
  public var to: String?
  public var status: Status?
  public var task: Task?

  public init(
    id: String, kind: Kind, text: String = "", x: Double = 0, y: Double = 0, w: Double? = nil,
    h: Double? = nil, tint: Tint? = nil, shape: Shape? = nil, from: String? = nil,
    to: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.x = x
    self.y = y
    self.w = w ?? kind.defaultSize.width
    self.h = h ?? kind.defaultSize.height
    self.tint = tint ?? (kind == .note ? .yellow : nil)
    self.shape = shape ?? (kind == .shape ? .rectangle : nil)
    self.from = from
    self.to = to
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(Kind.self, forKey: .kind)
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
    y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
    w = try container.decodeIfPresent(Double.self, forKey: .w) ?? kind.defaultSize.width
    h = try container.decodeIfPresent(Double.self, forKey: .h) ?? kind.defaultSize.height
    tint = try container.decodeIfPresent(Tint.self, forKey: .tint)
    shape = try container.decodeIfPresent(Shape.self, forKey: .shape)
    from = try container.decodeIfPresent(String.self, forKey: .from)
    to = try container.decodeIfPresent(String.self, forKey: .to)
    status = try container.decodeIfPresent(Status.self, forKey: .status)
    task = try container.decodeIfPresent(Task.self, forKey: .task)
  }

  public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

  /// The smallest an item may be dragged or set to, so it never disappears.
  public var minimumSize: CGSize {
    switch kind {
    case .note: CGSize(width: 90, height: 60)
    case .text: CGSize(width: 60, height: 24)
    case .shape: CGSize(width: 60, height: 40)
    case .frame: CGSize(width: 160, height: 120)
    case .arrow: .zero
    }
  }
}

/// A ready-made layout for a new board, so the first one is never blank.
public enum BoardTemplate: String, CaseIterable, Identifiable, Sendable {
  case timeline, kanban, retro, prosCons, brainstorm

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .timeline: "Timeline"
    case .kanban: "Kanban"
    case .retro: "Retro"
    case .prosCons: "Pros and cons"
    case .brainstorm: "Brainstorm"
    }
  }

  public var symbol: String {
    switch self {
    case .timeline: "calendar.day.timeline.left"
    case .kanban: "rectangle.split.3x1"
    case .retro: "arrow.counterclockwise"
    case .prosCons: "plusminus"
    case .brainstorm: "lightbulb"
    }
  }

  /// The board this template starts from.
  public var board: Whiteboard {
    var board = Whiteboard()
    func columns(_ titles: [(String, BoardItem.Tint)], notes: Int) {
      for (index, column) in titles.enumerated() {
        let x = Double(index) * 460
        board.items.append(
          BoardItem(
            id: board.issueID(), kind: .frame, text: column.0, x: x, y: 0, w: 420, h: 480))
        for slot in 0..<notes {
          board.items.append(
            BoardItem(
              id: board.issueID(), kind: .note, x: x + 20 + Double(slot % 2) * 200,
              y: 50 + Double(slot / 2) * 140, tint: column.1))
        }
      }
    }
    switch self {
    case .timeline:
      columns([("Now", .yellow), ("Next", .blue), ("Later", .purple)], notes: 2)
    case .kanban:
      columns([("To do", .yellow), ("Doing", .blue), ("Done", .green)], notes: 2)
    case .retro:
      columns([("Went well", .green), ("Didn’t go well", .pink), ("Try next", .blue)], notes: 2)
    case .prosCons:
      columns([("Pros", .green), ("Cons", .pink)], notes: 4)
    case .brainstorm:
      let centre = BoardItem(
        id: board.issueID(), kind: .shape, text: "Topic", x: 300, y: 220, w: 200, h: 110,
        tint: .orange, shape: .ellipse)
      board.items.append(centre)
      let spots: [(Double, Double)] = [
        (0, 0), (310, -40), (620, 0), (0, 420), (310, 460), (620, 420),
      ]
      for spot in spots {
        let note = BoardItem(id: board.issueID(), kind: .note, x: spot.0, y: spot.1)
        board.items.append(note)
        board.items.append(
          BoardItem(id: board.issueID(), kind: .arrow, from: centre.id, to: note.id))
      }
    }
    return board
  }
}

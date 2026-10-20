import Foundation

/// A card the user asked for on Home ("add my top meetings to my home page"). Cards belong to
/// the space, not a canvas, and an automation can keep one fresh.
public struct HomeCard: Codable, Sendable, Equatable, Identifiable {
  public enum Style: String, Codable, Sendable, CaseIterable {
    /// Rows of label + detail with an optional trailing value, e.g. meetings.
    case list
    /// Big numbers with the change since the last update, e.g. follower counts.
    case metrics
    /// A short paragraph or a few bullet points.
    case text
    /// A line chart over the rows in order (label = x, value = y).
    case line
    /// A bar chart, one bar per row.
    case bar

    /// Charts draw rows as data points rather than as a list.
    public var isChart: Bool { self == .line || self == .bar }
  }

  /// How much of a row the card takes on a dashboard.
  public enum Width: String, Codable, Sendable, CaseIterable {
    case regular
    case wide
    case full

    /// Columns the card spans when the page has `columns` of them.
    public func span(of columns: Int) -> Int {
      switch self {
      case .regular: 1
      case .wide: min(2, columns)
      case .full: columns
      }
    }
  }

  public var id: UUID
  public var title: String
  public var style: Style
  public var rows: [HomeCardRow]
  public var text: String?
  public var updatedAt: Date
  /// Who last wrote it, e.g. "Calendar automation" or "Claude Code".
  public var updatedBy: String?
  /// The automation that keeps this card fresh, if any.
  public var automationID: UUID?
  /// The dashboard the card sits on; nil puts it on Home.
  public var dashboardID: UUID?
  /// How the numbers were made: the source, query or steps, shown under "How this was made".
  public var source: String?
  /// nil is regular.
  public var width: Width?
  /// Overrides the page's accent for this card's charts and highlights.
  public var color: HomeCardColor?

  public init(
    id: UUID = UUID(), title: String, style: Style, rows: [HomeCardRow] = [],
    text: String? = nil, updatedAt: Date = .now, updatedBy: String? = nil,
    automationID: UUID? = nil, dashboardID: UUID? = nil, source: String? = nil,
    width: Width? = nil, color: HomeCardColor? = nil
  ) {
    self.id = id
    self.title = title
    self.style = style
    self.rows = rows
    self.text = text
    self.updatedAt = updatedAt
    self.updatedBy = updatedBy
    self.automationID = automationID
    self.dashboardID = dashboardID
    self.source = source
    self.width = width
    self.color = color
  }

  public var isEmpty: Bool {
    rows.isEmpty && (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }
}

/// The colours a user or agent can give a dashboard or a card. The app maps each to the theme.
public enum HomeCardColor: String, Codable, Sendable, CaseIterable {
  case green, blue, purple, pink, orange, yellow, red, gray

  /// Reads "Purple", "grey" or "teal"-style near misses; nil when nothing matches.
  public init?(name: String) {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let aliases: [String: HomeCardColor] = [
      "grey": .gray, "violet": .purple, "teal": .green, "mint": .green, "amber": .yellow,
      "gold": .yellow, "cyan": .blue, "magenta": .pink,
    ]
    guard let color = HomeCardColor(rawValue: key) ?? aliases[key] else { return nil }
    self = color
  }
}

/// A named page of cards, e.g. Revenue or Socials, kept apart from Home.
public struct Dashboard: Codable, Sendable, Equatable, Identifiable {
  /// How see-through the cards are over the theme's photo.
  public enum CardStyle: String, Codable, Sendable, CaseIterable {
    case frosted
    case smoked
    case solid

    /// How dark the glass is, 0...1.
    public var smoke: Double {
      switch self {
      case .frosted: 0.22
      case .smoked: 0.5
      case .solid: 0.86
      }
    }
  }

  public var id: UUID
  public var name: String
  public var symbol: String
  public var createdAt: Date
  /// Charts and highlights; nil follows the theme.
  public var accent: HomeCardColor?
  /// nil is smoked.
  public var cardStyle: CardStyle?

  public init(
    id: UUID = UUID(), name: String, symbol: String = "chart.bar.xaxis", createdAt: Date = .now,
    accent: HomeCardColor? = nil, cardStyle: CardStyle? = nil
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.createdAt = createdAt
    self.accent = accent
    self.cardStyle = cardStyle
  }
}

public struct HomeCardRow: Codable, Sendable, Equatable, Identifiable {
  public var label: String
  public var value: String?
  public var detail: String?
  public var url: String?
  /// Earlier numeric values of `value`, oldest first, for the change and the sparkline.
  public var history: [Double]

  public var id: String { label.lowercased() }

  public init(
    label: String, value: String? = nil, detail: String? = nil, url: String? = nil,
    history: [Double] = []
  ) {
    self.label = label
    self.value = value
    self.detail = detail
    self.url = url
    self.history = history
  }

  public static let historyLimit = 30

  /// `value` read as a number: "12,480", "1.2k", "$3.4M" and "85%" all count.
  public var number: Double? { Self.number(from: value) }

  /// Change against the previous reading, when both are numbers.
  public var delta: Double? {
    guard let number, history.count >= 2 else { return nil }
    return number - history[history.count - 2]
  }

  public static func number(from text: String?) -> Double? {
    guard var raw = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty
    else { return nil }
    raw.removeAll { ",$£€% ".contains($0) }
    var scale = 1.0
    if let last = raw.last, let factor = ["k": 1e3, "m": 1e6, "b": 1e9][String(last)] {
      scale = factor
      raw.removeLast()
    }
    return Double(raw).map { $0 * scale }
  }
}

public enum HomeCardUpdateMode: String, Codable, Sendable {
  /// The new rows become the card's rows (history carries over by label).
  case replace
  /// Rows with a matching label are updated, new labels are added, the rest stay.
  case upsert
}

extension HomeCard {
  /// Applies fresh content, carrying each row's history over by label.
  public mutating func apply(
    rows newRows: [HomeCardRow]?, text newText: String?, mode: HomeCardUpdateMode,
    removing labels: [String] = [], by author: String?, at now: Date = .now
  ) {
    let removed = Set(labels.map { $0.lowercased() })
    var merged: [HomeCardRow] = mode == .upsert ? rows : []
    for incoming in newRows ?? [] {
      let previous = rows.first { $0.id == incoming.id }
      var row = incoming
      row.history = previous?.history ?? []
      if let number = row.number {
        row.history.append(number)
        row.history = Array(row.history.suffix(HomeCardRow.historyLimit))
      }
      if let index = merged.firstIndex(where: { $0.id == row.id }) {
        merged[index] = row
      } else {
        merged.append(row)
      }
    }
    if mode == .replace, newRows == nil { merged = rows }
    rows = merged.filter { !removed.contains($0.id) }
    if let newText { text = newText.isEmpty ? nil : newText }
    updatedAt = now
    updatedBy = author
  }

  /// How similar two card titles are, 0...1, ignoring filler words like "my" and "today".
  public static func titleSimilarity(_ lhs: String, _ rhs: String) -> Double {
    let left = keywords(lhs)
    let right = keywords(rhs)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return Double(left.intersection(right).count) / Double(min(left.count, right.count))
  }

  static func keywords(_ text: String) -> Set<String> {
    let filler: Set<String> = [
      "my", "the", "a", "an", "and", "of", "for", "to", "on", "in", "today", "daily", "card",
      "home", "page", "each", "day", "every", "top",
    ]
    return Set(
      text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        .filter { !filler.contains($0) })
  }
}

/// Reads an automation's final answer into card content: a JSON block with `rows`/`text`, or
/// plain text, where bullet lines become rows and anything else becomes the card's text.
public enum HomeCardOutputParser {
  public struct Content: Equatable, Sendable {
    public var rows: [HomeCardRow]?
    public var text: String?
  }

  private struct Wire: Decodable {
    struct Row: Decodable {
      var label: String
      var value: String?
      var detail: String?
      var url: String?

      enum CodingKeys: String, CodingKey { case label, value, detail, url }
      init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        if let number = try? container.decodeIfPresent(Double.self, forKey: .value) {
          value = number.rounded() == number ? String(Int(number)) : String(number)
        } else {
          value = try container.decodeIfPresent(String.self, forKey: .value)
        }
      }
    }
    var rows: [Row]?
    var text: String?
  }

  public static func parse(_ result: String) -> Content? {
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "[SILENT]" else { return nil }
    if let wire = decode(trimmed) {
      let rows = wire.rows?.compactMap { row -> HomeCardRow? in
        let label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return HomeCardRow(
          label: String(label.prefix(120)), value: row.value.map { String($0.prefix(40)) },
          detail: row.detail.map { String($0.prefix(300)) }, url: row.url)
      }
      return Content(rows: rows, text: wire.text.map { String($0.prefix(2_000)) })
    }
    let lines = trimmed.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("• ") }
    if bullets.count >= 2, bullets.count >= lines.count - 1 {
      return Content(rows: bullets.map { row(fromBullet: String($0.dropFirst(2))) }, text: nil)
    }
    return Content(rows: nil, text: String(trimmed.prefix(2_000)))
  }

  /// "Acme call — 11:00" or "LinkedIn: 12,480" become label + value.
  static func row(fromBullet line: String) -> HomeCardRow {
    let text = line.replacingOccurrences(of: "**", with: "")
    for separator in [" — ", " – ", ": ", " - "] {
      if let range = text.range(of: separator) {
        let label = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, !value.isEmpty {
          return HomeCardRow(
            label: label, value: value.count <= 24 ? value : nil,
            detail: value.count > 24 ? value : nil)
        }
      }
    }
    return HomeCardRow(label: text)
  }

  private static func decode(_ text: String) -> Wire? {
    var body = text
    if let fence = text.range(of: "```") {
      let after = text[fence.upperBound...]
      let start = after.firstIndex(of: "\n").map { after.index(after: $0) } ?? after.startIndex
      if let close = after[start...].range(of: "```") {
        body = String(after[start..<close.lowerBound])
      }
    }
    guard let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}") else {
      return nil
    }
    let wire = try? JSONDecoder().decode(Wire.self, from: Data(body[open...close].utf8))
    guard let wire, wire.rows != nil || wire.text != nil else { return nil }
    return wire
  }

  /// Appended to an automation's prompt when it delivers into a card.
  public static let routineInstruction = """
    Your answer updates a card on the user's Home page. Reply with only a fenced JSON block, \
    either rows or a short note:
    ```json
    {"rows":[{"label":"LinkedIn","value":"12480","detail":"followers"},{"label":"Acme pricing call","value":"11:00","detail":"Jo wants a decision on seats"}]}
    ```
    ```json
    {"text":"One or two short sentences."}
    ```
    Keep labels short and give values as plain numbers or short times so Otto can show changes. \
    Always send the full current set of rows.
    """
}

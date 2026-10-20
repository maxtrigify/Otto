import Foundation
import OttoApplicationTools
import OttoModels
import OttoRuntime
import OttoTools

public struct HomeCardRowInput: Codable, Sendable {
  public var label: String
  public var value: String?
  public var detail: String?
  public var url: String?
  public init(label: String, value: String? = nil, detail: String? = nil, url: String? = nil) {
    self.label = label
    self.value = value
    self.detail = detail
    self.url = url
  }

  var row: HomeCardRow? {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return HomeCardRow(
      label: String(trimmed.prefix(120)), value: value.map { String($0.prefix(40)) },
      detail: detail.map { String($0.prefix(300)) },
      url: url.flatMap { $0.hasPrefix("https://") ? $0 : nil })
  }
}

public struct HomeCardAddInput: Codable, Sendable {
  public var title: String
  public var style: String?
  public var rows: [HomeCardRowInput]?
  public var text: String?
  /// Set after the user chose "New card" even though a similar card exists.
  public var newCard: Bool?
  /// Dashboard name; omit for Home.
  public var dashboard: String?
  public var source: String?
  public var width: String?
  public var color: String?
  public init(
    title: String, style: String? = nil, rows: [HomeCardRowInput]? = nil, text: String? = nil,
    newCard: Bool? = nil, dashboard: String? = nil, source: String? = nil, width: String? = nil,
    color: String? = nil
  ) {
    self.title = title
    self.style = style
    self.rows = rows
    self.text = text
    self.newCard = newCard
    self.dashboard = dashboard
    self.source = source
    self.width = width
    self.color = color
  }
}

public struct HomeCardUpdateInput: Codable, Sendable {
  public var card: String
  public var rows: [HomeCardRowInput]?
  public var text: String?
  public var mode: String?
  public var removeRows: [String]?
  public var title: String?
  public var dashboard: String?
  public var source: String?
  public var style: String?
  public var width: String?
  public var color: String?
  /// Another card on the same page whose place this one takes, shifting the rest along.
  public var moveTo: String?
  public init(
    card: String, rows: [HomeCardRowInput]? = nil, text: String? = nil, mode: String? = nil,
    removeRows: [String]? = nil, title: String? = nil, dashboard: String? = nil,
    source: String? = nil, style: String? = nil, width: String? = nil, color: String? = nil,
    moveTo: String? = nil
  ) {
    self.card = card
    self.rows = rows
    self.text = text
    self.mode = mode
    self.removeRows = removeRows
    self.title = title
    self.dashboard = dashboard
    self.source = source
    self.style = style
    self.width = width
    self.color = color
    self.moveTo = moveTo
  }
}

public struct HomeCardRefInput: Codable, Sendable {
  public var card: String
  public var alsoDeleteAutomation: Bool?
  public var dashboard: String?
  public init(card: String, alsoDeleteAutomation: Bool? = nil, dashboard: String? = nil) {
    self.card = card
    self.alsoDeleteAutomation = alsoDeleteAutomation
    self.dashboard = dashboard
  }
}

public struct HomeCardFreshInput: Codable, Sendable {
  public var card: String
  public var task: String
  public var cron: String
  public var agent: String?
  public var dashboard: String?
  public init(
    card: String, task: String, cron: String, agent: String? = nil, dashboard: String? = nil
  ) {
    self.card = card
    self.task = task
    self.cron = cron
    self.agent = agent
    self.dashboard = dashboard
  }
}

public struct HomeCardSummary: Codable, Sendable, Equatable {
  public var id: UUID
  public var title: String
  public var style: String
  public var rows: [String]
  public var text: String?
  public var updatedAt: Date
  public var keptFreshBy: String?
  public var dashboard: String?
  public var source: String?
  public var width: String?
  public var color: String?
}

public struct HomeCardListOutput: Codable, Sendable, Equatable {
  public var cards: [HomeCardSummary]
  public var dashboards: [String]
}

public struct DashboardCreateInput: Codable, Sendable {
  public var name: String
  public init(name: String) { self.name = name }
}

public struct DashboardUpdateInput: Codable, Sendable {
  public var dashboard: String
  public var name: String?
  public var accent: String?
  public var cardStyle: String?
  public init(
    dashboard: String, name: String? = nil, accent: String? = nil, cardStyle: String? = nil
  ) {
    self.dashboard = dashboard
    self.name = name
    self.accent = accent
    self.cardStyle = cardStyle
  }
}

public struct DashboardOutput: Codable, Sendable, Equatable {
  public var dashboards: [String]
  public var created: String?
  public var note: String
}

public struct HomeCardOutput: Codable, Sendable, Equatable {
  public var created: Bool
  public var card: HomeCardSummary?
  public var similarCards: [String]
  public var note: String
}

private let rowSchema = JSONValue.objectSchema(
  properties: [
    "label": .stringSchema(description: "Short name, e.g. LinkedIn or Acme pricing call"),
    "value": .stringSchema(
      description: "Short value shown on the right: a number (12480) or time (11:00)"),
    "detail": .stringSchema(description: "Optional one-line detail under the label"),
    "url": .stringSchema(description: "Optional https link the row opens"),
  ], required: ["label"])

private let rowsSchema = JSONValue.object(["type": .string("array"), "items": rowSchema])
private let dashboardProperty = JSONValue.stringSchema(
  description: "Dashboard name, e.g. Revenue. Omit to use the user's Home page.")
private let widthProperty = JSONValue.stringSchema(
  description:
    "Card size on the page: regular (one column), wide (two columns) or full (the whole row)")
private let colorProperty = JSONValue.stringSchema(
  description:
    "Card colour for charts and highlights: green, blue, purple, pink, orange, yellow, red or gray. Empty string follows the dashboard"
)
private let sourceProperty = JSONValue.stringSchema(
  description:
    "How the numbers were made: the tool, query or steps you used, shown to the user under How this was made"
)

public struct HomeCardListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.list_cards",
    description:
      "Lists the cards on the user's Otto Home page, or on one of their dashboards, plus the names of all dashboards. Call this first whenever the user asks to add, put, show or pin something on Home or a dashboard, so you can tell whether it belongs in an existing card.",
    inputSchema: .objectSchema(properties: ["dashboard": dashboardProperty]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  public struct Input: Codable, Sendable {
    public var dashboard: String?
    public init(dashboard: String? = nil) { self.dashboard = dashboard }
  }
  private let handler: @Sendable (Input) async throws -> HomeCardListOutput
  public init(handler: @escaping @Sendable (Input) async throws -> HomeCardListOutput) {
    self.handler = handler
  }
  public func call(_ input: Input, context: ToolContext) async throws -> HomeCardListOutput {
    try await handler(input)
  }
}

public struct HomeCardAddTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.add_card",
    description: """
      Adds a new card to the user's Otto Home page, or to a dashboard when dashboard is given. \
      Use when the user asks to add, put or show something on Home or a dashboard. Styles: list \
      (rows such as meetings or tasks), metrics (numbers such as follower counts; Otto shows the \
      change since the last update), line (a trend: one row per point, label = date, value = \
      number), bar (one bar per row) or text (a short note). Always say in source how you got \
      the numbers. If a similar card already exists the card is NOT created and the \
      similar titles are returned: ask the user with agent.ask_user, choices "New card" and \
      "Add to <title>", then either call again with newCard true or use home.update_card. Use \
      brief.add instead for one-off news. To keep the card updated on a schedule, follow with \
      home.keep_card_fresh.
      """,
    inputSchema: .objectSchema(
      properties: [
        "title": .stringSchema(description: "Short card title, e.g. Today's meetings"),
        "style": .stringSchema(description: "list, metrics or text"),
        "rows": rowsSchema,
        "text": .stringSchema(description: "Short note for text cards (plain text or bullets)"),
        "newCard": .object([
          "type": .string("boolean"),
          "description": .string("True once the user chose a new card over a similar one"),
        ]),
        "dashboard": dashboardProperty,
        "source": sourceProperty,
        "width": widthProperty,
        "color": colorProperty,
      ], required: ["title"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (HomeCardAddInput, ToolContext) async throws -> HomeCardOutput
  public init(
    handler: @escaping @Sendable (HomeCardAddInput, ToolContext) async throws -> HomeCardOutput
  ) { self.handler = handler }
  public func call(_ input: HomeCardAddInput, context: ToolContext) async throws
    -> HomeCardOutput
  { try await handler(input, context) }
}

public struct HomeCardUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.update_card",
    description: """
      Updates a card on the user's Otto Home page, found by title or id. mode "upsert" (default) \
      updates rows with the same label and adds new ones, e.g. adding Substack to a Socials \
      card; mode "replace" swaps in a fresh full set of rows. removeRows drops rows by label; \
      text replaces the note; title renames the card. width, color and moveTo arrange the \
      page: use them when the user asks to resize, recolour, reorder or even out cards.
      """,
    inputSchema: .objectSchema(
      properties: [
        "card": .stringSchema(description: "Card title or id"),
        "rows": rowsSchema,
        "text": .stringSchema(description: "Replacement note"),
        "mode": .stringSchema(description: "upsert (default) or replace"),
        "removeRows": .object([
          "type": .string("array"), "items": .object(["type": .string("string")]),
        ]),
        "title": .stringSchema(description: "New title"),
        "dashboard": dashboardProperty,
        "source": sourceProperty,
        "style": .stringSchema(description: "Change the style: list, metrics, line, bar or text"),
        "width": widthProperty,
        "color": colorProperty,
        "moveTo": .stringSchema(
          description:
            "Title or id of a card on the same page; this card takes its place and the rest shift along"
        ),
      ], required: ["card"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (HomeCardUpdateInput, ToolContext) async throws -> HomeCardOutput
  public init(
    handler: @escaping @Sendable (HomeCardUpdateInput, ToolContext) async throws -> HomeCardOutput
  ) { self.handler = handler }
  public func call(_ input: HomeCardUpdateInput, context: ToolContext) async throws
    -> HomeCardOutput
  { try await handler(input, context) }
}

public struct HomeCardRemoveTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.remove_card",
    description:
      "Removes a card from the user's Otto Home page. Only when the user asks. If the card has an automation keeping it fresh, ask whether to delete that too and pass alsoDeleteAutomation.",
    inputSchema: .objectSchema(
      properties: [
        "card": .stringSchema(description: "Card title or id"),
        "alsoDeleteAutomation": .object(["type": .string("boolean")]),
        "dashboard": dashboardProperty,
      ], required: ["card"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .consequential)
  private let handler: @Sendable (HomeCardRefInput) async throws -> HomeCardOutput
  public init(handler: @escaping @Sendable (HomeCardRefInput) async throws -> HomeCardOutput) {
    self.handler = handler
  }
  public func call(_ input: HomeCardRefInput, context: ToolContext) async throws
    -> HomeCardOutput
  { try await handler(input) }
}

public struct HomeCardFreshTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "home.keep_card_fresh",
    description: """
      Keeps a Home card up to date by linking an automation to it. Use when the user says things \
      like "every morning" or "update it daily". task says what to fetch, in plain words (Otto \
      adds the reply format). cron is a 5-field schedule in the user's time zone, e.g. \
      "0 8 * * *" for 8am daily or "30 7 * * 1-5" for weekdays at 7:30. agent is a bot name, \
      "Claude Code" or "Codex" (default Claude Code). Runs are read-only. Calling it again \
      re-schedules the same automation.
      """,
    inputSchema: .objectSchema(
      properties: [
        "card": .stringSchema(description: "Card title or id"),
        "task": .stringSchema(description: "What to look up each time"),
        "cron": .stringSchema(description: "5-field cron schedule"),
        "agent": .stringSchema(description: "Bot name, Claude Code or Codex"),
        "dashboard": dashboardProperty,
      ], required: ["card", "task", "cron"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .consequential)
  private let handler: @Sendable (HomeCardFreshInput) async throws -> HomeCardOutput
  public init(handler: @escaping @Sendable (HomeCardFreshInput) async throws -> HomeCardOutput) {
    self.handler = handler
  }
  public func call(_ input: HomeCardFreshInput, context: ToolContext) async throws
    -> HomeCardOutput
  { try await handler(input) }
}

public struct DashboardListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "dashboard.list",
    description: "Lists the user's Otto dashboards (pages of cards such as Revenue or Socials).",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  public struct Input: Codable, Sendable { public init() {} }
  private let handler: @Sendable () async throws -> DashboardOutput
  public init(handler: @escaping @Sendable () async throws -> DashboardOutput) {
    self.handler = handler
  }
  public func call(_ input: Input, context: ToolContext) async throws -> DashboardOutput {
    try await handler()
  }
}

public struct DashboardCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "dashboard.create",
    description: """
      Creates a dashboard: a named page of cards in Otto, e.g. "Revenue" or "Socials". Use when \
      the user asks for a dashboard. Then fill it with home.add_card (pass dashboard), choosing \
      metrics for headline numbers, line for trends and bar or list for breakdowns, and offer \
      home.keep_card_fresh so it stays live. Returns the existing one if the name is taken.
      """,
    inputSchema: .objectSchema(
      properties: ["name": .stringSchema(description: "Short dashboard name")],
      required: ["name"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (DashboardCreateInput) async throws -> DashboardOutput
  public init(handler: @escaping @Sendable (DashboardCreateInput) async throws -> DashboardOutput) {
    self.handler = handler
  }
  public func call(_ input: DashboardCreateInput, context: ToolContext) async throws
    -> DashboardOutput
  { try await handler(input) }
}

public struct DashboardUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "dashboard.update",
    description: """
      Renames an Otto dashboard or changes its look: accent (the colour of its charts and \
      highlights: green, blue, purple, pink, orange, yellow, red or gray; empty string follows \
      the theme) and cardStyle (frosted, smoked or solid, from see-through to opaque). Size, \
      colour or move single cards with home.update_card.
      """,
    inputSchema: .objectSchema(
      properties: [
        "dashboard": .stringSchema(description: "Dashboard name or id"),
        "name": .stringSchema(description: "New name"),
        "accent": .stringSchema(description: "Colour name, or empty to follow the theme"),
        "cardStyle": .stringSchema(description: "frosted, smoked or solid"),
      ], required: ["dashboard"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (DashboardUpdateInput) async throws -> DashboardOutput
  public init(handler: @escaping @Sendable (DashboardUpdateInput) async throws -> DashboardOutput) {
    self.handler = handler
  }
  public func call(_ input: DashboardUpdateInput, context: ToolContext) async throws
    -> DashboardOutput
  { try await handler(input) }
}

extension ApplicationServices {
  func registerHomeCardTools() async throws {
    try await registry.register(
      DashboardListTool { [weak self] in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return await self.dashboardOutput(created: nil, note: "")
      })
    try await registry.register(
      DashboardCreateTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.createDashboard(input)
      })
    try await registry.register(
      DashboardUpdateTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.updateDashboard(input)
      })
    try await registry.register(
      HomeCardListTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.listHomeCards(input)
      })
    try await registry.register(
      HomeCardAddTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.addHomeCard(input, context: context)
      })
    try await registry.register(
      HomeCardUpdateTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.updateHomeCard(input, context: context)
      })
    try await registry.register(
      HomeCardRemoveTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.removeHomeCard(input)
      })
    try await registry.register(
      HomeCardFreshTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.keepHomeCardFresh(input)
      })
  }

  @MainActor
  func homeCardSummary(_ card: HomeCard) -> HomeCardSummary {
    HomeCardSummary(
      id: card.id, title: card.title, style: card.style.rawValue,
      rows: card.rows.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: ": ") },
      text: card.text, updatedAt: card.updatedAt,
      keptFreshBy: card.automationID.flatMap { routines.routine(id: $0) }?.name,
      dashboard: card.dashboardID.flatMap { homeCards.dashboard(id: $0) }?.name,
      source: card.source, width: card.width?.rawValue, color: card.color?.rawValue)
  }

  /// Resolves an optional dashboard name to its id; nil or empty means Home.
  @MainActor
  private func resolveDashboard(_ name: String?) throws -> UUID? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
      name.caseInsensitiveCompare("home") != .orderedSame
    else { return nil }
    guard let dashboard = homeCards.dashboard(named: name) else {
      let names = homeCards.dashboards.map(\.name)
      throw ToolRegistryError.invalidInput(
        names.isEmpty
          ? "There is no dashboard called \"\(name)\". Create it with dashboard.create."
          : "No dashboard matches \"\(name)\". Dashboards: \(names.joined(separator: ", ")). Or create it with dashboard.create."
      )
    }
    return dashboard.id
  }

  @MainActor
  private func pageName(_ dashboardID: UUID?) -> String {
    dashboardID.flatMap { homeCards.dashboard(id: $0) }.map { "the \($0.name) dashboard" }
      ?? "Home"
  }

  @MainActor
  func dashboardOutput(created: String?, note: String) -> DashboardOutput {
    DashboardOutput(dashboards: homeCards.dashboards.map(\.name), created: created, note: note)
  }

  @MainActor
  private func createDashboard(_ input: DashboardCreateInput) throws -> DashboardOutput {
    if let existing = homeCards.dashboard(named: input.name) {
      return dashboardOutput(
        created: nil,
        note: "\"\(existing.name)\" already exists; add cards to it with home.add_card.")
    }
    let dashboard = try homeCards.createDashboard(name: input.name)
    return dashboardOutput(
      created: dashboard.name,
      note:
        "Created. Add cards with home.add_card and dashboard \"\(dashboard.name)\". The user sees it under Dashboards in Otto."
    )
  }

  @MainActor
  private func updateDashboard(_ input: DashboardUpdateInput) throws -> DashboardOutput {
    guard let dashboard = homeCards.dashboard(named: input.dashboard) else {
      throw ToolRegistryError.invalidInput(
        "No dashboard matches \"\(input.dashboard)\". Dashboards: \(homeCards.dashboards.map(\.name).joined(separator: ", "))"
      )
    }
    let accent = try input.accent.map(Self.cardColor)
    let style = try input.cardStyle.map { raw in
      guard let style = Dashboard.CardStyle(rawValue: raw.lowercased()) else {
        throw ToolRegistryError.invalidInput("cardStyle is frosted, smoked or solid.")
      }
      return style
    }
    if let name = input.name, !name.isEmpty, name != dashboard.name {
      try homeCards.renameDashboard(id: dashboard.id, to: name)
    }
    try homeCards.updateDashboard(id: dashboard.id) { next in
      if let accent { next.accent = accent }
      if let style { next.cardStyle = style }
    }
    let saved = homeCards.dashboard(id: dashboard.id) ?? dashboard
    return dashboardOutput(
      created: nil,
      note:
        "Updated \"\(saved.name)\": accent \(saved.accent?.rawValue ?? "theme"), cards \((saved.cardStyle ?? .smoked).rawValue)."
    )
  }

  /// "" clears the colour; an unknown name is an error so the agent can correct it.
  static func cardColor(_ raw: String) throws -> HomeCardColor? {
    if raw.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    guard let color = HomeCardColor(name: raw) else {
      throw ToolRegistryError.invalidInput(
        "Unknown colour \"\(raw)\". Use one of: \(HomeCardColor.allCases.map(\.rawValue).joined(separator: ", "))."
      )
    }
    return color
  }

  static func cardWidth(_ raw: String) throws -> HomeCard.Width {
    guard let width = HomeCard.Width(rawValue: raw.lowercased()) else {
      throw ToolRegistryError.invalidInput("width is regular, wide or full.")
    }
    return width
  }

  @MainActor
  private func listHomeCards(_ input: HomeCardListTool.Input) throws -> HomeCardListOutput {
    let page = try resolveDashboard(input.dashboard)
    return HomeCardListOutput(
      cards: homeCards.cards(on: page).map(homeCardSummary),
      dashboards: homeCards.dashboards.map(\.name))
  }

  @MainActor
  func cardAuthor(_ context: ToolContext) -> String {
    context.sourceNodeID.flatMap { id in
      store.snapshot.canvases.flatMap(\.nodes).first { $0.id == id }?.displayName
    } ?? "An agent"
  }

  @MainActor
  private func resolveCard(_ reference: String, dashboard: String? = nil) throws -> HomeCard {
    let page = try resolveDashboard(dashboard)
    guard let card = homeCards.card(named: reference, on: page) else {
      let titles = homeCards.cards(on: page).map(\.title)
      throw ToolRegistryError.invalidInput(
        titles.isEmpty
          ? "There are no cards on \(pageName(page)) yet. Use home.add_card."
          : "No card on \(pageName(page)) matches \"\(reference)\". Cards: \(titles.joined(separator: ", "))"
      )
    }
    return card
  }

  @MainActor
  private func addHomeCard(_ input: HomeCardAddInput, context: ToolContext) throws
    -> HomeCardOutput
  {
    let rows = input.rows?.compactMap(\.row)
    let style =
      input.style.flatMap { HomeCard.Style(rawValue: $0.lowercased()) }
      ?? (rows?.isEmpty == false
        ? (rows!.allSatisfy { $0.number != nil } ? .metrics : .list) : .text)
    let page = try resolveDashboard(input.dashboard)
    let similar = homeCards.similarCards(to: input.title, on: page)
    if input.newCard != true, !similar.isEmpty {
      return HomeCardOutput(
        created: false, card: nil, similarCards: similar.map(\.title),
        note:
          "Not created: \(pageName(page)) already has a similar card. Ask the user with agent.ask_user, choices \"New card\" and \"Add to \(similar[0].title)\". Then call home.add_card again with newCard true, or home.update_card on the existing card."
      )
    }
    var card = HomeCard(
      title: input.title, style: style, updatedBy: cardAuthor(context), dashboardID: page,
      source: input.source, width: try input.width.map(Self.cardWidth),
      color: try input.color.flatMap(Self.cardColor))
    card.apply(rows: rows, text: input.text, mode: .replace, by: card.updatedBy)
    let saved = try homeCards.add(card)
    return HomeCardOutput(
      created: true, card: homeCardSummary(saved), similarCards: [],
      note:
        "Added to \(pageName(page)). If they want it kept up to date, call home.keep_card_fresh."
    )
  }

  @MainActor
  private func updateHomeCard(_ input: HomeCardUpdateInput, context: ToolContext) throws
    -> HomeCardOutput
  {
    let card = try resolveCard(input.card, dashboard: input.dashboard)
    let mode = input.mode.flatMap { HomeCardUpdateMode(rawValue: $0.lowercased()) } ?? .upsert
    let author = cardAuthor(context)
    let width = try input.width.map(Self.cardWidth)
    let color = try input.color.map(Self.cardColor)
    let anchor = try input.moveTo.map {
      try resolveCard($0, dashboard: input.dashboard ?? card.dashboardID?.uuidString)
    }
    // Layout-only changes leave the content, its author and "Updated" time alone.
    let changesContent =
      input.rows != nil || input.text != nil || !(input.removeRows ?? []).isEmpty
    let saved = try homeCards.update(id: card.id) { card in
      if changesContent {
        card.apply(
          rows: input.rows?.compactMap(\.row), text: input.text, mode: mode,
          removing: input.removeRows ?? [], by: author)
      }
      if let width { card.width = width == .regular ? nil : width }
      if let color { card.color = color }
      if let title = input.title, !title.isEmpty { card.title = title }
      if let source = input.source { card.source = source.isEmpty ? nil : source }
      if let style = input.style.flatMap({ HomeCard.Style(rawValue: $0.lowercased()) }) {
        card.style = style
      }
    }
    if let anchor { try homeCards.move(id: card.id, to: anchor.id) }
    return HomeCardOutput(
      created: false, card: homeCardSummary(saved), similarCards: [], note: "Card updated.")
  }

  @MainActor
  private func removeHomeCard(_ input: HomeCardRefInput) throws -> HomeCardOutput {
    let card = try resolveCard(input.card, dashboard: input.dashboard)
    try homeCards.remove(id: card.id)
    var note = "Removed \"\(card.title)\" from \(pageName(card.dashboardID))."
    if let automationID = card.automationID, routines.routine(id: automationID) != nil {
      if input.alsoDeleteAutomation == true {
        try deleteRoutine(id: automationID)
        note += " Its automation was deleted too."
      } else {
        note += " Its automation still exists; it will stop updating anything until relinked."
      }
    }
    return HomeCardOutput(created: false, card: nil, similarCards: [], note: note)
  }

  @MainActor
  private func keepHomeCardFresh(_ input: HomeCardFreshInput) async throws -> HomeCardOutput {
    let card = try resolveCard(input.card, dashboard: input.dashboard)
    let task = input.task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !task.isEmpty else { throw ToolRegistryError.invalidInput("Say what to look up") }
    let cron = input.cron.trimmingCharacters(in: .whitespacesAndNewlines)
    guard CronExpression(cron) != nil else {
      throw ToolRegistryError.invalidInput("Use a 5-field cron schedule, e.g. 0 8 * * *")
    }
    let target = try homeCardTarget(input.agent)
    var routine =
      card.automationID.flatMap { routines.routine(id: $0) }
      ?? Routine(
        name: "Update \(card.title)", instruction: task,
        trigger: .schedule(cron: cron, intervalSeconds: nil), target: target)
    routine.instruction = task
    routine.trigger = .schedule(cron: cron, intervalSeconds: nil)
    routine.target = target
    routine.delivery = .homeCard(cardID: card.id)
    routine.enabled = true
    routine.permissionMode = AgentPermissionMode.readOnly.rawValue
    routine.quietWhenUnchanged = false
    routine.timeZoneIdentifier = TimeZone.current.identifier
    let saved = try await saveRoutine(routine)
    let updated = try homeCards.update(id: card.id) { $0.automationID = saved.id }
    return HomeCardOutput(
      created: false, card: homeCardSummary(updated), similarCards: [],
      note:
        "\"\(saved.name)\" now runs on \(saved.trigger.summary) and refreshes the card. The user can change it under Automations."
    )
  }

  @MainActor
  private func homeCardTarget(_ agent: String?) throws -> RoutineTarget {
    let name = agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if name.isEmpty { return .spawnProvider(provider: AgentProvider.claudeCode.rawValue) }
    if let provider = AgentProvider.allCases.first(where: {
      $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
    }) {
      return .spawnProvider(provider: provider.rawValue)
    }
    if let bot = agentProfiles.activeProfiles.first(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      return .spawnProfile(profileID: bot.id)
    }
    throw ToolRegistryError.invalidInput(
      "Unknown agent \"\(name)\". Use a bot name, Claude Code or Codex.")
  }

  /// An automation's answer replaces the content of the card it keeps fresh.
  @MainActor
  func deliverRoutineResultToHomeCard(_ routine: Routine, cardID: UUID, result: String) throws {
    guard homeCards.card(id: cardID) != nil else {
      throw HomeCardsStore.CardError.unknownCard(routine.name)
    }
    guard let content = HomeCardOutputParser.parse(result) else { return }
    try homeCards.update(id: cardID) { card in
      card.apply(
        rows: content.rows, text: content.text ?? (content.rows == nil ? nil : ""),
        mode: .replace, by: routine.name)
      card.automationID = routine.id
    }
  }
}

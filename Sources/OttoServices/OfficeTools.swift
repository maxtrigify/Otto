import Foundation
import OttoApplicationTools
import OttoModels
import OttoTools

// Agent tools for Otto documents, spreadsheets and presentations. Agents change documents
// through suggestions the person accepts; sheets and slides change directly and are
// highlighted so the person can see what moved.

public struct OfficeDocRef: Codable, Sendable {
  public var doc: String
  public init(doc: String) { self.doc = doc }
}

public struct OfficeCreateInput: Codable, Sendable {
  public var title: String
  public var kind: String?
  public var content: String?
  public init(title: String, kind: String? = nil, content: String? = nil) {
    self.title = title
    self.kind = kind
    self.content = content
  }
}

public struct OfficeSuggestInput: Codable, Sendable {
  public var doc: String
  public var find: String
  public var replace: String
  public var note: String?
  public init(doc: String, find: String, replace: String, note: String? = nil) {
    self.doc = doc
    self.find = find
    self.replace = replace
    self.note = note
  }
}

public struct OfficeWriteInput: Codable, Sendable {
  public var doc: String
  public var text: String
  public var mode: String?
  public var note: String?
  public init(doc: String, text: String, mode: String? = nil, note: String? = nil) {
    self.doc = doc
    self.text = text
    self.mode = mode
    self.note = note
  }
}

public struct SheetSetCellsInput: Codable, Sendable {
  public var doc: String
  public var cells: [String: String]
  /// Tab name; nil is the first tab. A new name adds the tab.
  public var tab: String?
  public init(doc: String, cells: [String: String], tab: String? = nil) {
    self.doc = doc
    self.cells = cells
    self.tab = tab
  }
}

public struct SheetTabsInput: Codable, Sendable {
  public var doc: String
  /// add, rename or move.
  public var action: String
  public var tab: String?
  public var name: String?
  /// 1-based position for move or add.
  public var position: Int?
  public init(
    doc: String, action: String, tab: String? = nil, name: String? = nil, position: Int? = nil
  ) {
    self.doc = doc
    self.action = action
    self.tab = tab
    self.name = name
    self.position = position
  }
}

public struct SlideEditInput: Codable, Sendable {
  public var doc: String
  /// 1-based slide number; for add_slide, where to insert (default: at the end).
  public var slide: Int?
  public var title: String?
  public var bullets: [String]?
  public var notes: String?
  public var layout: String?
  /// The slide's HTML, written with the deck components from slides.guide.
  public var html: String?
  public init(
    doc: String, slide: Int? = nil, title: String? = nil, bullets: [String]? = nil,
    notes: String? = nil, layout: String? = nil, html: String? = nil
  ) {
    self.doc = doc
    self.slide = slide
    self.title = title
    self.bullets = bullets
    self.notes = notes
    self.layout = layout
    self.html = html
  }
}

public struct SlidesSetDeckInput: Codable, Sendable {
  public struct Item: Codable, Sendable {
    public var html: String
    public var notes: String?
    public init(html: String, notes: String? = nil) {
      self.html = html
      self.notes = notes
    }
  }
  public var doc: String
  public var slides: [Item]
  public var theme: String?
  public init(doc: String, slides: [Item], theme: String? = nil) {
    self.doc = doc
    self.slides = slides
    self.theme = theme
  }
}

public struct SlidesThemeInput: Codable, Sendable {
  public var doc: String
  public var preset: String?
  public var background: String?
  public var background2: String?
  public var surface: String?
  public var text: String?
  public var muted: String?
  public var accent: String?
  public var accent2: String?
  public var fontDisplay: String?
  public var fontBody: String?
  public var fontURL: String?
  public var logoURL: String?
  public var brandName: String?
  public init(
    doc: String, preset: String? = nil, background: String? = nil, background2: String? = nil,
    surface: String? = nil, text: String? = nil, muted: String? = nil, accent: String? = nil,
    accent2: String? = nil, fontDisplay: String? = nil, fontBody: String? = nil,
    fontURL: String? = nil, logoURL: String? = nil, brandName: String? = nil
  ) {
    self.doc = doc
    self.preset = preset
    self.background = background
    self.background2 = background2
    self.surface = surface
    self.text = text
    self.muted = muted
    self.accent = accent
    self.accent2 = accent2
    self.fontDisplay = fontDisplay
    self.fontBody = fontBody
    self.fontURL = fontURL
    self.logoURL = logoURL
    self.brandName = brandName
  }

  var brand: DeckTokens? {
    let tokens = DeckTokens(
      background: background, background2: background2, surface: surface, text: text,
      muted: muted, accent: accent, accent2: accent2, fontDisplay: fontDisplay,
      fontBody: fontBody, fontURL: fontURL.flatMap { $0.hasPrefix("https://") ? $0 : nil },
      logoURL: logoURL.flatMap {
        $0.hasPrefix("https://") || $0.hasPrefix("data:image/") ? $0 : nil
      },
      brandName: brandName)
    return tokens == DeckTokens() ? nil : tokens
  }
}

public struct OfficeFileSummary: Codable, Sendable, Equatable {
  public var title: String
  public var kind: String
  public var path: String
  public var modifiedAt: Date
}

public struct OfficeListOutput: Codable, Sendable, Equatable {
  public var files: [OfficeFileSummary]
}

public struct OfficeOutput: Codable, Sendable, Equatable {
  public var file: OfficeFileSummary?
  public var content: String?
  public var applied: Bool
  public var note: String
}

private let docProperty = JSONValue.stringSchema(
  description: "The file's title (e.g. Q4 plan) or its path from docs.list")

public struct DocsListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "docs.list",
    description:
      "Lists the user's Otto documents, spreadsheets and presentations (newest first). Use it to find the file the user means.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  public struct Input: Codable, Sendable { public init() {} }
  private let handler: @Sendable () async throws -> OfficeListOutput
  public init(handler: @escaping @Sendable () async throws -> OfficeListOutput) {
    self.handler = handler
  }
  public func call(_ input: Input, context: ToolContext) async throws -> OfficeListOutput {
    try await handler()
  }
}

public struct DocsCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "docs.create",
    description: """
      Creates a document, spreadsheet or presentation in Otto's Documents page and opens nothing \
      else. kind: document (default), spreadsheet or presentation. content: for a document, the \
      first draft in light Markdown (# headings, - bullets, **bold**); for a spreadsheet, CSV \
      (formulas like =SUM(B2:B9) are fine). Fill presentations with slides.add_slide.
      """,
    inputSchema: .objectSchema(
      properties: [
        "title": .stringSchema(description: "File name, e.g. Q4 plan"),
        "kind": .stringSchema(description: "document, spreadsheet or presentation"),
        "content": .stringSchema(description: "Optional first draft (Markdown or CSV)"),
      ], required: ["title"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (OfficeCreateInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (OfficeCreateInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: OfficeCreateInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct DocsReadTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "docs.read",
    description: """
      Reads an Otto document, spreadsheet or presentation. Documents come back as plain text \
      (quote it exactly in docs.suggest_edit), spreadsheets as a cell list with raw input and \
      value, presentations as a numbered slide outline. Pending suggestions are listed too.
      """,
    inputSchema: .objectSchema(properties: ["doc": docProperty], required: ["doc"]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  private let handler: @Sendable (OfficeDocRef, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (OfficeDocRef, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: OfficeDocRef, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct DocsSuggestEditTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "docs.suggest_edit",
    description: """
      Proposes an edit to an Otto document: replace the exact text `find` (copy it from \
      docs.read, a sentence or paragraph is best) with `replace` (light Markdown allowed). The \
      user sees it highlighted with Accept and Reject. Make one call per separate change and \
      keep each focused. Never edit the .docx file on disk directly.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "find": .stringSchema(description: "Exact text currently in the document"),
        "replace": .stringSchema(description: "The new text (empty to delete)"),
        "note": .stringSchema(description: "One short line on why, shown to the user"),
      ], required: ["doc", "find", "replace"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (OfficeSuggestInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (OfficeSuggestInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: OfficeSuggestInput, context: ToolContext) async throws
    -> OfficeOutput
  { try await handler(input, context) }
}

public struct DocsWriteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "docs.write",
    description: """
      Writes a block of text into an Otto document in light Markdown. mode append (default) adds \
      it at the end; mode replace rewrites the whole document. An empty document is written \
      straight away; otherwise it becomes a suggestion the user accepts or rejects. For small \
      changes prefer docs.suggest_edit.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "text": .stringSchema(description: "Markdown text"),
        "mode": .stringSchema(description: "append or replace"),
        "note": .stringSchema(description: "One short line on what this adds"),
      ], required: ["doc", "text"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (OfficeWriteInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (OfficeWriteInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: OfficeWriteInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct SheetTabsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "sheet.tabs",
    description: """
      Arranges the tabs of an Otto spreadsheet. action add (name, optional position) adds an \
      empty tab; rename (tab, name) renames one and updates formulas that point at it; move \
      (tab, position) reorders. Positions start at 1. Fill tabs with sheet.set_cells. Tabs \
      can only be deleted by the user.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "action": .stringSchema(description: "add, rename or move"),
        "tab": .stringSchema(description: "The tab to rename or move"),
        "name": .stringSchema(description: "Name for a new or renamed tab (up to 31 characters)"),
        "position": .object([
          "type": .string("integer"), "description": .string("1-based tab position"),
        ]),
      ], required: ["doc", "action"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SheetTabsInput) async throws -> OfficeOutput
  public init(handler: @escaping @Sendable (SheetTabsInput) async throws -> OfficeOutput) {
    self.handler = handler
  }
  public func call(_ input: SheetTabsInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input)
  }
}

public struct SheetSetCellsTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "sheet.set_cells",
    description: """
      Sets cells in an Otto spreadsheet: cells maps addresses to raw input, e.g. {"A1":"Month", \
      "B2":"1200","B8":"=SUM(B2:B7)"}. An empty string clears a cell. Excel/Google Sheets functions work, including SUM, AVERAGE, \
      COUNT, IF, IFS, IFERROR, SUMIF(S), COUNTIF(S), AVERAGEIF(S), VLOOKUP, XLOOKUP, INDEX, MATCH, \
      ROUND, TEXT, LEFT/RIGHT/MID, TEXTJOIN, DATE, DAYS and more. The user sees changed cells \
      highlighted. A spreadsheet can have several tabs: pass tab to write to one (a new name \
      adds the tab; omit it for the first tab). Formulas read other tabs like Excel: \
      =Sales!B2 or =SUM('Q1 data'!B2:B9).
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "cells": .object([
          "type": .string("object"),
          "additionalProperties": .object(["type": .string("string")]),
        ]),
        "tab": .stringSchema(
          description: "Tab name, e.g. Sales. Omit for the first tab; a new name adds a tab"),
      ], required: ["doc", "cells"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SheetSetCellsInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SheetSetCellsInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SheetSetCellsInput, context: ToolContext) async throws
    -> OfficeOutput
  { try await handler(input, context) }
}

private let slideProperties: [String: JSONValue] = [
  "doc": docProperty,
  "slide": .integerSchema(description: "Slide number, starting at 1"),
  "title": .stringSchema(description: "Slide title"),
  "bullets": .arraySchema(of: .stringSchema(), description: "Short bullet points (3-5 is best)"),
  "notes": .stringSchema(description: "Speaker notes"),
  "layout": .stringSchema(description: "title, bullets or section (only for slides without html)"),
  "html": .stringSchema(
    description: "The slide's HTML using the deck components from slides.guide (preferred)"),
]

public struct SlidesGuideTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.guide",
    description:
      "Returns the design guide for Otto slides: the HTML components for layout, charts, count-up stats, motion and 3D, with examples. Read it before writing or redesigning any slide.",
    inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.agentRead],
    riskLevel: .read)
  public struct Input: Codable, Sendable { public init() {} }
  public init() {}
  public func call(_ input: Input, context: ToolContext) async throws -> OfficeOutput {
    OfficeOutput(file: nil, content: DeckAuthoring.guide, applied: false, note: "")
  }
}

public struct SlidesSetDeckTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.set_deck",
    description: """
      Writes a whole Otto presentation at once: slides is the full list in order, each with \
      html (built with the components in slides.guide) and optional speaker notes. Replaces \
      every slide; the previous version is kept so the user can go back. theme is optional: \
      midnight, aurora, paper, ember, forest or mono.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "slides": .arraySchema(
          of: .objectSchema(
            properties: [
              "html": .stringSchema(description: "Slide HTML"),
              "notes": .stringSchema(description: "Speaker notes"),
            ], required: ["html"])),
        "theme": .stringSchema(description: "midnight, aurora, paper, ember, forest or mono"),
      ], required: ["doc", "slides"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SlidesSetDeckInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SlidesSetDeckInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SlidesSetDeckInput, context: ToolContext) async throws
    -> OfficeOutput
  { try await handler(input, context) }
}

public struct SlidesThemeTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.set_theme",
    description: """
      Sets an Otto presentation's look. preset picks a built-in theme (midnight, aurora, paper, \
      ember, forest, mono); the other fields override it with brand colours (hex), fonts, a \
      Google Fonts stylesheet URL (fontURL), a logo image URL and the brand name. Use it to \
      match a company's website after reading the site.
      """,
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "preset": .stringSchema(description: "midnight, aurora, paper, ember, forest or mono"),
        "background": .stringSchema(description: "Main background colour"),
        "background2": .stringSchema(description: "Second background colour for the glow"),
        "surface": .stringSchema(description: "Card colour, rgba works well"),
        "text": .stringSchema(description: "Text colour"),
        "muted": .stringSchema(description: "Secondary text colour"),
        "accent": .stringSchema(description: "Brand accent colour"),
        "accent2": .stringSchema(description: "Second accent colour"),
        "fontDisplay": .stringSchema(description: "Headline font family"),
        "fontBody": .stringSchema(description: "Body font family"),
        "fontURL": .stringSchema(description: "https stylesheet that loads the fonts"),
        "logoURL": .stringSchema(description: "https URL of the logo"),
        "brandName": .stringSchema(description: "Brand name"),
      ], required: ["doc"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SlidesThemeInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SlidesThemeInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SlidesThemeInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct SlidesAddTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.add_slide",
    description:
      "Adds a slide to an Otto presentation. Prefer html built with the components in slides.guide; title/bullets/layout make a plain slide. slide is where to insert it (default: at the end).",
    inputSchema: .objectSchema(properties: slideProperties, required: ["doc", "title"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SlideEditInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct SlidesUpdateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.update_slide",
    description:
      "Changes one slide of an Otto presentation. Pass html to redesign it (see slides.guide), or notes, title or bullets. Only the fields you pass change; the previous version is kept.",
    inputSchema: .objectSchema(properties: slideProperties, required: ["doc", "slide"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SlideEditInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

public struct SlidesDeleteTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "slides.delete_slide",
    description: "Deletes one slide from an Otto presentation. Only when the user asks.",
    inputSchema: .objectSchema(
      properties: [
        "doc": docProperty,
        "slide": .integerSchema(description: "Slide number, starting at 1"),
      ], required: ["doc", "slide"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .consequential)
  private let handler: @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  public init(
    handler: @escaping @Sendable (SlideEditInput, ToolContext) async throws -> OfficeOutput
  ) { self.handler = handler }
  public func call(_ input: SlideEditInput, context: ToolContext) async throws -> OfficeOutput {
    try await handler(input, context)
  }
}

extension ApplicationServices {
  /// Standing instructions for a helper agent bound to a document or dashboard. They travel
  /// with every turn as hidden context, so the chat only shows what the person typed. Bots keep
  /// their own channel, so they get the instructions as hidden context for that one turn.
  @MainActor
  public func workBindingContext(nodeID: UUID) -> String? {
    guard let key = office.binding(of: nodeID), !key.hasPrefix("card-run:") else { return nil }
    let node = store.snapshot.canvases.flatMap(\.nodes).first { $0.id == nodeID }
    guard node?.agentDefinition?.profileID == nil else { return nil }
    return Self.workInstructions(key: key, office: office, cards: homeCards)
  }

  @MainActor
  public static func workInstructions(key: String, office: OfficeStore, cards: HomeCardsStore)
    -> String?
  {
    if key.hasPrefix("dashboard:") {
      guard let id = UUID(uuidString: String(key.dropFirst(10))),
        let dashboard = cards.dashboard(id: id)
      else { return nil }
      return """
        You are the helper beside the user's Otto dashboard "\(dashboard.name)". They are \
        watching it while you work. Check home.list_cards with dashboard "\(dashboard.name)" \
        first; update a card that fits, otherwise add one with home.add_card (dashboard \
        "\(dashboard.name)"): metrics for headline numbers, line for trends (one row per point), \
        bar or list for breakdowns. Use real numbers from the user's connected tools and never \
        invent them; if a source is unreachable, say which and add a text card explaining how \
        to connect it. Fill in source on every card. Offer home.keep_card_fresh when it would \
        help. Keep replies short.
        """
    }
    guard let file = office.file(path: key) else { return nil }
    let name = "\(file.kind.displayName.lowercased()) \"\(file.title)\""
    let tools =
      switch file.kind {
      case .document:
        "Read it with docs.read. Propose changes with docs.suggest_edit (find = the exact current text; one call per change) or docs.write for new sections; the user accepts or rejects them in the document."
      case .spreadsheet:
        "Read it with docs.read and change cells with sheet.set_cells; formulas are welcome. It can have several tabs (sheet.tabs); formulas read other tabs as Sales!B2."
      case .presentation:
        "Read slides.guide first and design with its components so every slide looks great: varied layouts, big type, charts and count-ups for numbers, motion and backdrops. Read the deck with docs.read; write a whole deck with slides.set_deck, change single slides with slides.update_slide (html), add with slides.add_slide, and set colours, fonts and logo with slides.set_theme (read the brand's website first when asked to match a brand)."
      }
    return """
      You are the helper beside the user's Otto \(name). They are watching it while you work, \
      so make the changes with Otto's tools rather than describing them. \(tools) Never edit \
      the file on disk directly. When the user quotes text, cells or a slide, change that part. \
      Keep replies short: say what you changed.
      """
  }

  func registerOfficeTools() async throws {
    try await registry.register(
      DocsListTool { [weak self] in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return await self.listOffice()
      })
    try await registry.register(
      DocsCreateTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.createOffice(input, context: context)
      })
    try await registry.register(
      DocsReadTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.readOffice(input)
      })
    try await registry.register(
      DocsSuggestEditTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.suggestOffice(input, context: context)
      })
    try await registry.register(
      DocsWriteTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.writeOffice(input, context: context)
      })
    try await registry.register(
      SheetSetCellsTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.setSheetCells(input)
      })
    try await registry.register(
      SheetTabsTool { [weak self] input in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.arrangeSheetTabs(input)
      })
    try await registry.register(SlidesGuideTool())
    try await registry.register(
      SlidesSetDeckTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.setDeck(input, context: context)
      })
    try await registry.register(
      SlidesThemeTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.setDeckTheme(input, context: context)
      })
    try await registry.register(
      SlidesAddTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.editSlides(input, action: .add)
      })
    try await registry.register(
      SlidesUpdateTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.editSlides(input, action: .update)
      })
    try await registry.register(
      SlidesDeleteTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.editSlides(input, action: .delete)
      })
  }

  @MainActor
  private func summary(_ file: OfficeFile) -> OfficeFileSummary {
    OfficeFileSummary(
      title: file.title, kind: file.kind.rawValue, path: file.path, modifiedAt: file.modifiedAt)
  }

  @MainActor
  private func resolveOffice(_ reference: String, kind: OfficeKind? = nil) throws -> OfficeFile {
    if let file = office.file(named: reference, kind: kind) { return file }
    if let other = office.file(named: reference), let kind {
      throw OfficeStore.OfficeError.wrongKind(other.title, kind)
    }
    let titles = office.files.filter { kind == nil || $0.kind == kind }.map(\.title)
    throw ToolRegistryError.invalidInput(
      titles.isEmpty
        ? "No such file. Create one with docs.create."
        : "No file matches \"\(reference)\". Files: \(titles.prefix(20).joined(separator: ", "))")
  }

  @MainActor
  private func listOffice() -> OfficeListOutput {
    office.refresh()
    return OfficeListOutput(files: office.files.map(summary))
  }

  @MainActor
  private func createOffice(_ input: OfficeCreateInput, context: ToolContext) throws
    -> OfficeOutput
  {
    let kind = input.kind.flatMap(OfficeKind.init(loose:)) ?? .document
    let file = try office.create(kind, title: input.title)
    if let content = input.content, !content.isEmpty {
      switch kind {
      case .document: try office.applyNow(.replaceAll(content), path: file.path)
      case .spreadsheet:
        let sheet = SpreadsheetCSV.decode(content)
        try office.saveSheet(sheet, path: file.path, touched: Set(sheet.cells.keys))
      case .presentation: break
      }
    }
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note: "Created \"\(file.title)\". The user finds it under Documents in Otto.")
  }

  @MainActor
  private func readOffice(_ input: OfficeDocRef) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc)
    let content: String
    switch file.kind {
    case .document:
      var text = try office.documentText(path: file.path)
      let pending = office.suggestions(path: file.path)
      if !pending.isEmpty {
        text +=
          "\n\n--- Pending suggestions (not yet accepted) ---\n"
          + pending.map { "• \($0.target.map { "\"\($0)\" → " } ?? "")\"\($0.proposed)\"" }
          .joined(separator: "\n")
      }
      content = text
    case .spreadsheet:
      let book = try office.loadWorkbook(path: file.path)
      let listings = book.tabs.map { tab in
        let evaluator = book.evaluator(for: tab.id)
        let cells = tab.sheet.cells.keys.compactMap(CellAddress.init).sorted {
          ($0.row, $0.column) < ($1.row, $1.column)
        }
        return cells.isEmpty
          ? "(empty sheet)"
          : cells.map { address in
            let raw = tab.sheet.raw(address.a1)
            let value = evaluator.value(at: address.a1).display
            return raw.hasPrefix("=")
              ? "\(address.a1): \(raw) → \(value)" : "\(address.a1): \(raw)"
          }.joined(separator: "\n")
      }
      // One tab reads as before; several get a heading each so the agent can pass `tab`.
      content =
        book.tabs.count == 1
        ? listings[0]
        : zip(book.tabs, listings).map { "## Tab: \($0.name)\n\($1)" }
          .joined(separator: "\n\n")
    case .presentation:
      content = try office.loadDeck(path: file.path).outline
    }
    return OfficeOutput(file: summary(file), content: content, applied: false, note: "")
  }

  @MainActor
  private func suggestOffice(_ input: OfficeSuggestInput, context: ToolContext) throws
    -> OfficeOutput
  {
    let file = try resolveOffice(input.doc, kind: .document)
    guard !input.find.isEmpty else {
      throw ToolRegistryError.invalidInput("Quote the exact text to change in find")
    }
    let text = try office.documentText(path: file.path)
    // Agents sometimes quote with Markdown markers the document doesn't contain.
    let candidates = [
      input.find, input.find.replacingOccurrences(of: "**", with: ""),
      input.find.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: ""),
    ]
    guard let find = candidates.first(where: { !$0.isEmpty && text.contains($0) }) else {
      throw ToolRegistryError.invalidInput(
        "That text is not in the document. Call docs.read and copy it exactly.")
    }
    try office.suggest(
      DocSuggestion(
        path: file.path, change: .replace(find: find, replace: input.replace),
        note: input.note, author: cardAuthor(context)))
    return OfficeOutput(
      file: summary(file), content: nil, applied: false,
      note: "Suggested. The user sees it highlighted with Accept and Reject.")
  }

  @MainActor
  private func writeOffice(_ input: OfficeWriteInput, context: ToolContext) throws
    -> OfficeOutput
  {
    let file = try resolveOffice(input.doc, kind: .document)
    let replacing = input.mode?.lowercased() == "replace"
    let change: DocSuggestion.Change = replacing ? .replaceAll(input.text) : .append(input.text)
    let isEmpty = try office.documentText(path: file.path)
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if isEmpty {
      try office.applyNow(change, path: file.path)
      return OfficeOutput(
        file: summary(file), content: nil, applied: true, note: "Written into the document.")
    }
    try office.suggest(
      DocSuggestion(
        path: file.path, change: change, note: input.note, author: cardAuthor(context)))
    return OfficeOutput(
      file: summary(file), content: nil, applied: false,
      note: "Suggested. The user accepts or rejects it in the document.")
  }

  @MainActor
  private func setSheetCells(_ input: SheetSetCellsInput) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .spreadsheet)
    guard !input.cells.isEmpty, input.cells.count <= 2_000 else {
      throw ToolRegistryError.invalidInput("Set between 1 and 2000 cells at a time")
    }
    var book = try office.loadWorkbook(path: file.path)
    var target = book.tabs[0]
    if let name = input.tab?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      if let found = book.tab(named: name) {
        target = found
      } else {
        guard book.tabs.count < SpreadsheetWorkbook.tabLimit else {
          throw ToolRegistryError.invalidInput("This spreadsheet already has the most tabs allowed")
        }
        do { target = try book.addTab(named: name) } catch {
          throw ToolRegistryError.invalidInput(error.localizedDescription)
        }
      }
    }
    var sheet = target.sheet
    var touched: Set<String> = []
    for (key, raw) in input.cells {
      guard let address = CellAddress(key) else {
        throw ToolRegistryError.invalidInput("\"\(key)\" is not a cell address like B4")
      }
      sheet.set(address.a1, raw)
      touched.insert(address.a1)
    }
    book.setSheet(sheet, for: target.id)
    let tabName = book.tabs[book.index(of: target.id) ?? 0].name
    try office.saveWorkbook(
      book, path: file.path, touched: Set(touched.map { "\(tabName)!\($0)" }))
    let evaluator = book.evaluator(for: target.id)
    let errors = touched.sorted().compactMap { a1 -> String? in
      if case .error(let code) = evaluator.value(at: a1) { return "\(a1) \(code)" }
      return nil
    }
    let place = book.tabs.count > 1 ? " on \(tabName)" : ""
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note: errors.isEmpty
        ? "Updated \(touched.count) cell\(touched.count == 1 ? "" : "s")\(place)."
        : "Updated, but these cells show errors: \(errors.joined(separator: ", "))")
  }

  @MainActor
  private func arrangeSheetTabs(_ input: SheetTabsInput) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .spreadsheet)
    var book = try office.loadWorkbook(path: file.path)
    func existing() throws -> SpreadsheetWorkbook.Tab {
      guard let name = input.tab, let tab = book.tab(named: name) else {
        throw ToolRegistryError.invalidInput(
          "Name an existing tab. Tabs: \(book.tabs.map(\.name).joined(separator: ", "))")
      }
      return tab
    }
    let note: String
    do {
      switch input.action.lowercased() {
      case "add":
        guard book.tabs.count < SpreadsheetWorkbook.tabLimit else {
          throw ToolRegistryError.invalidInput("This spreadsheet already has the most tabs allowed")
        }
        let tab = try book.addTab(named: input.name)
        if let position = input.position { book.moveTab(tab.id, to: position - 1) }
        note = "Added the tab \"\(tab.name)\". Fill it with sheet.set_cells and tab."
      case "rename":
        let tab = try existing()
        guard let name = input.name else {
          throw ToolRegistryError.invalidInput("Give the new name in name")
        }
        try book.renameTab(tab.id, to: name)
        note = "Renamed \"\(tab.name)\" and updated formulas that pointed at it."
      case "move":
        let tab = try existing()
        guard let position = input.position else {
          throw ToolRegistryError.invalidInput("Give the new 1-based position in position")
        }
        book.moveTab(tab.id, to: position - 1)
        note = "Moved \"\(tab.name)\"."
      default:
        throw ToolRegistryError.invalidInput("action is add, rename or move")
      }
    } catch let error as SpreadsheetWorkbook.TabError {
      throw ToolRegistryError.invalidInput(error.localizedDescription)
    }
    try office.saveWorkbook(book, path: file.path, touched: [])
    return OfficeOutput(
      file: summary(file), content: "Tabs: \(book.tabs.map(\.name).joined(separator: ", "))",
      applied: true, note: note)
  }

  enum SlideAction { case add, update, delete }

  @MainActor
  private func editSlides(_ input: SlideEditInput, action: SlideAction) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .presentation)
    var deck = try office.loadDeck(path: file.path)
    let layout = input.layout.flatMap { Slide.Layout(rawValue: $0.lowercased()) }
    var touched: Set<String> = []
    deck.snapshot(by: "An agent")
    switch action {
    case .add:
      let slide = Slide(
        title: input.title ?? "", bullets: input.bullets ?? [], notes: input.notes ?? "",
        layout: layout ?? .bullets, html: input.html)
      let index = min(max(0, (input.slide ?? deck.slides.count + 1) - 1), deck.slides.count)
      deck.slides.insert(slide, at: index)
      touched.insert(slide.id.uuidString)
    case .update, .delete:
      guard let number = input.slide, deck.slides.indices.contains(number - 1) else {
        throw ToolRegistryError.invalidInput(
          "Use a slide number from 1 to \(deck.slides.count)")
      }
      if action == .delete {
        guard deck.slides.count > 1 else {
          throw ToolRegistryError.invalidInput("A presentation keeps at least one slide")
        }
        deck.slides.remove(at: number - 1)
      } else {
        var slide = deck.slides[number - 1]
        if let title = input.title { slide.title = title }
        if let bullets = input.bullets { slide.bullets = bullets }
        if let notes = input.notes { slide.notes = notes }
        if let layout { slide.layout = layout }
        if let html = input.html { slide.html = html.isEmpty ? nil : DeckHTML.sanitize(html) }
        deck.slides[number - 1] = slide
        touched.insert(slide.id.uuidString)
      }
    }
    try office.saveDeck(deck, path: file.path, touched: touched)
    return OfficeOutput(
      file: summary(file), content: deck.outline, applied: true,
      note: "Done. The presentation now has \(deck.slides.count) slides.")
  }

  @MainActor
  private func setDeck(_ input: SlidesSetDeckInput, context: ToolContext) throws -> OfficeOutput {
    let file = try resolveOffice(input.doc, kind: .presentation)
    guard !input.slides.isEmpty, input.slides.count <= 60 else {
      throw ToolRegistryError.invalidInput("Give between 1 and 60 slides")
    }
    var deck = try office.loadDeck(path: file.path)
    deck.snapshot(by: cardAuthor(context))
    deck.slides = input.slides.map {
      Slide(title: "", notes: $0.notes ?? "", html: $0.html)
    }
    if let theme = input.theme.flatMap({ Presentation.Theme(rawValue: $0.lowercased()) }) {
      deck.theme = theme
    }
    try office.saveDeck(deck, path: file.path, touched: Set(deck.slides.map(\.id.uuidString)))
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note:
        "Wrote \(deck.slides.count) slides. The user is watching them appear; the old version is in History."
    )
  }

  @MainActor
  private func setDeckTheme(_ input: SlidesThemeInput, context: ToolContext) throws
    -> OfficeOutput
  {
    let file = try resolveOffice(input.doc, kind: .presentation)
    var deck = try office.loadDeck(path: file.path)
    deck.snapshot(by: cardAuthor(context))
    if let preset = input.preset {
      guard let theme = Presentation.Theme(rawValue: preset.lowercased()) else {
        throw ToolRegistryError.invalidInput(
          "Use one of: \(Presentation.Theme.allCases.map(\.rawValue).joined(separator: ", "))")
      }
      deck.theme = theme
      deck.brand = nil
    }
    if let brand = input.brand { deck.brand = (deck.brand ?? DeckTokens()).merged(with: brand) }
    try office.saveDeck(deck, path: file.path, touched: [])
    return OfficeOutput(
      file: summary(file), content: nil, applied: true,
      note: "Theme updated\(deck.brand?.brandName.map { " for \($0)" } ?? "").")
  }
}

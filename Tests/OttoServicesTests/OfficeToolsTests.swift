import AppKit
import Foundation
import OttoCore
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Documents, sheets and slides")
struct OfficeToolsTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "office-\(UUID())")
  }

  private let caller = ToolContext(
    actorID: "agent", scopes: [.canvasWrite, .agentRead], source: .agent)

  private func call<Output: Decodable & Sendable>(
    _ services: ApplicationServices, _ name: String, _ input: some Encodable & Sendable,
    as: Output.Type = OfficeOutput.self
  ) async throws -> Output {
    try await services.registry.call(
      name: name, input: try JSONValue.encode(input), context: caller
    ).decode(Output.self)
  }

  /// Stands in for the open editor window.
  final class FakeEditor: LiveOfficeDocument {
    let text = NSMutableAttributedString(string: "")
    var plainText: String? { text.string }
    func apply(_ change: DocSuggestion.Change) -> Bool { OfficeStore.apply(change, to: text) }
  }

  @Test("A document is a real .docx; agents draft into it, then suggest edits the user accepts")
  func documentFlow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    let created = try await call(
      services, "docs.create",
      OfficeCreateInput(
        title: "Q4 plan", content: "# Q4 plan\nWe will **grow** revenue.\n- Hire two people"))
    #expect(created.file?.path == "Documents/Q4 plan.docx")
    let url = root.appending(path: "Documents/Q4 plan.docx")
    // A real Word file: a zip that AppKit reads back with its formatting.
    let reread = try NSAttributedString(
      data: Data(contentsOf: url),
      options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
      documentAttributes: nil)
    #expect(reread.string.contains("We will grow revenue."))
    #expect(reread.string.contains("•\tHire two people"))

    let suggestion = try await call(
      services, "docs.suggest_edit",
      OfficeSuggestInput(
        doc: "q4 plan", find: "grow", replace: "double", note: "Bolder goal"))
    #expect(!suggestion.applied)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "docs.suggest_edit",
        OfficeSuggestInput(doc: "Q4 plan", find: "not in here", replace: "x"))
    }
    let pending = services.office.suggestions(path: "Documents/Q4 plan.docx")
    #expect(pending.count == 1)
    #expect(pending.first?.author == "An agent")

    // Writing into a non-empty document also becomes a suggestion.
    let appended = try await call(
      services, "docs.write", OfficeWriteInput(doc: "Q4 plan", text: "## Risks\n- Hiring"))
    #expect(!appended.applied)

    let read = try await call(services, "docs.read", OfficeDocRef(doc: "Q4 plan"))
    #expect(read.content?.contains("Pending suggestions") == true)

    try services.office.accept(pending[0].id)
    #expect(try services.office.documentText(path: "Documents/Q4 plan.docx").contains("double"))
    let remaining = services.office.suggestions(path: "Documents/Q4 plan.docx")
    try services.office.dismiss(remaining[0].id)
    #expect(services.office.suggestions(path: "Documents/Q4 plan.docx").isEmpty)
    #expect(!(try services.office.documentText(path: "Documents/Q4 plan.docx")).contains("Risks"))

    // With the editor open, changes go through it instead of the file.
    let editor = FakeEditor()
    editor.text.append(NSAttributedString(string: "Live text here"))
    services.office.register(editor, path: "Documents/Q4 plan.docx")
    _ = try await call(
      services, "docs.suggest_edit",
      OfficeSuggestInput(doc: "Q4 plan", find: "Live", replace: "Edited"))
    try services.office.accept(services.office.suggestions(path: "Documents/Q4 plan.docx")[0].id)
    #expect(editor.plainText == "Edited text here")
    services.office.unregister(editor, path: "Documents/Q4 plan.docx")
  }

  @Test("Sheets take cells and formulas from agents and mark what changed")
  func sheetFlow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    _ = try await call(
      services, "docs.create",
      OfficeCreateInput(title: "Budget", kind: "sheet", content: "Item,Cost\nRent,1200\nFood,300"))
    let set = try await call(
      services, "sheet.set_cells",
      SheetSetCellsInput(doc: "Budget", cells: ["A4": "Total", "B4": "=SUM(B2:B3)", "C1": "=1/0"]))
    #expect(set.note.contains("C1 #DIV/0!"))
    let read = try await call(services, "docs.read", OfficeDocRef(doc: "Budget"))
    #expect(read.content?.contains("B4: =SUM(B2:B3) → 1500") == true)
    #expect(
      services.office.agentTouched["Documents/Budget.ottosheet"]?.contains("Sheet1!B4") == true)
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "sheet.set_cells", SheetSetCellsInput(doc: "Budget", cells: ["ZZZ0": "x"]))
    }
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "slides.add_slide", SlideEditInput(doc: "Budget", title: "Nope"))
    }
  }

  @Test("Agents write to tabs, read every tab, and add, rename and move tabs")
  func sheetTabsFlow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    _ = try await call(
      services, "docs.create",
      OfficeCreateInput(title: "Plan", kind: "sheet", content: "Item,Cost\nRent,1200"))
    let added = try await call(
      services, "sheet.set_cells",
      SheetSetCellsInput(doc: "Plan", cells: ["A1": "Total", "B1": "=Sheet1!B2*12"], tab: "Year"))
    #expect(added.note.contains("on Year"))
    let read = try await call(services, "docs.read", OfficeDocRef(doc: "Plan"))
    #expect(read.content?.contains("## Tab: Year\nA1: Total\nB1: =Sheet1!B2*12 → 14400") == true)
    #expect(services.office.agentTouched["Documents/Plan.ottosheet"]?.contains("Year!B1") == true)

    _ = try await call(
      services, "sheet.tabs",
      SheetTabsInput(doc: "Plan", action: "rename", tab: "sheet1", name: "Costs"))
    _ = try await call(
      services, "sheet.tabs", SheetTabsInput(doc: "Plan", action: "move", tab: "Year", position: 1))
    let moved = try await call(
      services, "sheet.tabs", SheetTabsInput(doc: "Plan", action: "add", name: "Notes"))
    #expect(moved.content == "Tabs: Year, Costs, Notes")
    let book = try services.office.loadWorkbook(path: "Documents/Plan.ottosheet")
    #expect(book.tabs[0].sheet.raw("B1") == "=Costs!B2*12")
    #expect(book.evaluator(for: book.tabs[0].id).value(at: "B1") == .number(14_400))
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "sheet.tabs", SheetTabsInput(doc: "Plan", action: "add", name: "costs"))
    }
    await #expect(throws: (any Error).self) {
      _ = try await call(
        services, "sheet.tabs", SheetTabsInput(doc: "Plan", action: "delete", tab: "Notes"))
    }
  }

  @Test("A bot helper's brief rides with one turn and stays out of its chat")
  func hiddenHelperBrief() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    // A failed send leaves nothing waiting to leak into a later turn.
    await #expect(throws: (any Error).self) {
      try await services.sendPrompt(agentID: UUID(), prompt: "hi", hiddenContext: "Brief")
    }
    #expect(services.takeNextTurnContext(nodeID: UUID()) == nil)

    // The mock agent reads one line per turn, so record what Otto hands the provider for the
    // turn instead of sending the multiline context envelope through it.
    let handed = HandedContext()
    await services.supervisor.setTurnContextProvider { [weak services] nodeID, _ in
      let context = await services?.takeNextTurnContext(nodeID: nodeID)
      await handed.record(context)
      return nil
    }
    let nodeID = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    _ = try await services.supervisor.spawnDeterministicMock(id: nodeID)
    let deadline = ContinuousClock.now + .seconds(3)
    while (try? await services.supervisor.snapshot(agentID: nodeID))?.state != .idle,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    try await services.sendPrompt(
      agentID: nodeID, prompt: "Make the intro shorter",
      hiddenContext: "You are the helper beside the user's Otto document")
    #expect(await handed.values == ["You are the helper beside the user's Otto document"])
    // Used once: the next turn goes without it.
    #expect(services.takeNextTurnContext(nodeID: nodeID) == nil)
    let transcript = try await services.supervisor.snapshot(agentID: nodeID).transcript
    #expect(transcript.filter { $0.role == .user }.map(\.text) == ["Make the intro shorter"])
    #expect(!transcript.contains { $0.text.contains("You are the helper") })
  }

  @Test("Slides can be added, changed and removed by number")
  func slidesFlow() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }

    _ = try await call(
      services, "docs.create", OfficeCreateInput(title: "Pitch", kind: "slides"))
    _ = try await call(
      services, "slides.add_slide",
      SlideEditInput(doc: "Pitch", title: "Problem", bullets: ["Too many tabs", "No memory"]))
    _ = try await call(
      services, "slides.add_slide",
      SlideEditInput(doc: "Pitch", slide: 2, title: "Agenda", layout: "section"))
    let updated = try await call(
      services, "slides.update_slide",
      SlideEditInput(doc: "Pitch", slide: 3, bullets: ["Too many apps"]))
    #expect(
      updated.content
        == "Theme: midnight\n\nSlide 1 [title]: Pitch\n\nSlide 2 [section]: Agenda\n\nSlide 3 [bullets]: Problem\n- Too many apps"
    )
    _ = try await call(services, "slides.delete_slide", SlideEditInput(doc: "Pitch", slide: 2))
    #expect(try services.office.loadDeck(path: "Documents/Pitch.ottoslides").slides.count == 2)

    let listed = try await call(
      services, "docs.list", DocsListTool.Input(), as: OfficeListOutput.self)
    #expect(listed.files.map(\.title) == ["Pitch"])
  }

  @Test("Renaming carries suggestions; importing CSV makes a sheet")
  func renameAndImport() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let office = OfficeStore(workspacePath: root.path)
    let file = try office.create(.document, title: "Draft: v1?")
    #expect(file.title == "Draft  v1")
    try office.applyNow(.replaceAll("Hello world"), path: file.path)
    try office.suggest(
      DocSuggestion(
        path: file.path, change: .replace(find: "world", replace: "Max"), note: nil,
        author: "Test"))
    let renamed = try office.rename(path: file.path, to: "Letter")
    #expect(renamed == "Documents/Letter.docx")
    #expect(office.suggestions(path: renamed).count == 1)

    let csv = root.appending(path: "people.csv")
    try "Name,Age\nAda,36".write(to: csv, atomically: true, encoding: .utf8)
    let imported = try office.importFile(csv)
    #expect(imported.kind == .spreadsheet)
    #expect(try office.loadSheet(path: imported.path).raw("B2") == "36")
  }

  @Test("A helper bound to a file gets standing instructions and stays out of Chat's list")
  func boundHelperContext() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = CanvasStore()
    let services = ApplicationServices(store: canvas, workspacePath: root.path)
    let file = try services.office.create(.spreadsheet, title: "Budget")
    let helper = try #require(
      canvas.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    #expect(services.workBindingContext(nodeID: helper) == nil)
    services.office.setSession(helper, path: file.path)
    #expect(services.office.boundSessionIDs.contains(helper))
    #expect(services.office.binding(of: helper) == file.path)
    let context = try #require(services.workBindingContext(nodeID: helper))
    #expect(context.contains("spreadsheet \"Budget\""))
    #expect(context.contains("sheet.set_cells"))

    let board = try services.homeCards.createDashboard(name: "Socials")
    services.office.setSession(nil, path: file.path)
    services.office.setSession(helper, path: OfficeStore.dashboardKey(board.id))
    #expect(services.workBindingContext(nodeID: helper)?.contains("dashboard \"Socials\"") == true)
  }

  @Test("Agents write whole decks as HTML, set a brand, and every change can be taken back")
  func designedDecks() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    defer { services.stop() }
    _ = try await call(services, "docs.create", OfficeCreateInput(title: "Deck", kind: "deck"))

    let guide = try await call(services, "slides.guide", SlidesGuideTool.Input())
    #expect(guide.content?.contains("data-type=\"bar|hbar|line|area|donut\"") == true)

    let written = try await call(
      services, "slides.set_deck",
      SlidesSetDeckInput(
        doc: "Deck",
        slides: [
          .init(
            html:
              #"<h1 class="huge" onclick="steal()">Hi</h1><script>alert(1)</script><a href="javascript:x()">x</a>"#,
            notes: "Open warm"),
          .init(html: #"<div class="chart" data-type="bar" data-values='[1,2]'></div>"#),
        ], theme: "aurora"))
    #expect(written.applied)
    var deck = try services.office.loadDeck(path: "Documents/Deck.ottoslides")
    #expect(deck.slides.count == 2)
    #expect(deck.theme == .aurora)
    let first = try #require(deck.slides.first?.html)
    #expect(
      !first.contains("<script") && !first.contains("onclick") && !first.contains("javascript:"))
    #expect(deck.slides[0].notes == "Open warm")
    #expect(deck.history?.count == 1)

    _ = try await call(
      services, "slides.set_theme",
      SlidesThemeInput(
        doc: "Deck", accent: "#635bff", fontDisplay: "Sohne",
        fontURL: "http://insecure.example/font.css", logoURL: "https://stripe.com/logo.svg",
        brandName: "Stripe"))
    deck = try services.office.loadDeck(path: "Documents/Deck.ottoslides")
    #expect(deck.tokens.accent == "#635bff")
    #expect(deck.tokens.fontURL == nil)
    #expect(deck.tokens.brandName == "Stripe")
    #expect(deck.tokens.background == Presentation.Theme.aurora.tokens.background)

    _ = try await call(
      services, "slides.update_slide",
      SlideEditInput(doc: "Deck", slide: 2, html: "<h2>Redesigned</h2>"))
    deck = try services.office.loadDeck(path: "Documents/Deck.ottoslides")
    #expect(deck.slides[1].renderedHTML == "<h2>Redesigned</h2>")
    let before = try #require(deck.history?.last)
    let reverted = deck.revert(to: before.id, by: "You")
    #expect(reverted)
    #expect(deck.slides[1].html?.contains("chart") == true)
    #expect((deck.history?.count ?? 0) <= Presentation.historyLimit)
  }

  @Test("Word export has real headings, lists and bold for Google Docs")
  func wordExport() throws {
    let text = OfficeRichText.attributed(
      markdown:
        "# Q4 plan\nWe will **grow** revenue.\n## Priorities\n- Ship Otto\n- Hire two\n1. First\n### Detail"
    )
    let document = OfficeRichText.docx(text, title: "Q4 plan")
    #expect(
      document.paragraphs.map(\.style) == [
        .heading1, .body, .heading2, .bullet, .bullet, .number, .heading3,
      ])
    #expect(document.paragraphs[3].runs.map(\.text).joined() == "Ship Otto")
    #expect(document.paragraphs[1].runs.contains { $0.text == "grow" && $0.bold })
    let data = DocxWriter.data(document)
    let url = FileManager.default.temporaryDirectory.appending(path: "word-\(UUID()).docx")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    if let output = ProcessInfo.processInfo.environment["OTTO_HOME_SNAPSHOT_DIR"] {
      try data.write(to: URL(fileURLWithPath: "\(output)/word-export.docx"))
    }
    let reread = try NSAttributedString(
      data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
      documentAttributes: nil)
    #expect(reread.string.contains("We will grow revenue."))
    #expect(reread.string.contains("Ship Otto"))
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", url.path, "word/document.xml"]
    let pipe = Pipe()
    unzip.standardOutput = pipe
    try unzip.run()
    unzip.waitUntilExit()
    let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(xml.contains(#"<w:pStyle w:val="Heading1"/>"#))
    #expect(xml.contains(#"<w:numId w:val="1"/>"#))
    #expect(xml.contains(#"<w:numId w:val="2"/>"#))
  }
}

/// What Otto handed the provider as hidden context, turn by turn.
private actor HandedContext {
  var values: [String] = []
  func record(_ value: String?) { if let value { values.append(value) } }
}

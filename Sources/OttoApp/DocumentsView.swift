import AppKit
import OttoModels
import OttoServices
import SwiftUI
import UniformTypeIdentifiers

/// Documents, spreadsheets and presentations, written with agents. Open one and a helper sits
/// beside it: right-click anything to ask about it, or chat more broadly in the side panel.
struct DocumentsView<Conversation: View>: View {
  @ObservedObject var services: ApplicationServices
  @ObservedObject var office: OfficeStore
  let start: AssistantStarter
  @ViewBuilder let conversation: (UUID) -> Conversation
  @Environment(\.ottoPalette) private var palette
  @AppStorage(AssistantTarget.defaultsKey) private var targetRaw = ""
  @AppStorage("otto.documents.open") private var openPath = ""
  @State private var search = ""
  @State private var error: String?
  @State private var renaming: OfficeFile?
  @State private var draftName = ""
  @State private var pendingAsk: OfficeAsk?
  @State private var showsPanel = true
  @StateObject private var editors = DocEditorCache()
  @StateObject private var sheetModel = SheetModel(sheet: Spreadsheet())
  @StateObject private var sheetTabs = SheetTabsModel()
  @State private var status: OttoStatusToast?

  private var target: Binding<AssistantTarget> {
    Binding(
      get: { AssistantTarget(storageValue: targetRaw) ?? .provider(.claudeCode) },
      set: { targetRaw = $0.storageValue })
  }

  private var openFile: OfficeFile? { office.file(path: openPath) }

  private var bots: [(id: UUID, name: String)] {
    services.botRoster().map { (id: $0.profile.id, name: $0.profile.name) }
  }

  var body: some View {
    Group {
      if let file = openFile {
        editor(file)
      } else {
        library
      }
    }
    .foregroundStyle(palette.paper)
    .onAppear { office.refresh() }
    // A closed document may change on disk (accepted suggestions, agent edits), so it reopens
    // from the file rather than from a cached editor.
    .onChange(of: openPath) { previous, _ in editors.forget(previous) }
    .alert(
      "Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    ) {
      TextField("Name", text: $draftName)
      Button("Rename") {
        if let renaming {
          attempt {
            editors.controller(for: renaming.path)?.saveNow()
            let newPath = try office.rename(path: renaming.path, to: draftName)
            editors.forget(renaming.path)
            if openPath == renaming.path { openPath = newPath }
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    }
    .ottoStatusToast($status)
  }

  // MARK: Library

  private var filtered: [OfficeFile] {
    let query = search.trimmingCharacters(in: .whitespaces)
    return office.files.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
  }

  private var library: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Documents").font(.ottoDisplay(26).weight(.semibold))
            Text(
              "Docs, sheets and slides you write with your agents. Saved in this space’s Documents folder."
            )
            .font(.ottoDisplay(13)).foregroundStyle(palette.muted)
          }
          Spacer()
          Button("Import…") { importFiles() }
            .help("Bring in a Word document or a CSV")
          Menu {
            ForEach(OfficeKind.allCases) { kind in
              Button(kind.displayName, systemImage: kind.symbol) { create(kind) }
            }
          } label: {
            Label("New", systemImage: "plus")
              .font(.ottoDisplay(12.5).weight(.semibold))
              .foregroundStyle(palette.ink)
              .padding(.horizontal, 14).padding(.vertical, 6)
              .background(palette.signal, in: RoundedRectangle(cornerRadius: 8))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityIdentifier("documents.new")
        }
        AssistantPromptBar(
          services: services,
          placeholder: "Start with AI: “a one-page project brief for…”, “a budget sheet for…”",
          target: target
        ) { request in
          await startWithAI(request)
        }
        HStack {
          Text("ALL FILES · \(office.files.count)").font(.ottoMicro).tracking(1.6)
            .foregroundStyle(palette.muted)
          Spacer()
          TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
        }
        if filtered.isEmpty {
          emptyState
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            ForEach(filtered) { file in fileCard(file) }
          }
        }
        if let error {
          Text(error).font(.ottoDisplay(12)).foregroundStyle(palette.red)
        }
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 28)
      .frame(maxWidth: 1180, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollIndicators(.hidden)
  }

  private var emptyState: some View {
    HStack(spacing: 14) {
      ForEach(OfficeKind.allCases) { kind in
        Button {
          create(kind)
        } label: {
          VStack(alignment: .leading, spacing: 10) {
            Image(systemName: kind.symbol).font(.system(size: 22)).foregroundStyle(palette.signal)
            Text("New \(kind.displayName.lowercased())").font(.ottoDisplay(14).weight(.semibold))
            Text(Self.blurb(kind)).font(.ottoDisplay(12)).foregroundStyle(palette.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(18)
          .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
          .background(palette.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
          .ottoElevated(cornerRadius: 14)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  static func blurb(_ kind: OfficeKind) -> String {
    switch kind {
    case .document: "Write like in Word. Saves as .docx."
    case .spreadsheet: "Rows, columns and formulas. Exports to Excel."
    case .presentation:
      "Decks built like websites: motion, charts, 3D. Exports to PowerPoint and PDF."
    }
  }

  private func fileCard(_ file: OfficeFile) -> some View {
    let pending = file.kind == .document ? office.suggestions(path: file.path).count : 0
    return Button {
      open(file)
    } label: {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Image(systemName: file.kind.symbol).font(.system(size: 18))
            .foregroundStyle(palette.signal)
          Spacer()
          if pending > 0 {
            Text("\(pending) SUGGESTION\(pending == 1 ? "" : "S")").font(.ottoMicro).tracking(1.2)
              .foregroundStyle(palette.ink)
              .padding(.horizontal, 6).padding(.vertical, 3)
              .background(palette.signal, in: Capsule())
          }
        }
        Text(file.title).font(.ottoDisplay(14).weight(.semibold)).lineLimit(2)
          .multilineTextAlignment(.leading)
        Spacer(minLength: 0)
        Text(
          "\(file.kind.displayName) · \(file.modifiedAt.formatted(.relative(presentation: .named)))"
            .uppercased()
        )
        .font(.ottoMicro).tracking(1.2).foregroundStyle(palette.muted).lineLimit(1)
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
      .background(palette.raised.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
      .ottoElevated(cornerRadius: 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button("Open") { open(file) }
      Button("Rename…") {
        draftName = file.title
        renaming = file
      }
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([office.url(for: file.path)])
      }
      Divider()
      Button("Move to Trash", role: .destructive) {
        attempt { try office.trash(path: file.path) }
        status = OttoStatusToast(
          kind: .info, title: "Moved to Trash", detail: "Put it back from the Finder Trash.")
      }
    }
  }

  // MARK: Editor

  private func editor(_ file: OfficeFile) -> some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        editorHeader(file)
        Divider().overlay(palette.paper.opacity(0.08))
        switch file.kind {
        case .document:
          let editor = editors.editor(for: file.path, office: office) { controller in
            controller.onAsk = handleAsk
            controller.bots = { bots }
          }
          DocEditorView(
            office: office, file: file, controller: editor.controller, initial: editor.initial
          )
          .id(file.path)
        case .spreadsheet:
          SheetEditorView(
            office: office, file: file, ask: handleAsk, bots: bots,
            model: sheetModel, tabs: sheetTabs
          ).id(file.path)
        case .presentation:
          SlidesEditorView(office: office, file: file, ask: handleAsk, bots: bots).id(file.path)
        }
      }
      if showsPanel {
        sidePanel(file).frame(width: 400)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
  }

  private func editorHeader(_ file: OfficeFile) -> some View {
    HStack(spacing: 10) {
      Button {
        openPath = ""
      } label: {
        Label("Documents", systemImage: "chevron.left").font(.ottoDisplay(12))
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.muted)
      .keyboardShortcut("[", modifiers: .command)
      Image(systemName: file.kind.symbol).foregroundStyle(palette.signal)
      Button {
        draftName = file.title
        renaming = file
      } label: {
        Text(file.title).font(.ottoDisplay(15).weight(.semibold)).lineLimit(1)
      }
      .buttonStyle(.plain)
      .help("Rename")
      Spacer()
      Menu {
        exportItems(file)
      } label: {
        Label("Export", systemImage: "square.and.arrow.up")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Button {
        withAnimation(.easeOut(duration: 0.18)) { showsPanel.toggle() }
      } label: {
        Label(showsPanel ? "Hide AI" : "Ask AI", systemImage: "sparkles")
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.signal)
      .keyboardShortcut("j", modifiers: .command)
      .help("Chat with an agent about this file (⌘J)")
    }
    .font(.ottoDisplay(12))
    .padding(.horizontal, 16)
    .frame(height: 46)
  }

  @ViewBuilder private func exportItems(_ file: OfficeFile) -> some View {
    switch file.kind {
    case .document:
      Button("Prepare upload to Google Docs…", systemImage: "arrow.up.forward.app") {
        sendToGoogle(file, type: "docx", app: "Google Docs") { try wordData(file) }
      }
      Divider()
      Button("Word document (.docx)") { export(file, type: "docx") { try wordData(file) } }
      Button("PDF") {
        export(file, type: "pdf") {
          guard let data = editors.controller(for: file.path)?.pdfData() else {
            throw CocoaError(.fileWriteUnknown)
          }
          return data
        }
      }
    case .spreadsheet:
      Button("Prepare upload to Google Sheets…", systemImage: "arrow.up.forward.app") {
        sendToGoogle(file, type: "xlsx", app: "Google Sheets") { try excelData(file)() }
      }
      Divider()
      Button("Excel workbook (.xlsx)") {
        export(file, type: "xlsx") { try excelData(file)() }
      }
      // CSV holds one tab, so a workbook with several offers each tab.
      let book = try? office.loadWorkbook(path: file.path)
      if let book, book.tabs.count > 1 {
        Menu("CSV, one tab") {
          ForEach(book.tabs) { tab in
            Button(tab.name) { exportCSV(file, tab: tab.name) }
          }
        }
      } else {
        Button("CSV") { exportCSV(file, tab: nil) }
      }
    case .presentation:
      Button("Prepare upload to Google Slides…", systemImage: "arrow.up.forward.app") {
        sendToGoogle(file, type: "pptx", app: "Google Slides") {
          { deck in
            await DeckSnapshotter.shared.editablePPTX(deck, title: file.title, forGoogle: true)
          }
        }
      }
      Divider()
      Button("PowerPoint, editable text (.pptx)") {
        exportDeck(file, type: "pptx") { deck in
          await DeckSnapshotter.shared.editablePPTX(deck, title: file.title)
        }
      }
      Button("PowerPoint, exact look (.pptx)") {
        exportDeck(file, type: "pptx") { deck in
          PPTXWriter.data(
            images: await DeckSnapshotter.shared.pngs(deck), notes: deck.slides.map(\.notes),
            title: file.title)
        }
      }
      Button("PDF") {
        exportDeck(file, type: "pdf") { deck in await DeckSnapshotter.shared.pdf(deck) }
      }
      Button("Web page (.html) to share") {
        exportDeck(file, type: "html") { deck in
          Data(DeckRenderer.page(deck, mode: .present, title: file.title).utf8)
        }
      }
    }
  }

  /// A Word file with real headings and lists, which Google Docs converts cleanly.
  private func wordData(_ file: OfficeFile) throws -> Data {
    try editors.controller(for: file.path)?.saveForExport()
    let text = try office.loadDocument(path: file.path)
    return DocxWriter.data(OfficeRichText.docx(text, title: file.title))
  }

  /// Every tab becomes a worksheet. A lone default "Sheet1" takes the file's title, as before.
  private func excelData(_ file: OfficeFile) -> () throws -> Data {
    {
      let book = try sheetTabs.workbookForExport(path: file.path)
      if book.tabs.count == 1, book.tabs[0].name == "Sheet1" {
        return XLSXWriter.data(for: book.tabs[0].sheet, sheetName: file.title)
      }
      return XLSXWriter.data(for: book)
    }
  }

  private func exportCSV(_ file: OfficeFile, tab: String?) {
    export(file, type: "csv") {
      let book = try sheetTabs.workbookForExport(path: file.path)
      let chosen = tab.flatMap(book.tab(named:)) ?? book.tabs[0]
      let evaluator = book.evaluator(for: chosen.id)
      return Data(SpreadsheetCSV.encode(chosen.sheet, evaluator: evaluator).utf8)
    }
  }

  /// Saves the Google-ready file to Downloads, shows it in Finder and opens Google Drive, where
  /// dropping it in converts it to Google Docs, Sheets or Slides.
  private func sendToGoogle(
    _ file: OfficeFile, type: String, app: String, data: @escaping () throws -> Data
  ) {
    sendToGoogle(file, type: type, app: app) {
      { _ in try data() }
    }
  }

  private func sendToGoogle(
    _ file: OfficeFile, type: String, app: String,
    deckData: () -> (Presentation) async throws -> Data
  ) {
    let make = deckData()
    status = OttoStatusToast(kind: .info, title: "Preparing for \(app)…", detail: file.title)
    Task {
      do {
        let deck =
          file.kind == .presentation ? try office.loadDeck(path: file.path) : Presentation()
        let data = try await make(deck)
        guard !data.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let downloads =
          FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
          ?? FileManager.default.temporaryDirectory
        var url = downloads.appending(path: "\(file.title).\(type)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
          url = downloads.appending(path: "\(file.title) \(counter).\(type)")
          counter += 1
        }
        try data.write(to: url, options: .atomic)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        if let drive = URL(string: "https://drive.google.com/drive/my-drive") {
          NSWorkspace.shared.open(drive)
        }
        status = OttoStatusToast(
          kind: .success, title: "Ready for \(app)",
          detail:
            "Saved \(url.lastPathComponent). Upload this new file to Drive and open with \(app). Existing Google files are not updated."
        )
      } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t prepare it", detail: error.localizedDescription)
      }
    }
  }

  /// The helper chat bound to this file: changing who helps starts a fresh chat.
  private func helperTarget(_ file: OfficeFile) -> Binding<AssistantTarget> {
    Binding(
      get: { target.wrappedValue },
      set: { next in
        if next != target.wrappedValue { office.setSession(nil, path: file.path) }
        target.wrappedValue = next
      })
  }

  private func sidePanel(_ file: OfficeFile) -> some View {
    WorkAssistantPanel(
      services: services, target: helperTarget(file),
      sessionID: office.session(path: file.path),
      actions: AssistantPanelActions(
        newChat: {
          office.setSession(nil, path: file.path)
          pendingAsk = nil
        },
        close: { withAnimation(.easeOut(duration: 0.18)) { showsPanel = false } })
    ) {
      if file.kind == .document {
        DocSuggestionsList(office: office, path: file.path)
      }
      if pendingAsk != nil, office.session(path: file.path) != nil {
        askBox(file)
        Divider().overlay(palette.paper.opacity(0.08))
      }
    } empty: {
      VStack(alignment: .leading, spacing: 0) {
        askBox(file)
        AssistantIdeas(title: "Ideas", ideas: Self.ideas(file.kind)) { idea in
          Task { await send(idea, quote: nil, bot: nil, file: file) }
        }
      }
    } conversation: { nodeID in
      conversation(nodeID)
    }
  }

  static func ideas(_ kind: OfficeKind) -> [String] {
    switch kind {
    case .document:
      [
        "Write a first draft from my notes in this document",
        "Tighten the whole document and fix any grammar",
        "Add a short summary at the top",
      ]
    case .spreadsheet:
      [
        "Add a totals row and a column of percentages",
        "Build a monthly budget template here",
        "Chart this data on a dashboard",
      ]
    case .presentation:
      [
        "Design a beautiful 8-slide deck on this topic",
        "Match this deck to my company’s website brand",
        "Make every slide more visual: charts, stats and motion",
      ]
    }
  }

  private func askBox(_ file: OfficeFile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let quote = pendingAsk?.quote {
        HStack(alignment: .top, spacing: 6) {
          Rectangle().fill(palette.signal).frame(width: 2)
          Text(quote).font(.ottoDisplay(11.5)).foregroundStyle(palette.paper.opacity(0.8))
            .lineLimit(4)
          Spacer(minLength: 0)
          Button {
            pendingAsk = nil
          } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(palette.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      AssistantPromptBar(
        services: services,
        placeholder: pendingAsk?.quote == nil
          ? "Ask about this \(file.kind.displayName.lowercased())…" : "What should change?",
        target: target, showsPicker: false
      ) { request in
        await send(request, quote: pendingAsk?.quote, bot: pendingAsk?.bot, file: file)
        pendingAsk = nil
      }
    }
    .padding(14)
  }

  // MARK: Actions

  private func handleAsk(_ ask: OfficeAsk) {
    withAnimation(.easeOut(duration: 0.18)) { showsPanel = true }
    guard let file = openFile else { return }
    if let bot = ask.bot {
      // Tagging a bot hands this file's chat to that bot.
      helperTarget(file).wrappedValue = .bot(bot)
    }
    if let request = ask.request {
      Task { await send(request, quote: ask.quote, bot: nil, file: file) }
    } else {
      pendingAsk = ask
    }
  }

  /// Sends to the file's own helper chat, which stays here beside the file.
  private func send(_ request: String, quote: String?, bot: UUID?, file: OfficeFile) async {
    // The agent reads from disk too, so make sure what's on screen is saved first.
    editors.controller(for: file.path)?.saveNow()
    var message = request
    if let quote, !quote.isEmpty {
      message += "\n\n> " + quote.prefix(4_000).replacingOccurrences(of: "\n", with: "\n> ")
    }
    do {
      _ = try await start(target.wrappedValue, message, file.path)
      pendingAsk = nil
      error = nil
    } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t reach the agent", detail: error.localizedDescription)
    }
  }

  private func startWithAI(_ request: String) async {
    let lower = request.lowercased()
    let kind: OfficeKind =
      ["sheet", "spreadsheet", "budget", "table", "tracker", "excel"].contains {
        lower.contains($0)
      }
      ? .spreadsheet
      : ["slide", "deck", "presentation", "pitch"].contains { lower.contains($0) }
        ? .presentation : .document
    let title = Self.title(from: request)
    do {
      let file = try office.create(kind, title: title)
      openPath = file.path
      showsPanel = true
      await send("Create this from scratch: \(request)", quote: nil, bot: nil, file: file)
    } catch {
      self.error = error.localizedDescription
    }
  }

  static func title(from request: String) -> String { DocumentsTitle.from(request, words: 7) }

  private func create(_ kind: OfficeKind) {
    attempt {
      let file = try office.create(kind, title: "Untitled \(kind.displayName.lowercased())")
      open(file)
    }
  }

  private func open(_ file: OfficeFile) {
    openPath = file.path
  }

  private func importFiles() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [
      UTType(filenameExtension: "docx"), .rtf, .plainText, .commaSeparatedText,
      UTType(filenameExtension: "md"),
    ].compactMap { $0 }
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      attempt { _ = try office.importFile(url) }
    }
  }

  private func export(_ file: OfficeFile, type: String, data: () throws -> Data) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(file.title).\(type)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try data().write(to: url, options: .atomic)
      status = OttoStatusToast(kind: .success, title: "Exported", detail: url.lastPathComponent)
    } catch {
      status = OttoStatusToast(
        kind: .error, title: "Couldn’t export", detail: error.localizedDescription)
    }
  }

  /// Exports need the deck engine to render each slide first, which takes a moment.
  private func exportDeck(
    _ file: OfficeFile, type: String, data: @escaping (Presentation) async -> Data
  ) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(file.title).\(type)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    status = OttoStatusToast(kind: .info, title: "Exporting…", detail: url.lastPathComponent)
    Task {
      do {
        let deck = try office.loadDeck(path: file.path)
        let output = await data(deck)
        guard !output.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try output.write(to: url, options: .atomic)
        status = OttoStatusToast(kind: .success, title: "Exported", detail: url.lastPathComponent)
      } catch {
        status = OttoStatusToast(
          kind: .error, title: "Couldn’t export", detail: error.localizedDescription)
      }
    }
  }

  private func attempt(_ action: () throws -> Void) {
    do {
      try action()
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}

/// One editor per open document, kept while Documents is on screen, so the text view, its
/// undo history and the agent's live link always point at the same object.
@MainActor
final class DocEditorCache: ObservableObject {
  private var editors: [String: (controller: DocEditorController, initial: NSAttributedString)] =
    [:]

  func editor(
    for path: String, office: OfficeStore, configure: (DocEditorController) -> Void
  ) -> (controller: DocEditorController, initial: NSAttributedString) {
    if let existing = editors[path] { return existing }
    let controller = DocEditorController()
    configure(controller)
    controller.save = { [weak office] text in try office?.saveDocument(text, path: path) }
    let initial = (try? office.loadDocument(path: path)) ?? NSAttributedString(string: "")
    editors[path] = (controller, initial)
    return (controller, initial)
  }

  func controller(for path: String) -> DocEditorController? { editors[path]?.controller }

  func forget(_ path: String) { editors[path] = nil }
}

/// Short names from what people type: "a one-page project brief for the Acme launch" →
/// "Project brief for the Acme launch".
enum DocumentsTitle {
  static func from(_ request: String, words limit: Int) -> String {
    var words = request.split(separator: " ").map(String.init)
    let filler: Set<String> = [
      "a", "an", "the", "write", "make", "create", "draft", "build", "me", "my", "please",
      "one-page", "short", "quick", "new",
    ]
    while let first = words.first, filler.contains(first.lowercased()) { words.removeFirst() }
    let title = words.prefix(limit).joined(separator: " ")
      .trimmingCharacters(in: .punctuationCharacters)
    guard let first = title.first else { return "Untitled" }
    return first.uppercased() + title.dropFirst()
  }
}

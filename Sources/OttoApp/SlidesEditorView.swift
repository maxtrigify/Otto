import AppKit
import OttoModels
import OttoServices
import SwiftUI
import WebKit

/// Decks built like websites: the slide in the middle is a live page you can type on, the
/// thumbnails are rendered by the same engine, and agents redesign slides through the side panel.
struct SlidesEditorView: View {
  @Environment(\.ottoSpaceVisible) private var spaceVisible
  @ObservedObject var office: OfficeStore
  let file: OfficeFile
  let ask: (OfficeAsk) -> Void
  let bots: [(id: UUID, name: String)]
  @Environment(\.ottoPalette) private var palette
  @State private var deck = Presentation()
  @State private var selectedID: UUID?
  @State private var pageHTML = ""
  @State private var token = 0
  @State private var loadError: String?
  @State private var saveTask: Task<Void, Never>?
  @State private var showsHTML = false
  @State private var htmlDraft = ""
  @State private var askingBrand = false
  @State private var brandURL = ""
  @State private var selection = ""
  @StateObject private var keys = SlideKeys()

  private var index: Int { deck.slides.firstIndex { $0.id == selectedID } ?? 0 }

  var body: some View {
    HStack(spacing: 0) {
      thumbnails
      Divider().overlay(palette.paper.opacity(0.08))
      VStack(spacing: 0) {
        toolbar
        Divider().overlay(palette.paper.opacity(0.08))
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            DeckWebView(
              html: pageHTML, token: token,
              onEdit: { html in editedInPlace(html) },
              onSelection: { selection = $0 },
              onEditingText: { keys.typingOnSlide = $0 }
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.paper.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .contextMenu { slideMenu(index) }
            hintRow
            inspector
          }
          .padding(24)
          .frame(maxWidth: 1040)
          .frame(maxWidth: .infinity)
        }
        if let loadError {
          Text(loadError).font(.ottoDisplay(11)).foregroundStyle(palette.red).padding(8)
        }
      }
    }
    .onAppear {
      load()
      keys.step = { offset in step(offset) }
      if spaceVisible { keys.start() }
    }
    .onChange(of: spaceVisible) { _, visible in
      if visible { keys.start() } else { keys.stop() }
    }
    .onDisappear { keys.stop() }
    .onChange(of: office.revisions[file.path]) { _, _ in load() }
    .onChange(of: selectedID) { _, _ in reloadPage() }
    .alert("Match a brand", isPresented: $askingBrand) {
      TextField("Website, e.g. stripe.com", text: $brandURL)
      Button("Match") {
        let site = brandURL.trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty else { return }
        ask(
          OfficeAsk(
            request:
              "Match this deck to the brand at \(site): read the site, then set its colours, fonts, logo and name with slides.set_theme, and adjust the wording to its voice."
          ))
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("An agent reads the site and applies its colours, fonts and logo.")
    }
  }

  // MARK: Pieces

  /// ↑ ↓ (and Page Up/Down, Home, End) move through the slides.
  private func step(_ offset: Int) {
    guard !deck.slides.isEmpty else { return }
    let target =
      offset == .min
      ? 0
      : offset == .max
        ? deck.slides.count - 1
        : min(max(0, index + offset), deck.slides.count - 1)
    selectedID = deck.slides[target].id
  }

  private var thumbnails: some View {
    let touched = office.agentTouched[file.path] ?? []
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(Array(deck.slides.enumerated()), id: \.element.id) { position, slide in
            let selected = slide.id == selectedID
            Button {
              selectedID = slide.id
            } label: {
              HStack(alignment: .top, spacing: 8) {
                Text("\(position + 1)").font(.ottoMono(10)).foregroundStyle(palette.muted)
                  .frame(width: 16, alignment: .trailing)
                DeckThumbnail(deck: deck, index: position)
                  .clipShape(RoundedRectangle(cornerRadius: 5))
                  .overlay(
                    RoundedRectangle(cornerRadius: 5).strokeBorder(
                      selected ? palette.signal : palette.paper.opacity(0.1),
                      lineWidth: selected ? 2 : 1)
                  )
                  .overlay(alignment: .topTrailing) {
                    if touched.contains(slide.id.uuidString) {
                      Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(palette.ink)
                        .padding(4)
                        .background(palette.signal, in: Circle())
                        .padding(4)
                        .help("Changed by AI")
                    }
                  }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { slideMenu(position) }
          }
          newSlideMenu(label: true).padding(.leading, 24)
        }
        .padding(14)
      }
      // Keep the chosen slide in view as the keys move through the list.
      .onChange(of: selectedID) { _, id in
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
      }
    }
    .frame(width: 220)
    .background(palette.raised.opacity(0.5))
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      newSlideMenu(label: false)
      Menu {
        ForEach(Presentation.Theme.allCases, id: \.self) { theme in
          Button {
            change(by: "You") {
              $0.theme = theme
              $0.brand = nil
            }
          } label: {
            if deck.theme == theme && deck.brand == nil {
              Label(theme.displayName, systemImage: "checkmark")
            } else {
              Text(theme.displayName)
            }
          }
        }
        Divider()
        Button("Match a brand from a website…", systemImage: "globe") {
          brandURL = ""
          askingBrand = true
        }
      } label: {
        Label(deck.brand?.brandName ?? deck.theme.displayName, systemImage: "paintpalette")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Menu {
        let versions = (deck.history ?? []).reversed()
        if versions.isEmpty {
          Text("No earlier versions yet")
        }
        ForEach(Array(versions)) { version in
          Button(
            "Before \(version.author == "You" ? "your" : version.author + "’s") change · \(version.createdAt.formatted(.relative(presentation: .named)))"
          ) {
            var copy = deck
            if copy.revert(to: version.id, by: "You") {
              deck = copy
              selectedID = deck.slides.first?.id
              saveNow()
              reloadPage()
            }
          }
        }
      } label: {
        Label("History", systemImage: "clock.arrow.circlepath")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      if !(office.agentTouched[file.path] ?? []).isEmpty {
        Button("Clear AI marks") { office.clearTouched(path: file.path) }
          .buttonStyle(.plain).foregroundStyle(palette.signal)
      }
      Button {
        saveNow()
        DeckPresenter.present(deck, from: index, title: file.title)
      } label: {
        Label("Present", systemImage: "play.fill")
          .font(.ottoDisplay(12).weight(.semibold))
          .padding(.horizontal, 12).padding(.vertical, 5)
      }
      .buttonStyle(.ottoPrimary(cornerRadius: 7))
      .keyboardShortcut(.return, modifiers: [.command])
      .accessibilityIdentifier("slides.present")
    }
    .font(.ottoDisplay(12))
    .padding(.horizontal, 14)
    .frame(height: 42)
  }

  private func newSlideMenu(label: Bool) -> some View {
    Menu {
      ForEach(DeckTemplates.all, id: \.name) { template in
        Button(template.name, systemImage: template.symbol) { insert(template.html) }
      }
      Divider()
      Button("Ask AI to design a slide…", systemImage: "sparkles") {
        ask(OfficeAsk(quote: "After slide \(index + 1) of “\(file.title)”"))
      }
    } label: {
      if label {
        Label("Add slide", systemImage: "plus").font(.ottoDisplay(12))
          .frame(maxWidth: .infinity).frame(height: 30)
          .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
      } else {
        Label("New slide", systemImage: "plus.rectangle")
      }
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(label ? .hidden : .visible)
    .fixedSize(horizontal: !label, vertical: true)
  }

  private var hintRow: some View {
    HStack(spacing: 10) {
      Text("CLICK TEXT ON THE SLIDE TO EDIT IT").font(.ottoMicro).tracking(1.4)
      Spacer()
      Button {
        ask(
          OfficeAsk(
            quote: selection.isEmpty
              ? "Slide \(index + 1) of “\(file.title)”"
              : "“\(selection)” on slide \(index + 1) of “\(file.title)”"))
      } label: {
        Label(
          selection.isEmpty ? "Ask AI about this slide" : "Ask AI about the selection",
          systemImage: "sparkles")
      }
      .buttonStyle(.plain)
      .foregroundStyle(palette.signal)
      .font(.ottoDisplay(12))
    }
    .foregroundStyle(palette.muted)
  }

  private var inspector: some View {
    let notes = Binding(
      get: { deck.slides.indices.contains(index) ? deck.slides[index].notes : "" },
      set: { value in
        guard deck.slides.indices.contains(index) else { return }
        deck.slides[index].notes = value
        scheduleSave()
      })
    return VStack(alignment: .leading, spacing: 12) {
      field("SPEAKER NOTES") {
        TextEditor(text: notes).font(.ottoDisplay(13)).scrollContentBackground(.hidden)
          .frame(minHeight: 70)
      }
      DisclosureGroup(isExpanded: $showsHTML) {
        VStack(alignment: .trailing, spacing: 8) {
          TextEditor(text: $htmlDraft).font(.ottoMono(11)).scrollContentBackground(.hidden)
            .frame(minHeight: 180)
            .padding(8)
            .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
          Button("Apply HTML") {
            change(by: "You") { deck in
              if deck.slides.indices.contains(index) {
                deck.slides[index].html = DeckHTML.sanitize(htmlDraft)
              }
            }
          }
        }
        .padding(.top, 8)
      } label: {
        Text("SLIDE HTML").font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
      }
      .onChange(of: showsHTML) { _, open in if open { htmlDraft = currentHTML } }
    }
    .foregroundStyle(palette.paper)
  }

  private var currentHTML: String {
    deck.slides.indices.contains(index) ? deck.slides[index].renderedHTML : ""
  }

  private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.ottoMicro).tracking(1.6).foregroundStyle(palette.muted)
      content()
        .padding(10)
        .background(palette.paper.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.paper.opacity(0.08)))
    }
  }

  @ViewBuilder private func slideMenu(_ position: Int) -> some View {
    let quote = "Slide \(position + 1) of “\(file.title)”"
    Button("Ask AI about this slide…", systemImage: "sparkles") { ask(OfficeAsk(quote: quote)) }
    Button("Make it more visual") {
      ask(
        OfficeAsk(
          quote: quote,
          request:
            "Redesign this slide to be more visual and striking: use the deck components (stats, charts, cards, motion, a backdrop) and fewer words."
        ))
    }
    Button("Tighten the wording") {
      ask(
        OfficeAsk(
          quote: quote, request: "Tighten this slide: a sharper headline and fewer, punchier words."
        ))
    }
    if !bots.isEmpty {
      Menu("Ask a bot") {
        ForEach(bots, id: \.id) { bot in
          Button(bot.name) { ask(OfficeAsk(quote: quote, bot: bot.id)) }
        }
      }
    }
    Divider()
    Button("Duplicate") {
      change(by: "You") { deck in
        guard deck.slides.indices.contains(position) else { return }
        var copy = deck.slides[position]
        copy.id = UUID()
        deck.slides.insert(copy, at: position + 1)
      }
    }
    Button("Move up") { move(position, by: -1) }.disabled(position == 0)
    Button("Move down") { move(position, by: 1) }.disabled(position == deck.slides.count - 1)
    Button("Delete slide", role: .destructive) {
      guard deck.slides.count > 1 else { return }
      change(by: "You") { $0.slides.remove(at: position) }
    }
    .disabled(deck.slides.count <= 1)
  }

  // MARK: Changes

  private func load() {
    do {
      deck = try office.loadDeck(path: file.path)
      if selectedID == nil || !deck.slides.contains(where: { $0.id == selectedID }) {
        selectedID = deck.slides.first?.id
      }
      loadError = nil
      reloadPage()
    } catch {
      loadError = "Couldn’t open: \(error.localizedDescription)"
    }
  }

  private func reloadPage() {
    pageHTML = DeckRenderer.page(deck, indices: [index], mode: .edit, title: file.title)
    token += 1
    if showsHTML { htmlDraft = currentHTML }
  }

  /// Text typed on the slide itself: saved without reloading, so the caret stays put.
  private func editedInPlace(_ html: String) {
    guard deck.slides.indices.contains(index) else { return }
    deck.slides[index].html = DeckHTML.sanitize(html)
    scheduleSave()
  }

  /// A structural change by the person: keep the previous version, save, redraw.
  private func change(by author: String, _ edit: (inout Presentation) -> Void) {
    var next = deck
    next.snapshot(by: author)
    edit(&next)
    deck = next
    if !deck.slides.contains(where: { $0.id == selectedID }) {
      selectedID = deck.slides[min(index, deck.slides.count - 1)].id
    }
    saveNow()
    reloadPage()
  }

  private func insert(_ html: String) {
    let slide = Slide(title: "", html: html)
    change(by: "You") { deck in
      deck.slides.insert(slide, at: min(index + 1, deck.slides.count))
    }
    selectedID = slide.id
  }

  private func move(_ position: Int, by offset: Int) {
    change(by: "You") { deck in
      let target = position + offset
      guard deck.slides.indices.contains(target) else { return }
      deck.slides.swapAt(position, target)
    }
  }

  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      saveNow()
    }
  }

  private func saveNow() {
    saveTask?.cancel()
    do { try office.saveDeck(deck, path: file.path) } catch {
      loadError = "Not saved: \(error.localizedDescription)"
    }
  }
}

/// A slide picture rendered off screen by the deck engine, refreshed when the slide changes.
struct DeckThumbnail: View {
  let deck: Presentation
  let index: Int
  @State private var image: NSImage?
  @Environment(\.ottoPalette) private var palette

  var body: some View {
    ZStack {
      Rectangle().fill(Color(hex: deck.tokens.background) ?? palette.ink)
      if let image {
        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fit)
      } else {
        ProgressView().controlSize(.mini)
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
    .task(id: DeckSnapshotter.key(deck, index)) {
      image = DeckSnapshotter.shared.cached(deck, index)
      image = await DeckSnapshotter.shared.image(deck, index: index, width: 360) ?? image
    }
  }
}

/// A borderless window that can take the keyboard (plain borderless windows can't).
final class PresentationWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// Full-screen presenting. Keys are handled natively so they always work: → ↓ Space Return
/// Page Down (and presenter remotes or a keypad) go forward, ← ↑ Page Up go back, Home/End jump,
/// a number then Return goes to that slide, and Esc finishes.
@MainActor
enum DeckPresenter {
  private static var window: NSWindow?
  private(set) static var webView: WKWebView?
  private static var monitor: Any?
  private static var typedNumber = ""
  private static var previousOptions: NSApplication.PresentationOptions = []
  private static var shownOnScreen = false

  /// `onScreen` false keeps the window off screen, for tests.
  static func present(
    _ deck: Presentation, from start: Int, title: String, onScreen: Bool = true
  ) {
    guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
    close()
    let window = PresentationWindow(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .statusBar
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    let web = WKWebView(frame: CGRect(origin: .zero, size: screen.frame.size))
    web.autoresizingMask = [.width, .height]
    web.setValue(false, forKey: "drawsBackground")
    web.loadHTMLString(
      DeckRenderer.page(deck, mode: .present, start: start, title: title), baseURL: nil)
    window.contentView = web
    window.setFrame(screen.frame, display: true)
    if onScreen {
      previousOptions = NSApp.presentationOptions
      NSApp.presentationOptions = [.hideDock, .hideMenuBar]
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.makeFirstResponder(web)
    }
    shownOnScreen = onScreen
    self.window = window
    webView = web
    typedNumber = ""
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard self.window != nil, event.window === self.window || NSApp.keyWindow === self.window
      else { return event }
      return handle(event) ? nil : event
    }
  }

  /// Returns true when the key was used.
  static func handle(_ event: NSEvent) -> Bool {
    switch event.keyCode {
    case 53:  // Esc
      close()
    case 124, 125, 49, 36, 76, 121:  // → ↓ Space Return keypad-Enter PageDown
      if event.keyCode == 36 || event.keyCode == 76, let number = Int(typedNumber) {
        go("OttoDeck.go(\(max(0, number - 1)))")
      } else {
        go("OttoDeck.next()")
      }
    case 123, 126, 116, 51:  // ← ↑ PageUp Delete
      go("OttoDeck.prev()")
    case 115: go("OttoDeck.go(0)")  // Home
    case 119: go("OttoDeck.go(OttoDeck.count - 1)")  // End
    default:
      // Digits from the number row or keypad build a slide number for Return.
      if let characters = event.charactersIgnoringModifiers, characters.count == 1,
        characters.first?.isNumber == true
      {
        typedNumber += characters
        return true
      }
      if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "." {
        close()
        return true
      }
      return false
    }
    return true
  }

  private static func go(_ script: String) {
    typedNumber = ""
    webView?.evaluateJavaScript(script, completionHandler: nil)
  }

  static func close() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    if window != nil, shownOnScreen { NSApp.presentationOptions = previousOptions }
    window?.orderOut(nil)
    window = nil
    webView = nil
  }

  static var isPresenting: Bool { window != nil }
  static var windowTakesKeyboard: Bool { window?.canBecomeKey ?? false }
}

/// Arrow keys for the slide list. Watches key presses in this window and moves between
/// slides, except while text is being typed (in the notes, the HTML box, or on the slide).
@MainActor
final class SlideKeys: ObservableObject {
  var typingOnSlide = false
  var step: (Int) -> Void = { _ in }
  private var monitor: Any?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.handle(event) else { return event }
      return nil
    }
  }

  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  /// Off for tests, which can't make a window key.
  var requireKeyWindow = true
  /// While presenting, the presenter owns the keys.
  var isPresenting: () -> Bool = { DeckPresenter.isPresenting }

  func handle(_ event: NSEvent, responder: NSResponder? = nil) -> Bool {
    guard !isPresenting(), !typingOnSlide,
      event.modifierFlags.intersection([.command, .option, .control]).isEmpty
    else { return false }
    if requireKeyWindow {
      guard let window = event.window, window.isKeyWindow else { return false }
    }
    // Text fields and text views keep their arrow keys.
    let focused = responder ?? event.window?.firstResponder
    if focused is NSText { return false }
    switch event.keyCode {
    case 125, 124, 121: step(1)  // ↓ → Page Down
    case 126, 123, 116: step(-1)  // ↑ ← Page Up
    case 115: step(.min)  // Home
    case 119: step(.max)  // End
    default: return false
    }
    return true
  }
}

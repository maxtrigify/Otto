import AppKit
import OttoModels
import Testing
import WebKit

@testable import OttoApp

@MainActor
@Suite("Presenting slides", .serialized)
struct DeckPresenterTests {
  private func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [])
    -> NSEvent
  {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
  }

  private func current() async throws -> Int {
    let web = try #require(DeckPresenter.webView)
    return try #require(await web.evaluateJavaScript("OttoDeck.current()") as? Int)
  }

  @Test("Arrows, Space, Page keys, keypad numbers and Esc all work while presenting")
  func keys() async throws {
    _ = NSApplication.shared
    let deck = Presentation(
      slides: (1...5).map { Slide(title: "Slide \($0)", layout: .bullets) })
    DeckPresenter.present(deck, from: 0, title: "Test", onScreen: false)
    defer { DeckPresenter.close() }
    try await Task.sleep(for: .milliseconds(1_200))
    #expect(DeckPresenter.isPresenting)
    // Plain borderless windows refuse the keyboard; this one must accept it.
    #expect(DeckPresenter.windowTakesKeyboard)
    #expect(DeckPresenter.handle(key(124)))  // →
    #expect(DeckPresenter.handle(key(49, " ")))  // Space
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await current() == 2)
    #expect(DeckPresenter.handle(key(116)))  // Page Up (presenter remotes)
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await current() == 1)
    // Typing 5 on the keypad then Enter jumps to slide 5.
    #expect(DeckPresenter.handle(key(87, "5")))
    #expect(DeckPresenter.handle(key(76)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await current() == 4)
    #expect(DeckPresenter.handle(key(115)))  // Home
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await current() == 0)
    #expect(DeckPresenter.handle(key(53)))  // Esc
    #expect(!DeckPresenter.isPresenting)
  }
}

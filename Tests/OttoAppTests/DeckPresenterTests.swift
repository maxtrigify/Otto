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

  private func waitForDeckScript() async throws {
    let web = try #require(DeckPresenter.webView)
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
      let ready = try? await web.evaluateJavaScript("typeof OttoDeck !== 'undefined'") as? Bool
      if ready == true { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    Issue.record("The deck page never loaded")
  }

  /// Key handling is applied by the deck's web view asynchronously; a busy CI runner can take
  /// longer than a fixed delay, so poll until the slide settles (bounded).
  private func settledSlide(_ expected: Int) async throws -> Int {
    let deadline = ContinuousClock.now + .seconds(5)
    var slide = try await current()
    while slide != expected, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
      slide = try await current()
    }
    return slide
  }

  @Test("Arrows, Space, Page keys, keypad numbers and Esc all work while presenting")
  func keys() async throws {
    _ = NSApplication.shared
    let deck = Presentation(
      slides: (1...5).map { Slide(title: "Slide \($0)", layout: .bullets) })
    DeckPresenter.present(deck, from: 0, title: "Test", onScreen: false)
    defer { DeckPresenter.close() }
    // The deck page loads asynchronously (slowly on a CI runner); keys sent before its script
    // exists would be lost, so wait for it (bounded) rather than sleeping a fixed time.
    try await waitForDeckScript()
    #expect(DeckPresenter.isPresenting)
    // Plain borderless windows refuse the keyboard; this one must accept it.
    #expect(DeckPresenter.windowTakesKeyboard)
    #expect(DeckPresenter.handle(key(124)))  // →
    #expect(DeckPresenter.handle(key(49, " ")))  // Space
    #expect(try await settledSlide(2) == 2)
    #expect(DeckPresenter.handle(key(116)))  // Page Up (presenter remotes)
    #expect(try await settledSlide(1) == 1)
    // Typing 5 on the keypad then Enter jumps to slide 5.
    #expect(DeckPresenter.handle(key(87, "5")))
    #expect(DeckPresenter.handle(key(76)))
    #expect(try await settledSlide(4) == 4)
    #expect(DeckPresenter.handle(key(115)))  // Home
    #expect(try await settledSlide(0) == 0)
    #expect(DeckPresenter.handle(key(53)))  // Esc
    #expect(!DeckPresenter.isPresenting)
  }
}

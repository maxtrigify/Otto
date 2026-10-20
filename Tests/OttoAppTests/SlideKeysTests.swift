import AppKit
import Testing

@testable import OttoApp

@MainActor
@Suite("Slide list keys")
struct SlideKeysTests {
  private func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: code)!
  }

  @Test("↑ ↓ Page Up/Down Home End move between slides, but not while typing")
  func arrows() {
    let keys = SlideKeys()
    keys.requireKeyWindow = false
    keys.isPresenting = { false }
    var moves: [Int] = []
    keys.step = { moves.append($0) }
    #expect(keys.handle(key(125)))  // ↓
    #expect(keys.handle(key(126)))  // ↑
    #expect(keys.handle(key(121)))  // Page Down
    #expect(keys.handle(key(115)))  // Home
    #expect(keys.handle(key(119)))  // End
    #expect(moves == [1, -1, 1, .min, .max])
    // Typing in the notes keeps the arrows for the text.
    #expect(!keys.handle(key(125), responder: NSTextView()))
    // So does typing on the slide itself.
    keys.typingOnSlide = true
    #expect(!keys.handle(key(125)))
    #expect(moves.count == 5)
  }
}

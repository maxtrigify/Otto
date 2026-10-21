import AppKit
import Testing

@testable import OttoApp

@Suite("Otto browser input")
struct OttoBrowserInputTests {
  @Test("Command-T opens a tab, keeping Control-T as an alias")
  func newTabShortcut() {
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.control]) == .newTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.command]) == .newTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: []) == nil)
  }

  @Test("Browser commands use exact modifier combinations")
  func browserShortcuts() {
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 13, modifiers: [.command]) == .closeTab)
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.command, .shift]) == .reopenTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 37, modifiers: [.command]) == .focusAddress)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 15, modifiers: [.command]) == .reload)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 33, modifiers: [.command]) == .back)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 30, modifiers: [.command]) == .forward)
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 30, modifiers: [.command, .shift]) == .nextTab)
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 33, modifiers: [.command, .shift]) == .previousTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 48, modifiers: [.control]) == .nextTab)
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 48, modifiers: [.control, .shift]) == .previousTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.command, .option]) == nil)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 13, modifiers: [.command, .shift]) == nil)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 3, modifiers: [.command]) == nil)
  }

  @Test("Standard mouse history buttons map to back and forward")
  func mouseHistoryButtons() {
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 3) == .back)
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 4) == .forward)
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 2) == nil)
  }
}

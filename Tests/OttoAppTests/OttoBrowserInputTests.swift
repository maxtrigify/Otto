import AppKit
import Testing

@testable import OttoApp

@Suite("Otto browser input")
struct OttoBrowserInputTests {
  @Test("Control-T opens a tab without claiming other T shortcuts")
  func newTabShortcut() {
    #expect(
      OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.control]) == .newTab)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: [.command]) == nil)
    #expect(OttoBrowserInputPolicy.keyAction(keyCode: 17, modifiers: []) == nil)
  }

  @Test("Standard mouse history buttons map to back and forward")
  func mouseHistoryButtons() {
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 3) == .back)
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 4) == .forward)
    #expect(OttoBrowserInputPolicy.mouseAction(buttonNumber: 2) == nil)
  }
}

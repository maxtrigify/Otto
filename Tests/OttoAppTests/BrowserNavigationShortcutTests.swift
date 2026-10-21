import AppKit
import Testing

@testable import OttoApp

@Suite("Browser shortcut context") @MainActor
struct BrowserNavigationShortcutTests {
  @Test func commandBStillFormatsDocumentText() {
    let controller = DocEditorController()
    let editor = OttoDocTextView(usingTextLayoutManager: false)
    editor.controller = controller
    controller.textView = editor
    editor.textStorage?.setAttributedString(
      NSAttributedString(string: "Selected", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    editor.setSelectedRange(NSRange(location: 0, length: 8))
    #expect(
      BrowserNavigationShortcut.formatDocumentIfNeeded(firstResponder: editor, isKeyPress: true))
    let font = editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true)
    #expect(
      !BrowserNavigationShortcut.formatDocumentIfNeeded(firstResponder: editor, isKeyPress: false))
  }
  @Test func otherFocusNavigatesToBrowser() {
    #expect(
      !BrowserNavigationShortcut.formatDocumentIfNeeded(
        firstResponder: NSTextView(), isKeyPress: true))
    #expect(
      !BrowserNavigationShortcut.formatDocumentIfNeeded(firstResponder: nil, isKeyPress: true))
  }
}

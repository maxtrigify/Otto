import AppKit

@MainActor
enum BrowserNavigationShortcut {
  /// A direct menu click always navigates. The keyboard retains Bold inside document text.
  static func formatDocumentIfNeeded(firstResponder: NSResponder?, isKeyPress: Bool) -> Bool {
    guard isKeyPress, let editor = firstResponder as? OttoDocTextView,
      let controller = editor.controller
    else { return false }
    controller.toggleTrait(.boldFontMask)
    return true
  }
}

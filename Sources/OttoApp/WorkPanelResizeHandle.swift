import AppKit
import SwiftUI

/// Native mouse capture keeps resizing active when the pointer crosses an embedded web view.
struct WorkPanelResizeHandle: NSViewRepresentable {
  var began: () -> Void
  var changed: (Double) -> Void
  var ended: () -> Void

  func makeNSView(context: Context) -> HandleView { HandleView() }

  func updateNSView(_ view: HandleView, context: Context) {
    view.began = began
    view.changed = changed
    view.ended = ended
  }

  final class HandleView: NSView {
    var began: (() -> Void)?
    var changed: ((Double) -> Void)?
    var ended: (() -> Void)?
    private var startX: CGFloat?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
      NSColor.separatorColor.setFill()
      NSRect(x: bounds.midX, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
      startX = event.locationInWindow.x
      began?()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let startX else { return }
      changed?(Double(event.locationInWindow.x - startX))
    }

    override func mouseUp(with event: NSEvent) {
      startX = nil
      ended?()
    }
  }
}

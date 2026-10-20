import AppKit
import Foundation
import Testing
import WebKit

@testable import OttoApp

@Suite("Mermaid chat diagrams")
struct MermaidDiagramTests {
  @Test("Markdown parser preserves Mermaid language and source")
  func parsesMermaidFence() {
    let blocks = MarkdownBlockParser.parse(
      """
      Before

      ```mermaid
      flowchart LR
        User --> Otto
      ```
      """)

    #expect(blocks.count == 2)
    guard case .code(let language, let source) = blocks[1].content else {
      Issue.record("Expected a fenced code block")
      return
    }
    #expect(language == "mermaid")
    #expect(source == "flowchart LR\n  User --> Otto")
  }

  @Test("Render policy rejects empty and oversized sources")
  func appliesSourceLimits() {
    #expect(!MermaidRenderPolicy.accepts("  \n"))
    #expect(MermaidRenderPolicy.accepts("flowchart LR\nA --> B"))
    #expect(!MermaidRenderPolicy.accepts(String(repeating: "A", count: 65_537)))
  }

  @Test("Bridge accepts bounded messages")
  func parsesBridgeMessages() {
    #expect(MermaidBridgeMessage(body: ["type": "ready"]) == .ready)
    #expect(MermaidBridgeMessage(body: ["type": "rendered"]) == .rendered)
    #expect(MermaidBridgeMessage(body: ["type": "height", "value": 4]) == .height(88))
    #expect(MermaidBridgeMessage(body: ["type": "height", "value": 9_000]) == .height(1_200))
    #expect(MermaidBridgeMessage(body: ["type": "height", "value": Double.nan]) == nil)
    #expect(MermaidBridgeMessage(body: ["type": "unknown"]) == nil)
  }

  @Test("Preview height follows the conversation viewport")
  func boundsPreviewHeight() {
    #expect(MermaidRenderPolicy.previewHeightLimit(viewportHeight: 800) == 284)
    #expect(MermaidRenderPolicy.previewHeightLimit(viewportHeight: 500) == 164)
    #expect(MermaidRenderPolicy.previewHeightLimit(viewportHeight: .nan) == 320)
  }

  @Test("Inline WebKit content cannot capture conversation gestures")
  @MainActor
  func inlinePreviewPassesHitTestingToConversation() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
    scroll.documentView = document
    let preview = MermaidNativeWebView(
      frame: NSRect(x: 0, y: 0, width: 600, height: 250), configuration: WKWebViewConfiguration())
    document.addSubview(preview)
    let point = NSPoint(x: 100, y: 100)
    #expect(preview.hitTest(point) == nil)
    #expect(preview.enclosingScrollView === scroll)
    #expect(document.hitTest(point) === document)
    preview.isInteractive = true
    #expect(preview.hitTest(point) != nil)
  }

  @Test("Bundled renderer resources are available")
  func includesRendererResources() {
    #expect(MermaidRendererResources.indexURL != nil)
  }
}

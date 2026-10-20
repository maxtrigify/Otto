import Foundation
import Testing

@testable import OttoApp

@Suite("Conversation render policy")
struct ConversationRenderPolicyTests {
  @Test("A long transcript opens on a bounded recent window")
  func boundedRecentWindow() {
    #expect(
      ConversationRenderPolicy.visibleRange(totalCount: 10_000, limit: 80) == 9_920..<10_000
    )
    #expect(ConversationRenderPolicy.visibleRange(totalCount: 40, limit: 80) == 0..<40)
    #expect(ConversationRenderPolicy.visibleRange(totalCount: 0, limit: 80) == 0..<0)
  }

  @Test("History expands in bounded pages")
  func boundedExpansion() {
    #expect(ConversationRenderPolicy.expandedLimit(current: 80, totalCount: 10_000) == 160)
    #expect(ConversationRenderPolicy.expandedLimit(current: 160, totalCount: 175) == 175)
  }

  @Test("Switching chats opens on a short recent window")
  func switchOpensShortWindow() {
    #expect(ConversationRenderPolicy.initialRowLimit <= 30)
  }

  @Test("Reparsing a message returns the cached blocks unchanged")
  func markdownParseIsCached() {
    let text = "# Title\n\nSome **bold** text with `code`.\n\n- one\n- two"
    let first = MarkdownBlockParser.parse(text)
    #expect(MarkdownBlockParser.parse(text) == first)
    #expect(first.count == 3)
    #expect(InlineMarkdownCache.parse("a **b**") == InlineMarkdownCache.parse("a **b**"))
  }

  @Test("The chat layout boundary contains no frame-driven SwiftUI source")
  func noFrameDrivenChatLayout() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: repository.appending(path: "Sources/OttoApp/AgentConversationBody.swift"),
      encoding: .utf8
    )
    let start = try #require(source.range(of: "// CHAT_LAYOUT_BOUNDARY_BEGIN"))
    let end = try #require(source.range(of: "// CHAT_LAYOUT_BOUNDARY_END"))
    let chatBoundary = source[start.upperBound..<end.lowerBound]

    #expect(!chatBoundary.contains("TimelineView("))
    #expect(!chatBoundary.contains("repeatForever"))
    #expect(!chatBoundary.contains("GeometryReader"))
    #expect(!chatBoundary.contains(".textSelection(.enabled)"))
  }

  @Test("Selection is scoped to stable transcript rows")
  func selectionIsScopedToStableTranscriptRows() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let conversation = try String(
      contentsOf: repository.appending(path: "Sources/OttoApp/AgentConversationBody.swift"),
      encoding: .utf8
    )
    let markdown = try String(
      contentsOf: repository.appending(path: "Sources/OttoApp/MarkdownMessageView.swift"),
      encoding: .utf8
    )
    #expect(conversation.contains("content.modifier(StableTranscriptSelectionModifier())"))
    #expect(conversation.contains("content.textSelection(.enabled)"))
    // Message action bars and disclosure buttons remain click targets under the inherited
    // transcript selection environment.
    #expect(conversation.components(separatedBy: ".textSelection(.disabled)").count >= 4)
    #expect(!markdown.contains(".textSelection(.enabled)"))
    #expect(markdown.components(separatedBy: ".textSelection(.disabled)").count >= 3)
    #expect(markdown.contains("MarkdownInlineLinkInteraction(source:"))
  }
}

import Testing

@testable import OttoApp

@Suite("Visual response presentation")
struct AssistantResponsePresentationTests {
  let diagram =
    "```mermaid\nflowchart LR\nTask --> Feedback\nFeedback --> Memory\nMemory --> Task\n```"

  @Test func echoLearningLoopStaysVisible() {
    let source =
      "Otto learns from feedback.\n\n" + String(repeating: "Supporting detail. ", count: 55)
      + "\n\n" + diagram + "\n\nFeedback changes the next task."
    let result = AssistantResponsePresentation(source)
    #expect(result.hasVisual)
    #expect(!result.hasDetails)
    #expect(result.preview.count == 4)
    #expect(result.fullText == source)
    #expect(result.preview.last?.content == .paragraph("Feedback changes the next task."))
  }

  @Test func explicitOverviewPreservesCaveats() {
    let lead = "Proposed, not yet implemented.\n\n" + diagram + "\n\nYou review each lesson."
    let result = AssistantResponsePresentation(
      lead + "\n\n<!-- otto:details -->\n\nEvidence and details.")
    #expect(result.preview == MarkdownBlockParser.parse(lead))
    #expect(result.hasDetails)
    #expect(!result.fullText.contains("<!-- otto:details -->"))
    #expect(result.fullText.contains("Evidence and details."))
  }

  @Test func detailsContainOnlySupportingContent() {
    let result = AssistantResponsePresentation(
      "Takeaway.\n\n" + diagram + "\n\n<!-- otto:details -->\n\nSupporting evidence."
    )
    #expect(result.supportingBlocks.map(\.content) == [.paragraph("Supporting evidence.")])
    #expect(result.fullText.contains("Takeaway."))
  }

  @Test func legacyDetailsExcludeVisualButRetainEvidenceAndCode() {
    let source = "Takeaway.\n\n" + diagram + "\n\nEvidence.\n\n```swift\nlet evidence = true\n```"
    let result = AssistantResponsePresentation(source)
    #expect(result.supportingBlocks.count == 3)
    #expect(
      result.supportingBlocks.last?.content == .code(language: "swift", code: "let evidence = true")
    )
    #expect(result.fullText == source)
  }

  @Test func shortAnswersNeedNoDisclosure() {
    let result = AssistantResponsePresentation("The meeting starts at three.")
    #expect(!result.hasVisual)
    #expect(!result.hasDetails)
    #expect(result.preview.count == 1)
  }

  @Test func markerInsideCodeIsLiteral() {
    let source = "```html\n<!-- otto:details -->\n```"
    #expect(AssistantResponsePresentation(source).fullText == source)
  }

  @Test func visualBelowDividerIsNotHidden() {
    let result = AssistantResponsePresentation("Overview.\n\n<!-- otto:details -->\n\n" + diagram)
    #expect(result.hasVisual)
    #expect(result.preview.contains { if case .code = $0.content { true } else { false } })
  }

  @Test func comparisonsAndImagesAreVisuals() {
    for source in [
      "| Option | Cost |\n| --- | --- |\n| A | 12 |", "![Updated page](/tmp/page.png)",
    ] {
      #expect(AssistantResponsePresentation(source).hasVisual)
    }
    #expect(!AssistantResponsePresentation("```swift\nlet x = 1\n```").hasVisual)
  }

  @Test func unclosedFenceAndEmptyDividerRetainContent() {
    let code = "```swift\nlet x = 1\n\nlet y = 2"
    #expect(AssistantResponsePresentation(code).fullText == code)
    let result = AssistantResponsePresentation("Hello\n\n<!-- otto:details -->")
    #expect(result.fullText == "Hello")
    #expect(!result.hasDetails)
  }
}

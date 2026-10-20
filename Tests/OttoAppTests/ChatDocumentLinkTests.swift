import Foundation
import Testing

@testable import OttoApp

@Suite("Team document links")
struct ChatDocumentLinkTests {
  @Test("Plans resolve against the document workspace and decode spaces")
  func relativePlan() throws {
    let url = try #require(URL(string: "plans/Muse%20execution%20plan.md#milestones"))
    #expect(
      chatDocumentLinkPath(url, workspaceRoot: "/workspace")
        == "/workspace/plans/Muse execution plan.md")
  }

  @Test("The Research Team's angle-bracket Markdown link reaches the plan file")
  func renderedPlanLink() throws {
    let path =
      "/Users/example/Documents/Muse Workspace/Plans/Muse Context Learning Execution Plan.md"
    let attributed = try AttributedString(markdown: "[Otto execution plan](<\(path)>)")
    let url = try #require(attributed.runs.compactMap(\.link).first)
    #expect(chatDocumentLinkPath(url, workspaceRoot: "/other") == path)
  }

  @Test("Absolute and file links preserve their location and strip line references")
  func absolutePlan() throws {
    for source in ["/workspace/plan.md:12:3", "file:///workspace/plan.md#section"] {
      let url = try #require(URL(string: source))
      #expect(chatDocumentLinkPath(url, workspaceRoot: "/other") == "/workspace/plan.md")
    }
  }

  @Test("External and application links are not treated as files")
  func externalLinks() throws {
    for source in [
      "https://example.com/plan.md", "mailto:team@example.com", "muse://start", "#section",
    ] {
      let url = try #require(URL(string: source))
      #expect(chatDocumentLinkPath(url, workspaceRoot: "/workspace") == nil)
    }
  }
}

import Foundation
import Testing

@testable import OttoApp

@Test func aLinkInATableCellResolvesToItsFile() {
  let root = "/Users/me/Documents/Muse Workspace"
  let row =
    "| \"Right away.\" | [A](</Users/me/Documents/Muse Workspace/Mockups/voice-compare/sentence-1-A.wav>) | [B](</Users/me/Documents/Muse Workspace/Mockups/voice-compare/sentence-1-B.wav>) |"
  let source = "| Sentence | A | B |\n|---|---|---|\n" + row
  let blocks = MarkdownBlockParser.parse(source)
  var found: [String] = []
  for block in blocks {
    guard case .table(_, let rows) = block.content else { continue }
    for cell in rows.flatMap({ $0 }) {
      for run in InlineMarkdownCache.parse(cell).runs {
        if let url = run.link, let path = chatDocumentLinkPath(url, workspaceRoot: root) {
          found.append(path)
        }
      }
    }
  }
  #expect(
    found == [
      "/Users/me/Documents/Muse Workspace/Mockups/voice-compare/sentence-1-A.wav",
      "/Users/me/Documents/Muse Workspace/Mockups/voice-compare/sentence-1-B.wav",
    ], "got \(found)")
}

import Foundation
import OttoModels

/// A deterministic presentation of an answer, independent of provider and conversation surface.
/// The original answer is always retained; the preview is never used as a replacement transcript.
struct AssistantResponsePresentation {
  static let detailsMarker = OttoTranscriptMarkers.detailsMarker
  let fullText: String
  let supportingBlocks: [MarkdownBlock]
  let preview: [MarkdownBlock]
  let hasDetails: Bool
  let hasVisual: Bool

  init(_ source: String) {
    // Only a standalone marker outside a code fence is presentation metadata.
    var fence: String?
    var before: [String] = []
    var after: [String] = []
    var foundMarker = false
    for line in source.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if fence == nil, OttoTranscriptMarkers.detailsMarkers.contains(trimmed) {
        foundMarker = true
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        let token = String(trimmed.prefix(3))
        if fence == token { fence = nil } else if fence == nil { fence = token }
      }
      if foundMarker { after.append(line) } else { before.append(line) }
    }
    let lead = before.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let detail = after.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    fullText = [lead, detail].filter { !$0.isEmpty }.joined(separator: "\n\n")
    let blocks = MarkdownBlockParser.parse(fullText)
    supportingBlocks = MarkdownBlockParser.parse(foundMarker && !detail.isEmpty ? detail : fullText)
      .filter { !Self.isVisual($0.content) }
    hasVisual = blocks.contains { Self.isVisual($0.content) }
    let leading = MarkdownBlockParser.parse(lead)
    if blocks.count == 1, case .email = blocks[0].content,
      !leading.contains(where: { Self.isVisual($0.content) })
    {
      // A legacy letter may have a divider between its subject and body.
      preview = blocks
      hasDetails = false
      return
    }
    if foundMarker, !lead.isEmpty, !detail.isEmpty {
      // A misplaced visual must not disappear behind an agent-authored divider.
      if !MarkdownBlockParser.parse(detail).contains(where: { Self.isVisual($0.content) }) {
        preview = leading
        hasDetails = true
        return
      }
    }
    // Length alone cannot distinguish supporting evidence from the requested deliverable.
    // Keep legacy prose and every composed result visible unless the author marks details.
    preview = blocks
    hasDetails = false
  }

  private static func isVisual(_ block: MarkdownBlockContent) -> Bool {
    switch block {
    case .image, .table, .email, .inbox: true
    case .code(let language, _): language?.lowercased() == "mermaid"
    default: false
    }
  }
}

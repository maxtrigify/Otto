import Foundation
import SwiftUI

/// A large clipboard paste held beside the composer as an attachment chip instead of being typed
/// into the field. SwiftUI's vertical `TextField` re-measures its whole string on every keystroke,
/// so a multi-thousand-line paste made typing crawl. Like Claude Code and Codex, the field stays
/// short and the full text is expanded into the prompt only when it is sent.
struct ChatPastedText: Identifiable, Equatable {
  let id = UUID()
  let text: String
  let lineCount: Int

  init(_ text: String) {
    self.text = text
    lineCount = Self.lineCount(of: text)
  }

  /// Pastes at or above either limit become attachments; anything smaller is pasted normally.
  static let characterThreshold = 1_000
  static let lineThreshold = 15

  static func shouldAttach(_ text: String) -> Bool {
    // UTF-16 length is O(1) on bridged pasteboard strings and close enough for a threshold.
    text.utf16.count >= characterThreshold || lineCount(of: text) >= lineThreshold
  }

  var label: String {
    lineCount > 1 ? "Pasted text · \(lineCount) lines" : "Pasted text · \(text.count) chars"
  }

  /// A short excerpt for the chip's tooltip.
  var preview: String {
    let limit = 280
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  private static func lineCount(of text: String) -> Int {
    let trimmed = text.trimmingCharacters(in: .newlines)
    guard !trimmed.isEmpty else { return 0 }
    return trimmed.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
  }

  // MARK: - Prompt encoding

  private static let openPrefix = "<pasted_text index=\""
  private static let close = "</pasted_text>"

  /// Joins the typed message and each paste into the text the provider receives. Returns nil
  /// when there is nothing to send.
  static func compose(typed: String?, pastes: [ChatPastedText]) -> String? {
    let blocks = pastes.enumerated().map { offset, paste in
      "\(openPrefix)\(offset + 1)\" lines=\"\(paste.lineCount)\">\n\(paste.text)\n\(close)"
    }
    let parts = [typed].compactMap { $0 } + blocks
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// Splits a sent prompt back into the typed message and its pasted blocks so the transcript
  /// can render pastes collapsed. Text that does not match the encoding stays in `text`.
  static func decompose(_ source: String) -> (text: String, pastes: [String]) {
    var pastes: [String] = []
    var remainder = source[...]
    var typed = ""
    while let open = remainder.range(of: openPrefix) {
      guard let headerEnd = remainder[open.upperBound...].range(of: "\">\n"),
        let closing = remainder[headerEnd.upperBound...].range(of: "\n" + close)
      else { break }
      typed += remainder[..<open.lowerBound]
      pastes.append(String(remainder[headerEnd.upperBound..<closing.lowerBound]))
      remainder = remainder[closing.upperBound...]
    }
    typed += remainder
    return (typed.trimmingCharacters(in: .whitespacesAndNewlines), pastes)
  }
}

/// The removable chip a composer shows for each pending paste; hovering previews the text.
struct ChatPastedTextChip: View {
  let paste: ChatPastedText
  var scale: Double = 1
  let foreground: Color
  let background: Color
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 5 * scale) {
      Image(systemName: "doc.plaintext")
        .font(.system(size: max(7, 8 * scale)))
      Text(paste.label)
        .font(.ottoMono(max(6, 7 * scale)))
        .lineLimit(1)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: max(7, 8 * scale)))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(paste.label)")
    }
    .foregroundStyle(foreground)
    .padding(.horizontal, 7 * scale)
    .padding(.vertical, 4 * scale)
    .background(background, in: Capsule())
    .help(paste.preview)
  }
}

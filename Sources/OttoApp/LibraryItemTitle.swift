import Foundation
import OttoModels

/// The name a note or media item shows in Files & notes (issue #86).
///
/// New notes and media are created as "Notes 3" or "Media 1" before an agent fills them in, and
/// that placeholder used to stay on the card for good, so a library of 25 notes read "Notes 1"
/// to "Notes 25". A placeholder now gives way to something the person can recognise: the note's
/// first heading or line, its file name, or the media file's name. A name someone chose is
/// always kept.
enum LibraryItemTitle {
  nonisolated static func title(for node: OttoNode) -> String {
    guard isPlaceholder(node.displayName) else { return node.displayName }
    let derived: String? =
      switch node.content {
      case .markdown(let path, let text):
        firstLine(of: text) ?? fileTitle(path)
      case .media(let source):
        fileTitle(URL(string: source).flatMap { $0.scheme == nil ? nil : $0.path } ?? source)
      default:
        nil
      }
    return derived ?? node.displayName
  }

  /// "Notes 12" and "Media 3" are the names Otto gives before anything is known about the item.
  nonisolated static func isPlaceholder(_ name: String) -> Bool {
    let parts = name.split(separator: " ")
    guard parts.count == 2, parts[1].allSatisfy(\.isNumber) else { return false }
    return parts[0] == "Notes" || parts[0] == "Media"
  }

  /// "plans/q4-launch_notes.md" → "q4 launch notes". Nil for an empty or untitled path.
  nonisolated private static func fileTitle(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let readable = stem.replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !readable.isEmpty, readable.lowercased() != "untitled" else { return nil }
    return readable
  }

  /// The first non-empty line, without Markdown heading marks, cut to a card-sized length.
  nonisolated private static func firstLine(of text: String) -> String? {
    guard
      let line = text.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { !$0.isEmpty })
    else { return nil }
    let stripped = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    // A new note starts as "# Untitled"; that says no more than the placeholder.
    guard !stripped.isEmpty, stripped.lowercased() != "untitled" else { return nil }
    return stripped.count > 60 ? String(stripped.prefix(59)) + "…" : stripped
  }
}

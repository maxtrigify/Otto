import AppKit
import Foundation
import QuickLookUI
import SwiftUI

/// How the work panel shows a file a person picked in the workspace tree.
///
/// The panel used to read every file as UTF-8 text, so opening a screenshot, a screen
/// recording or a voice note ended in "Could not read this file as text." Nothing was wrong
/// with those files: they were never text. Text keeps Otto's editor and Markdown preview;
/// everything else goes to the system previewer, which renders images, movies, sounds, PDFs
/// and documents in place.
enum WorkFilePresentation: Equatable, Sendable {
  case text
  case systemPreview

  /// Extensions the system renders. A file listed here never reaches the editor, even when
  /// its bytes happen to decode.
  static let systemPreviewExtensions: Set<String> = [
    // Pictures
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "icns",
    // Movies and sounds
    "mov", "mp4", "m4v", "webm", "avi", "mkv",
    "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "ogg", "opus",
    // Documents and archives
    "pdf", "epub", "key", "pages", "numbers", "xlsx", "xls", "docx", "doc", "pptx", "ppt",
    "zip", "gz", "tar", "7z", "dmg", "pkg", "sketch", "fig", "psd", "ai",
  ]

  /// Extensions that stay in the editor. Anything else is decided by whether the bytes
  /// decode as UTF-8, so an uncommon source file still opens as text.
  static let textExtensions: Set<String> = [
    "md", "markdown", "mdx", "txt", "text", "rst", "adoc", "org", "tex", "bib",
    "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "rs", "go",
    "py", "rb", "php", "pl", "lua", "r", "jl", "scala", "dart", "ex", "exs",
    "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
    "json", "jsonc", "json5", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "properties",
    "xml", "plist", "strings", "stringsdict", "xcconfig", "entitlements", "pbxproj",
    "html", "htm", "css", "scss", "sass", "less",
    "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "astro",
    "sql", "graphql", "gql", "proto", "csv", "tsv", "log", "diff", "patch",
    "gradle", "cmake", "mk",
  ]

  /// Decides how one path is shown. `decodesAsText` is the result of reading the file, so
  /// binaries with an unknown extension still reach the previewer instead of the editor.
  static func forPath(_ path: String, decodesAsText: Bool) -> WorkFilePresentation {
    let fileExtension = (path as NSString).pathExtension.lowercased()
    if systemPreviewExtensions.contains(fileExtension) { return .systemPreview }
    if textExtensions.contains(fileExtension) {
      return decodesAsText ? .text : .systemPreview
    }
    return decodesAsText ? .text : .systemPreview
  }

  /// Reads a file as UTF-8 text, or nil when it is missing, binary, or not valid text.
  static func decodeText(atPath path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    guard !data.isEmpty else { return "" }
    // A NUL byte in the first block is the cheapest reliable sign of a binary file; some
    // office formats are mostly ASCII and would otherwise decode to garbage.
    guard !data.prefix(8 * 1024).contains(0) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// Shows one file the way Finder's Quick Look does — a picture, a movie with its own
/// transport controls, a sound, a PDF — without leaving Otto or handing the file to another
/// app. The view closes its preview item when SwiftUI takes it away.
struct WorkFilePreviewer: NSViewRepresentable {
  let path: String

  func makeNSView(context: Context) -> NSView {
    guard let view = QLPreviewView(frame: .zero, style: .normal) else {
      return NSTextField(labelWithString: "Nothing on this Mac can preview this file.")
    }
    view.autostarts = false
    view.shouldCloseWithWindow = false
    view.previewItem = URL(fileURLWithPath: path) as NSURL
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard let preview = view as? QLPreviewView else { return }
    let url = URL(fileURLWithPath: path)
    guard (preview.previewItem as? URL)?.standardizedFileURL != url.standardizedFileURL else {
      return
    }
    preview.previewItem = url as NSURL
  }

  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    (view as? QLPreviewView)?.close()
  }
}

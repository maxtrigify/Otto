import AppKit
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// How the Files panel shows a file. Text opens in the editor; photos are drawn directly and
/// videos, sounds and PDFs get a Quick Look preview, instead of "Could not read this file as
/// text" (issue #73).
enum WorkFilePreviewKind: Equatable {
  case text
  case image
  case media

  nonisolated static func kind(forPath path: String) -> WorkFilePreviewKind {
    let ext = (path as NSString).pathExtension.lowercased()
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .text }
    // SVG is an image to Quick Look but is also text people edit, so keep it in the editor.
    if type.conforms(to: .svg) { return .text }
    if type.conforms(to: .image) { return .image }
    let mediaTypes: [UTType] = [.audiovisualContent, .audio, .movie, .pdf]
    return mediaTypes.contains { type.conforms(to: $0) } ? .media : .text
  }

  /// Like `kind(forPath:)`, but a file the editor would open that is not readable text (a
  /// Word document, a zip, a binary with an unknown extension) goes to Quick Look instead of
  /// "Could not read this file as text." Idea from PR #74.
  nonisolated static func kind(forPath path: String, decodesAsText: Bool) -> WorkFilePreviewKind {
    let kind = kind(forPath: path)
    return kind == .text && !decodesAsText ? .media : kind
  }
}

/// A photo drawn to fit the panel.
struct WorkFileImagePreview: View {
  let path: String

  var body: some View {
    if let image = NSImage(contentsOfFile: path) {
      Image(nsImage: image)
        .resizable()
        .scaledToFit()
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView("Could not open this image", systemImage: "photo")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

/// A Quick Look preview of one file: images, video and audio (with playback controls) and PDFs.
struct WorkFileQuickLookPreview: NSViewRepresentable {
  let path: String

  func makeNSView(context: Context) -> QLPreviewView {
    let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    view.autostarts = false
    view.shouldCloseWithWindow = true
    view.previewItem = URL(fileURLWithPath: path) as NSURL
    return view
  }

  func updateNSView(_ view: QLPreviewView, context: Context) {
    let url = URL(fileURLWithPath: path)
    if (view.previewItem as? URL) != url {
      view.previewItem = url as NSURL
    }
  }

  static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
    view.close()
  }
}

import AppKit
import Foundation

struct ChatImageAttachment: Identifiable, Equatable {
  let id = UUID()
  let path: String
  let name: String
}

/// Home and Chat save images in the owning workspace before referencing them in a prompt.
@MainActor
struct ChatImageAttachmentStore {
  let directory: String
  static let maximumImageBytes: Int64 = 50 * 1_048_576

  enum AttachmentError: LocalizedError {
    case notAFile, fileTooLarge, unreadableImage, emptyClipboard

    var errorDescription: String? {
      switch self {
      case .notAFile: "Only image files can be attached."
      case .fileTooLarge: "The image exceeds the 50 MB attachment limit."
      case .unreadableImage: "Couldn’t read the image from the clipboard."
      case .emptyClipboard: "The clipboard does not contain a supported image."
      }
    }
  }

  func paste(from pasteboard: NSPasteboard) throws -> [ChatImageAttachment] {
    let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "webp", "heic"]
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
      let images = urls.filter { extensions.contains($0.pathExtension.lowercased()) }
      if !images.isEmpty { return try images.map(saveFile) }
    }
    guard let image = NSImage(pasteboard: pasteboard) else { throw AttachmentError.emptyClipboard }
    return [try saveImage(image)]
  }

  func saveFile(_ url: URL) throws -> ChatImageAttachment {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw AttachmentError.notAFile }
    guard Int64(values.fileSize ?? 0) <= Self.maximumImageBytes else {
      throw AttachmentError.fileTooLarge
    }
    let destination = try destination(preferredName: url.lastPathComponent)
    try FileManager.default.copyItem(atPath: url.path, toPath: destination.path)
    return ChatImageAttachment(path: destination.path, name: url.lastPathComponent)
  }

  func saveImage(_ image: NSImage) throws -> ChatImageAttachment {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let data = bitmap.representation(using: .png, properties: [:])
    else { throw AttachmentError.unreadableImage }
    guard Int64(data.count) <= Self.maximumImageBytes else { throw AttachmentError.fileTooLarge }
    let destination = try destination(preferredName: "pasted-image.png")
    try data.write(to: destination, options: .atomic)
    return ChatImageAttachment(path: destination.path, name: "Pasted image")
  }

  private func destination(preferredName: String) throws -> URL {
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = preferredName.replacingOccurrences(of: "/", with: "-")
    return folder.appending(path: "\(Int(Date.now.timeIntervalSince1970))-\(UUID())-\(name)")
  }

  static func compose(typed: String?, pastes: [ChatPastedText], images: [ChatImageAttachment])
    -> String?
  {
    let text = ChatPastedText.compose(typed: typed, pastes: pastes)
    guard text != nil || !images.isEmpty else { return nil }
    let base = text ?? "Please look at the attached image\(images.count == 1 ? "" : "s")."
    return AgentConversationBody.promptText(base, referencing: images.map(\.path))
  }
}

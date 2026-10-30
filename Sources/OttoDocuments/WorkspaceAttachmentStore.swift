import Foundation
import OttoModels

public enum AttachmentImportError: Error, LocalizedError, Equatable, Sendable {
  case missingFile(String)
  case directoryNotSupported(String)
  case symbolicLinkNotSupported(String)
  case fileTooLarge(String, Int64)
  case copyFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingFile(let name): "Attachment does not exist: \(name)"
    case .directoryNotSupported(let name): "Folders cannot be attached: \(name)"
    case .symbolicLinkNotSupported(let name): "Symbolic links cannot be attached: \(name)"
    case .fileTooLarge(let name, let limit):
      "Attachment \(name) exceeds the \(limit / 1_048_576) MB limit"
    case .copyFailed(let name): "Could not copy attachment: \(name)"
    }
  }
}

public actor WorkspaceAttachmentStore {
  private let rootURL: URL
  private let maximumBytes: Int64

  public init(rootPath: String, maximumBytes: Int64 = 50 * 1_048_576) {
    self.rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    self.maximumBytes = maximumBytes
  }

  public func importFiles(_ sourceURLs: [URL]) throws -> [OttoAttachment] {
    var imported: [OttoAttachment] = []
    do {
      for url in sourceURLs { imported.append(try importFile(url)) }
      return imported
    } catch {
      for attachment in imported {
        let importedURL = rootURL.appending(path: attachment.relativePath)
        try? FileManager.default.removeItem(at: importedURL.deletingLastPathComponent())
      }
      throw error
    }
  }

  private func importFile(_ sourceURL: URL) throws -> OttoAttachment {
    #if canImport(Darwin)
      let accessed = sourceURL.startAccessingSecurityScopedResource()
      defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
    #endif

    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(forKeys: [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey,
      ])
    } catch {
      throw AttachmentImportError.missingFile(sourceURL.lastPathComponent)
    }
    let name = sanitizedName(values.name ?? sourceURL.lastPathComponent)
    guard values.isDirectory != true else {
      throw AttachmentImportError.directoryNotSupported(name)
    }
    guard values.isSymbolicLink != true else {
      throw AttachmentImportError.symbolicLinkNotSupported(name)
    }
    guard values.isRegularFile == true else { throw AttachmentImportError.missingFile(name) }
    let size = Int64(values.fileSize ?? 0)
    guard size <= maximumBytes else {
      throw AttachmentImportError.fileTooLarge(name, maximumBytes)
    }

    let id = UUID()
    let relativePath = ".otto/attachments/\(id.uuidString.lowercased())/\(name)"
    let destination = rootURL.appending(path: relativePath).standardizedFileURL
    let directory = destination.deletingLastPathComponent()
    let temporary = directory.appending(path: ".importing-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: sourceURL, to: temporary)
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw AttachmentImportError.copyFailed(name)
    }
    return OttoAttachment(
      id: id,
      displayName: name,
      relativePath: relativePath,
      mimeType: mimeType(for: destination.pathExtension),
      byteCount: size
    )
  }

  private func sanitizedName(_ value: String) -> String {
    let disallowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ ")).inverted
    let cleaned = value.components(separatedBy: disallowed).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String((cleaned.isEmpty ? "attachment" : cleaned).prefix(160))
  }

  private func mimeType(for extensionValue: String) -> String {
    switch extensionValue.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "pdf": "application/pdf"
    case "md", "markdown": "text/markdown"
    case "txt", "log": "text/plain"
    case "mp3": "audio/mpeg"
    case "wav": "audio/wav"
    case "m4a": "audio/mp4"
    default: "application/octet-stream"
    }
  }
}

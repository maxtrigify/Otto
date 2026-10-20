import Foundation
import OttoModels

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

/// Copy explicitly embedded local images before saving a reply, so temporary tool output survives.
/// Remote URLs remain remote; code examples are never imported.
enum ChatImageStore {
  static func preservingImages(in text: String, workingDirectory: String) -> String {
    let root = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let storage = root.appendingPathComponent(".otto/chat-attachments/replies", isDirectory: true)
    var fence: String?
    return text.components(separatedBy: "\n").map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        let token = String(trimmed.prefix(3))
        if fence == token { fence = nil } else if fence == nil { fence = token }
        return line
      }
      guard fence == nil, let reference = ChatImageReference.parse(line),
        let source = ChatImageReference.localURL(reference.target, directory: root),
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"].contains(
          source.pathExtension.lowercased())
      else { return line }
      do {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0,
          size <= 50 * 1024 * 1024
        else { return line }
        let data = try Data(contentsOf: source)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = storage.appendingPathComponent(digest).appendingPathExtension(
          source.pathExtension.lowercased())
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
          try data.write(to: destination, options: .atomic)
        }
        return "![\(reference.alt)](<\(destination.path)>)"
      } catch {
        // Preserve the original reference, allowing an unavailable image to remain visible as such.
        return line
      }
    }.joined(separator: "\n")
  }
}

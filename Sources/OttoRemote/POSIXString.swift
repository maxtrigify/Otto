import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif os(Windows)
  import WinSDK
#endif

func decodeRemoteCString(_ pointer: UnsafePointer<CChar>) -> String {
  let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
  return String(
    decoding: UnsafeBufferPointer(start: bytes, count: strlen(pointer)),
    as: UTF8.self
  )
}

/// File-system operations the remote daemon needs, with one spelling per platform family.
/// Windows has no `realpath`, `chmod` or overwriting `rename`, and its paths compare
/// case-insensitively with either separator.
enum RemotePath {
  /// The symlink-free absolute path of an existing item, or nil when nothing is there.
  static func resolve(_ path: String) -> String? {
    #if os(Windows)
      let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      return url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } }
        ?? url.path
    #else
      guard let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return decodeRemoteCString(resolved)
    #endif
  }

  static func isAbsolute(_ path: String) -> Bool {
    #if os(Windows)
      let scalars = Array(path.unicodeScalars)
      if path.hasPrefix("\\\\") || path.hasPrefix("//") { return true }
      return scalars.count >= 3 && CharacterSet.letters.contains(scalars[0])
        && scalars[1] == ":" && (scalars[2] == "\\" || scalars[2] == "/")
    #else
      return path.hasPrefix("/")
    #endif
  }

  /// Whether `candidate` is `root` or inside it.
  static func contains(_ candidate: String, root: String) -> Bool {
    #if os(Windows)
      let normalize = { (path: String) in
        path.replacingOccurrences(of: "/", with: "\\").lowercased()
      }
      let candidate = normalize(candidate)
      let root = normalize(root)
      return candidate == root || candidate.hasPrefix(root.hasSuffix("\\") ? root : root + "\\")
    #else
      return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    #endif
  }

  /// Owner-only permissions on POSIX; Windows relies on the user profile's ACLs.
  static func restrict(_ path: String, mode: UInt16) {
    #if !os(Windows)
      _ = chmod(path, mode_t(mode))
    #endif
  }

  /// Atomically moves `source` over `destination`, replacing it if present.
  static func replace(_ source: String, with destination: String) -> Bool {
    #if os(Windows)
      let from = Array(source.utf16) + [0]
      let to = Array(destination.utf16) + [0]
      return MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    #else
      return rename(source, destination) == 0
    #endif
  }

  static func remove(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }
}

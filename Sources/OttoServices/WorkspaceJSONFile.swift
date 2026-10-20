import Foundation

/// Shared atomic JSON envelope used by workspace `.otto/*.json` stores.
enum WorkspaceJSONFile {
  static func load<T: Decodable>(_ type: T.Type, from url: URL, fileManager: FileManager) throws
    -> T?
  {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: Data(contentsOf: url))
  }

  static func save<T: Encodable>(_ value: T, to url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
  }
}

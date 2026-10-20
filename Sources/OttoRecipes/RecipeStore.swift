import Foundation

public struct RecipeRecord: Codable, Sendable, Equatable, Identifiable {
  public var id: String { definition.id }
  public var definition: RecipeDefinition
  public var createdAt: Date
  public var updatedAt: Date

  public init(definition: RecipeDefinition, createdAt: Date = .now, updatedAt: Date = .now) {
    self.definition = definition
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public actor RecipeStore {
  private let directoryURL: URL?
  private var memory: [String: RecipeRecord] = [:]

  public init(directoryURL: URL? = nil) {
    self.directoryURL = directoryURL
  }

  public static func live(fileManager: FileManager = .default) -> RecipeStore {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return RecipeStore(
      directoryURL: base.appending(path: "Otto/Recipes", directoryHint: .isDirectory))
  }

  public func list() throws -> [RecipeRecord] {
    try loadDiskIfNeeded()
    return memory.values.sorted {
      $0.definition.name.localizedCaseInsensitiveCompare($1.definition.name) == .orderedAscending
    }
  }

  public func get(id: String) throws -> RecipeRecord? {
    try loadDiskIfNeeded()
    return memory[id]
  }

  @discardableResult
  public func save(_ definition: RecipeDefinition) throws -> RecipeRecord {
    try RecipeValidator.validate(definition)
    try loadDiskIfNeeded()
    let now = Date()
    let record = RecipeRecord(
      definition: definition,
      createdAt: memory[definition.id]?.createdAt ?? now,
      updatedAt: now
    )
    memory[definition.id] = record
    guard let directoryURL else { return record }
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(
      to: directoryURL.appending(path: "\(definition.id).json"),
      options: .atomic
    )
    return record
  }

  private func loadDiskIfNeeded() throws {
    guard memory.isEmpty, let directoryURL else { return }
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    for url in try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter({ $0.pathExtension == "json" }) {
      let record = try decoder.decode(RecipeRecord.self, from: Data(contentsOf: url))
      try RecipeValidator.validate(record.definition)
      memory[record.id] = record
    }
  }
}

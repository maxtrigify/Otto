import Foundation

/// An organisational scope, never a filesystem permission grant.
public struct ConversationProject: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var isLegacyWorkspace: Bool
  public var sourceFolders: [String]
  /// Provider account new work in this project runs on unless an agent overrides it.
  public var defaultAccountID: UUID?
  /// Nil behaves as `.ask`: Otto never moves project work to another account on its own.
  public var usageLimitPolicy: ProviderUsageLimitPolicy?
  /// Account used by `.switchAccount`, and offered first when asking.
  public var usageLimitFallbackAccountID: UUID?
  public init(
    id: UUID = UUID(), name: String, isLegacyWorkspace: Bool = false, sourceFolders: [String] = [],
    defaultAccountID: UUID? = nil, usageLimitPolicy: ProviderUsageLimitPolicy? = nil,
    usageLimitFallbackAccountID: UUID? = nil
  ) {
    self.id = id
    self.name = name
    self.isLegacyWorkspace = isLegacyWorkspace
    self.sourceFolders = sourceFolders
    self.defaultAccountID = defaultAccountID
    self.usageLimitPolicy = usageLimitPolicy
    self.usageLimitFallbackAccountID = usageLimitFallbackAccountID
  }
  private enum CodingKeys: String, CodingKey {
    case id, name, isLegacyWorkspace, sourceFolders, defaultAccountID, usageLimitPolicy
    case usageLimitFallbackAccountID
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    isLegacyWorkspace = try values.decode(Bool.self, forKey: .isLegacyWorkspace)
    sourceFolders = try values.decodeIfPresent([String].self, forKey: .sourceFolders) ?? []
    defaultAccountID = try values.decodeIfPresent(UUID.self, forKey: .defaultAccountID)
    usageLimitPolicy = try? values.decodeIfPresent(
      ProviderUsageLimitPolicy.self, forKey: .usageLimitPolicy)
    usageLimitFallbackAccountID = try values.decodeIfPresent(
      UUID.self, forKey: .usageLimitFallbackAccountID)
  }
}

/// A value snapshot: later channel selections cannot mutate a dispatched assignment.
public struct ConversationProjectContext: Codable, Equatable, Sendable {
  public var projectID: UUID?
  public var name: String
  public var sourceFolders: [String]
  public init(projectID: UUID? = nil, name: String = "Unassigned", sourceFolders: [String] = []) {
    self.projectID = projectID
    self.name = name
    self.sourceFolders = sourceFolders
  }
  private enum CodingKeys: String, CodingKey { case projectID, name, sourceFolders }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    projectID = try values.decodeIfPresent(UUID.self, forKey: .projectID)
    name = try values.decode(String.self, forKey: .name)
    sourceFolders = try values.decodeIfPresent([String].self, forKey: .sourceFolders) ?? []
  }
  public var attribution: String { "[Project: \(name); \(projectID?.uuidString ?? "unassigned")]" }
}

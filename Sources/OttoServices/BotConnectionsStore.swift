#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels

private struct PersistedAllowlist: Codable {
  var profileID: UUID
  var integrationIDs: [String]
}

private struct PersistedBotConnections: Codable {
  var schemaVersion: Int
  var integrations: [BotIntegration]
  var allowlists: [PersistedAllowlist]
  var archivedAllowlists: [PersistedAllowlist]?
}

/// Workspace-level integration registry. Credentials stay in Keychain; this file
/// stores display names and keychain references only.
@MainActor
public final class BotConnectionsStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var integrations: [BotIntegration] = []
  /// profileID → integration IDs the profile may use.
  @Published public private(set) var allowlists: [UUID: [String]] = [:]
  @Published public private(set) var archivedAllowlists: [UUID: [String]] = [:]
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-connections.json")
    load()
  }

  public func integration(id: String) -> BotIntegration? {
    integrations.first { $0.id == id }
  }

  @discardableResult
  public func save(_ candidate: BotIntegration) throws -> BotIntegration {
    var record = candidate
    record.id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
    record.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
    record.keychainRef = record.keychainRef.trimmingCharacters(in: .whitespacesAndNewlines)
    try Self.validate(record)
    record.updatedAt = .now
    if let index = integrations.firstIndex(where: { $0.id == record.id }) {
      record.createdAt = integrations[index].createdAt
      integrations[index] = record
    } else {
      integrations.append(record)
    }
    try persist()
    return record
  }

  public func setAllowlist(profileID: UUID, integrationIDs: [String]) throws {
    let known = Set(integrations.map(\.id))
    allowlists[profileID] = integrationIDs.filter { known.contains($0) }
    try persist()
  }

  public func archiveAllowlist(profileID: UUID) throws {
    archivedAllowlists[profileID] = allowlists[profileID] ?? []
    allowlists[profileID] = []
    try persist()
  }

  public func restoreAllowlist(profileID: UUID) throws {
    allowlists[profileID] = archivedAllowlists.removeValue(forKey: profileID) ?? []
    try persist()
  }

  /// Removes policy created for an aggregate that failed before commit.
  func removeAllowlistForCreationRollback(profileID: UUID) throws {
    allowlists.removeValue(forKey: profileID)
    try persist()
  }

  /// Effective access is the intersection of the profile allowlist and the
  /// workspace grant (the registry itself). A bot never exceeds the user's Otto grant.
  public func effectiveAccess(profileID: UUID, grantedIntegrationIDs: Set<String>) -> Set<String> {
    let requested = Set(allowlists[profileID] ?? [])
    let registered = Set(integrations.map(\.id))
    return requested.intersection(grantedIntegrationIDs).intersection(registered)
  }

  public func isAuthorized(profileID: UUID, integrationID: String, granted: Set<String>) -> Bool {
    effectiveAccess(profileID: profileID, grantedIntegrationIDs: granted).contains(integrationID)
  }

  static func validate(_ record: BotIntegration) throws {
    guard !record.id.isEmpty, !record.name.isEmpty, !record.keychainRef.isEmpty else {
      throw BotStoreError.credentialInRegistry
    }
    let blob = "\(record.id) \(record.name) \(record.keychainRef)"
    if MemoryLikeSecret.firstMarker(in: blob) != nil {
      throw BotStoreError.credentialInRegistry
    }
    if record.keychainRef.lowercased().contains("secret")
      || record.keychainRef.hasPrefix("sk-")
      || record.keychainRef.count > 120
    {
      throw BotStoreError.credentialInRegistry
    }
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotConnections.self, from: fileURL, fileManager: fileManager)
      {
        integrations = persisted.integrations
        allowlists = Dictionary(
          uniqueKeysWithValues: persisted.allowlists.map { ($0.profileID, $0.integrationIDs) })
        archivedAllowlists = Dictionary(
          uniqueKeysWithValues: (persisted.archivedAllowlists ?? []).map {
            ($0.profileID, $0.integrationIDs)
          })
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot connections: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotConnections(
          schemaVersion: Self.currentSchemaVersion,
          integrations: integrations,
          allowlists: allowlists.map {
            PersistedAllowlist(profileID: $0.key, integrationIDs: $0.value)
          },
          archivedAllowlists: archivedAllowlists.map {
            PersistedAllowlist(profileID: $0.key, integrationIDs: $0.value)
          }
        ),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot connections: \(error.localizedDescription)"
      throw error
    }
  }
}

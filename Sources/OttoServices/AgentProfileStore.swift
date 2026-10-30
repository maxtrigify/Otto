#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels

private struct PersistedAgentProfiles: Codable {
  var schemaVersion: Int
  var profiles: [AgentProfile]
}

/// Workspace-scoped reusable agent identities. Runtime execution remains profile-optional.
@MainActor
public final class AgentProfileStore: ObservableObject {
  @Published public private(set) var profiles: [AgentProfile] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/agent-profiles.json")
    load()
  }

  public func profile(id: UUID) -> AgentProfile? { profiles.first { $0.id == id } }
  public var activeProfiles: [AgentProfile] { profiles.filter { !$0.isArchived } }

  public func exactMatch(name: String) -> AgentProfile? {
    let normalized = Self.normalizedName(name)
    return activeProfiles.first { Self.normalizedName($0.name) == normalized }
  }

  @discardableResult
  public func save(_ candidate: AgentProfile) throws -> AgentProfile {
    var profile = candidate
    profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    profile.role = profile.role.trimmingCharacters(in: .whitespacesAndNewlines)
    if let title = profile.jobTitle {
      let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
      profile.jobTitle = trimmed.isEmpty ? nil : trimmed
    }
    profile.instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    try validate(profile)

    let now = Date.now
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profile.createdAt = profiles[index].createdAt
      profile.revision = max(profiles[index].revision + 1, profile.revision)
      profile.updatedAt = now
      profiles[index] = profile
    } else {
      profile.revision = max(1, profile.revision)
      profile.createdAt = now
      profile.updatedAt = now
      profiles.append(profile)
    }
    profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    try persist()
    return profile
  }

  public func delete(id: UUID) throws {
    profiles.removeAll { $0.id == id }
    try persist()
  }

  @discardableResult
  public func archive(id: UUID, at date: Date = .now) throws -> AgentProfile {
    guard var profile = profile(id: id) else { throw BotStoreError.profileNotFound }
    if profile.archivedAt == nil {
      profile.archivedAt = date
      profile = try save(profile)
    }
    return profile
  }

  @discardableResult
  public func restore(id: UUID) throws -> AgentProfile {
    guard var profile = profile(id: id) else { throw BotStoreError.profileNotFound }
    profile.archivedAt = nil
    return try save(profile)
  }

  private func validate(_ profile: AgentProfile) throws {
    guard !profile.name.isEmpty else { throw AgentProfileValidationError.emptyName }
    guard profile.name.count <= 80 else { throw AgentProfileValidationError.nameTooLong }
    if let title = profile.jobTitle, title.count > 80 {
      throw AgentProfileValidationError.jobTitleTooLong
    }
    guard !profile.instructions.isEmpty else { throw AgentProfileValidationError.emptyInstructions }
    guard profile.provider != .shell else {
      throw AgentProfileValidationError.unsupportedProvider
    }
    guard profile.executionStrategy.isSupported(by: profile.provider) else {
      throw AgentProfileValidationError.unsupportedExecutionStrategy
    }
    guard
      !profiles.contains(where: {
        !profile.isArchived && !$0.isArchived && $0.id != profile.id
          && Self.normalizedName($0.name) == Self.normalizedName(profile.name)
      })
    else { throw AgentProfileValidationError.duplicateName }
  }

  private func load() {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let persisted = try decoder.decode(PersistedAgentProfiles.self, from: data)
      profiles = persisted.profiles.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load custom agents: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try encoder.encode(
        PersistedAgentProfiles(
          schemaVersion: AgentProfile.currentSchemaVersion, profiles: profiles))
      try data.write(to: fileURL, options: .atomic)
      persistenceError = nil
    } catch {
      persistenceError = "Could not save custom agents: \(error.localizedDescription)"
      throw error
    }
  }

  private static func normalizedName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }
}

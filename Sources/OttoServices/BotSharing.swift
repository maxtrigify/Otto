import Foundation
import OttoModels

public enum BotShareManifestError: Error, LocalizedError, Equatable, Sendable {
  case unsupportedSchema(Int)
  case invalidField(String)
  case privateData(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let version):
      "Bot share schema \(version) is not supported."
    case .invalidField(let field):
      "Bot share field \(field) is invalid."
    case .privateData(let marker):
      "Bot shares cannot contain private data (\(marker))."
    }
  }
}

extension ApplicationServices {
  public func exportBotShareManifest(profileID: UUID) throws -> BotShareManifest {
    guard let profile = agentProfiles.profile(id: profileID) else {
      throw BotStoreError.profileNotFound
    }
    let appearance = botAppearance.appearance(for: profileID).map {
      BotShareAppearance(
        avatarRef: $0.avatarRef,
        petRef: $0.petRef,
        shape: $0.shape,
        colorHex: $0.colorHex,
        initials: $0.initials
      )
    }
    let connectionSuggestions = (botConnections.allowlists[profileID] ?? []).compactMap {
      botConnections.integration(id: $0)?.id
    }
    let manifest = BotShareManifest(
      name: profile.name,
      role: profile.jobTitle ?? profile.role,
      instructions: profile.instructions,
      executionDefaults: BotShareExecutionDefaults(
        provider: profile.provider,
        model: profile.model,
        effort: profile.effort,
        permissionMode: profile.permissionMode,
        executionStrategy: profile.executionStrategy,
        isolatedWorktree: profile.isolatedWorktree
      ),
      appearance: appearance,
      suggestedSkillIDs: profile.skillIDs,
      suggestedConnectionIDs: connectionSuggestions
    )
    try Self.validateBotShareManifest(manifest)
    return manifest
  }

  @discardableResult
  public func importBotShareManifest(_ manifest: BotShareManifest) throws -> AgentProfile {
    try Self.validateBotShareManifest(manifest)
    let appearance = manifest.appearance
    // Suggested connections are intentionally not assigned. Importing a share can never grant
    // access; the user must connect and explicitly allow each public identifier afterwards.
    return try createBot(
      BotCreationRequest(
        name: manifest.name,
        role: manifest.role,
        responsibility: manifest.role,
        instructions: manifest.instructions,
        provider: manifest.executionDefaults.provider,
        model: manifest.executionDefaults.model,
        effort: manifest.executionDefaults.effort,
        permissionMode: manifest.executionDefaults.permissionMode,
        executionStrategy: manifest.executionDefaults.executionStrategy,
        isolatedWorktree: manifest.executionDefaults.isolatedWorktree,
        skillIDs: manifest.suggestedSkillIDs,
        avatarRef: appearance?.avatarRef,
        shape: appearance?.shape,
        colorHex: appearance?.colorHex
      ))
  }

  public nonisolated static func validateBotShareManifest(_ manifest: BotShareManifest) throws {
    guard manifest.schemaVersion == BotShareManifest.currentSchemaVersion else {
      throw BotShareManifestError.unsupportedSchema(manifest.schemaVersion)
    }
    let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let role = manifest.role.trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = manifest.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 80 else {
      throw BotShareManifestError.invalidField("name")
    }
    guard !role.isEmpty, role.count <= 240 else {
      throw BotShareManifestError.invalidField("role")
    }
    guard !instructions.isEmpty, instructions.count <= 32_000 else {
      throw BotShareManifestError.invalidField("instructions")
    }
    let identifiers = manifest.suggestedSkillIDs + manifest.suggestedConnectionIDs
    guard identifiers.count <= 128,
      identifiers.allSatisfy({
        !$0.isEmpty && $0.count <= 120
          && $0.allSatisfy { $0.isLetter || $0.isNumber || "._-:/".contains($0) }
      })
    else { throw BotShareManifestError.invalidField("suggestions") }

    let encoded = try JSONEncoder().encode(manifest)
    let text =
      ([name, role, instructions] + identifiers).joined(separator: "\n").lowercased()
      + String(decoding: encoded, as: UTF8.self).lowercased()
    let privateMarkers = [
      "api_key", "apikey", "access_token", "password", "bearer ", "sk-ant-", "sk-proj-",
      "ghp_", "github_pat_", "xoxb-", "xapp-", "private key-----", "/users/", "file://",
      "cookie", "session_id",
    ]
    if let marker = privateMarkers.first(where: { text.contains($0) }) {
      throw BotShareManifestError.privateData(marker)
    }
  }
}

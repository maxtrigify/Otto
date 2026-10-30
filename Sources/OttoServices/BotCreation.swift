import Foundation
import OttoModels

public enum BotCreationStage: String, CaseIterable, Sendable {
  case profile
  case channel
  case notes
  case connectionPolicy
  case appearance
}

public enum BotCreationError: Error, LocalizedError, Equatable, Sendable {
  case emptyResponsibility
  case profileAlreadyExists(UUID)

  public var errorDescription: String? {
    switch self {
    case .emptyResponsibility: "Describe what this bot is responsible for."
    case .profileAlreadyExists: "A bot with this identity already exists."
    }
  }
}

public struct BotCreationRequest: Sendable {
  public var profileID: UUID?
  public var name: String
  public var role: String
  public var responsibility: String
  public var persistResponsibilityAsJobTitle: Bool
  public var instructions: String?
  public var provider: AgentProvider
  public var accountID: UUID?
  public var model: String?
  public var effort: String?
  public var permissionMode: String
  public var executionStrategy: AgentExecutionStrategy
  public var isolatedWorktree: Bool
  public var subagents: [BotSubagentConfiguration]?
  public var skillIDs: [String]
  public var avatarRef: String?
  public var shape: String?
  public var colorHex: String?
  public var photoSourceURL: URL?

  public init(
    profileID: UUID? = nil,
    name: String,
    role: String = "",
    responsibility: String,
    persistResponsibilityAsJobTitle: Bool = true,
    instructions: String? = nil,
    provider: AgentProvider = .codex,
    accountID: UUID? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String = "workspaceWrite",
    executionStrategy: AgentExecutionStrategy = .direct,
    isolatedWorktree: Bool = false,
    skillIDs: [String] = [],
    subagents: [BotSubagentConfiguration]? = nil,
    avatarRef: String? = nil,
    shape: String? = nil,
    colorHex: String? = nil,
    photoSourceURL: URL? = nil
  ) {
    self.profileID = profileID
    self.name = name
    self.role = role
    self.responsibility = responsibility
    self.persistResponsibilityAsJobTitle = persistResponsibilityAsJobTitle
    self.instructions = instructions
    self.provider = provider
    self.accountID = accountID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.executionStrategy = executionStrategy
    self.isolatedWorktree = isolatedWorktree
    self.subagents = subagents
    self.skillIDs = skillIDs
    self.avatarRef = avatarRef
    self.shape = shape
    self.colorHex = colorHex
    self.photoSourceURL = photoSourceURL
  }
}

extension ApplicationServices {
  /// Creates every durable part of a bot before publishing it to the UI. `checkpoint` is a
  /// diagnostics/failure-injection seam used to prove compensation at every transition.
  @discardableResult
  public func createBot(
    _ request: BotCreationRequest,
    checkpoint: ((BotCreationStage) throws -> Void)? = nil
  ) throws -> AgentProfile {
    try validateBotSubagents(request.subagents ?? [])
    if let accountID = request.accountID, providerAccounts.account(id: accountID) == nil {
      throw ProviderAccountStore.AccountError.unknownAccount(accountID.uuidString)
    }
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let responsibility = request.responsibility.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !responsibility.isEmpty else { throw BotCreationError.emptyResponsibility }
    if let profileID = request.profileID, agentProfiles.profile(id: profileID) != nil {
      throw BotCreationError.profileAlreadyExists(profileID)
    }

    let suppliedInstructions = request.instructions?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions =
      suppliedInstructions.flatMap { $0.isEmpty ? nil : $0 }
      ?? Self.generatedBotInstructions(name: name, responsibility: responsibility)
    var profile = AgentProfile(
      id: request.profileID ?? UUID(),
      name: name,
      role: request.role,
      jobTitle: request.persistResponsibilityAsJobTitle ? responsibility : nil,
      instructions: instructions,
      provider: request.provider,
      accountID: request.accountID,
      model: request.model,
      effort: request.effort,
      permissionMode: request.permissionMode,
      executionStrategy: request.executionStrategy,
      isolatedWorktree: request.isolatedWorktree,
      skillIDs: request.skillIDs
    )
    profile.subagents = request.subagents
    var importedPhotoPath: String?

    do {
      let saved = try agentProfiles.save(profile)
      try checkpoint?(.profile)

      _ = try botChannels.ensureCanonicalChannel(for: saved.id)
      try checkpoint?(.channel)

      _ = try botNotes.ensure(profileID: saved.id)
      try checkpoint?(.notes)

      try botConnections.setAllowlist(profileID: saved.id, integrationIDs: [])
      try checkpoint?(.connectionPolicy)

      if let photoSourceURL = request.photoSourceURL {
        importedPhotoPath = try importBotPhoto(from: photoSourceURL, profileID: saved.id)
      }
      let defaults = Self.generatedAppearance(profileID: saved.id, name: saved.name)
      _ = try botAppearance.save(
        BotAppearance(
          profileID: saved.id,
          avatarRef: request.avatarRef ?? defaults.avatarRef,
          shape: request.shape ?? defaults.shape,
          colorHex: request.colorHex ?? defaults.colorHex,
          initials: defaults.initials,
          photoRelativePath: importedPhotoPath
        ))
      try checkpoint?(.appearance)

      objectWillChange.send()
      return saved
    } catch {
      try? botAppearance.remove(profileID: profile.id)
      if let importedPhotoPath { try? removeBotPhoto(relativePath: importedPhotoPath) }
      try? botConnections.removeAllowlistForCreationRollback(profileID: profile.id)
      try? botNotes.removeForCreationRollback(profileID: profile.id)
      try? botChannels.removeForCreationRollback(profileID: profile.id)
      try? agentProfiles.delete(id: profile.id)
      try? connectorAccess.removeProfile(profile.id)
      objectWillChange.send()
      throw error
    }
  }

  static func generatedBotInstructions(name: String, responsibility: String) -> String {
    """
    You are \(name), responsible for \(responsibility).

    Work toward concrete outcomes, keep the user informed when a decision is genuinely needed, \
    and never expand your permissions or connected-app access on your own.
    """
  }

  private static func generatedAppearance(profileID: UUID, name: String) -> BotAppearance {
    let seed = profileID.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
    let colors = ["#397b69", "#ad6a66", "#526b8e", "#a46e21", "#087f83"]
    let initials = name.split(whereSeparator: \.isWhitespace).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
    return BotAppearance(
      profileID: profileID,
      avatarRef: BotFamily.accessory(reference: nil, name: name).reference,
      shape: "rounded",
      colorHex: colors[seed % colors.count],
      initials: initials.isEmpty ? String(name.prefix(2)).uppercased() : initials
    )
  }

  private func removeBotPhoto(relativePath: String) throws {
    let url = URL(fileURLWithPath: workspacePath).appending(path: relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

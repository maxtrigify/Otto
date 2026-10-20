import Foundation
import OttoModels
import OttoRuntime
import OttoTools

/// Everything the bot editor can change after hiring. Appearance fields are cosmetic and never
/// bump the profile revision; the rest go through the profile store.
public struct BotEditRequest: Sendable {
  public var profileID: UUID
  public var name: String
  public var responsibility: String
  public var instructions: String
  public var provider: AgentProvider
  public var accountID: UUID?
  public var model: String?
  public var effort: String?
  public var permissionMode: String
  public var avatarRef: String?
  public var shape: String?
  public var colorHex: String?
  /// A new photo to import. Takes precedence over `existingPhotoPath`.
  public var photoSourceURL: URL?
  /// The photo to keep. Nil removes the current photo.
  public var existingPhotoPath: String?

  public init(
    profileID: UUID,
    name: String,
    responsibility: String,
    instructions: String,
    provider: AgentProvider,
    accountID: UUID? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String,
    avatarRef: String? = nil,
    shape: String? = nil,
    colorHex: String? = nil,
    photoSourceURL: URL? = nil,
    existingPhotoPath: String? = nil
  ) {
    self.profileID = profileID
    self.name = name
    self.responsibility = responsibility
    self.instructions = instructions
    self.provider = provider
    self.accountID = accountID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.avatarRef = avatarRef
    self.shape = shape
    self.colorHex = colorHex
    self.photoSourceURL = photoSourceURL
    self.existingPhotoPath = existingPhotoPath
  }
}

extension ApplicationServices {
  /// Saves an edited bot and brings its open sessions in line. A harness change cannot be
  /// applied to a running provider process, so those sessions are closed and the next open
  /// launches fresh on the new harness; memory, notes and the channel are kept.
  @discardableResult
  public func updateBot(_ request: BotEditRequest) throws -> AgentProfile {
    guard var profile = agentProfiles.profile(id: request.profileID), !profile.isArchived else {
      throw BotStoreError.profileNotFound
    }
    if let accountID = request.accountID, providerAccounts.account(id: accountID) == nil {
      throw ProviderAccountStore.AccountError.unknownAccount(accountID.uuidString)
    }
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let responsibility = request.responsibility.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !responsibility.isEmpty else { throw BotCreationError.emptyResponsibility }
    let instructions = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)

    let previous = profile
    profile.name = name
    profile.jobTitle = responsibility
    profile.instructions =
      instructions.isEmpty
      ? Self.generatedBotInstructions(name: name, responsibility: responsibility)
      : instructions
    profile.provider = request.provider
    profile.accountID = request.accountID
    profile.model = request.model
    profile.effort = request.effort
    profile.permissionMode = request.permissionMode
    let saved = try saveAgentProfile(profile)

    var photoPath = request.existingPhotoPath
    if let source = request.photoSourceURL {
      photoPath = try importBotPhoto(from: source, profileID: saved.id)
    }
    let current = botAppearance.appearance(for: saved.id)
    let initials = saved.name.split(whereSeparator: \.isWhitespace).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
    _ = try botAppearance.save(
      BotAppearance(
        profileID: saved.id,
        avatarRef: request.avatarRef ?? current?.avatarRef,
        petRef: current?.petRef,
        shape: request.shape ?? current?.shape,
        colorHex: request.colorHex ?? current?.colorHex,
        initials: initials.isEmpty ? String(saved.name.prefix(2)).uppercased() : initials,
        photoRelativePath: photoPath
      ))

    syncBotSessions(from: previous, to: saved)
    objectWillChange.send()
    return saved
  }

  private func syncBotSessions(from previous: AgentProfile, to saved: AgentProfile) {
    let runtimeChanged =
      previous.model != saved.model || previous.effort != saved.effort
      || previous.permissionMode != saved.permissionMode || previous.accountID != saved.accountID
    for canvas in store.snapshot.canvases {
      for node in canvas.nodes {
        guard var definition = node.agentDefinition, definition.profileID == saved.id else {
          continue
        }
        if previous.provider != saved.provider {
          agentLoopTasks[node.id]?.cancel()
          agentLoopTasks[node.id] = nil
          Task { [supervisor] in _ = try? await supervisor.stopIfPresent(agentID: node.id) }
          store.dispatch(.closeNode(node.id), targetCanvasID: canvas.id)
          continue
        }
        definition.model = saved.model
        definition.effort = saved.effort
        definition.permissionMode = saved.permissionMode
        definition.accountID = saved.accountID.flatMap { providerAccounts.account(id: $0)?.id }
        store.dispatch(
          .setAgentDefinition(id: node.id, definition: definition), targetCanvasID: canvas.id)
        if node.displayName != saved.name {
          store.dispatch(.renameNode(id: node.id, name: saved.name), targetCanvasID: canvas.id)
        }
        if runtimeChanged, let snapshot = fleet[node.id], snapshot.exitCode == nil,
          snapshot.executionMode == .interactiveProvider
        {
          Task { try? await restart(agentID: node.id) }
        }
      }
    }
  }

  /// Edits every part of a team: name, brief, members, lead and the permission its turns run
  /// with. Membership changes apply to the live session so the room keeps its history.
  @discardableResult
  public func updateTeam(
    channelID: UUID,
    name: String?,
    instructions: String?,
    memberProfileIDs: [UUID],
    orchestratorProfileID: UUID?,
    permissionMode: AgentPermissionMode?
  ) throws -> BotChannel {
    guard var channel = botChannels.channel(id: channelID),
      channel.kind == .group,
      !channel.archived
    else {
      throw BotStoreError.channelArchived
    }
    let members = Array(Set(memberProfileIDs)).sorted { $0.uuidString < $1.uuidString }
    guard members.count >= BotGroupSession.minMembers else { throw BotStoreError.groupTooSmall }
    guard members.count <= BotGroupSession.maxMembers else { throw BotStoreError.groupTooLarge }
    let membersChanged = Set(members) != Set(channel.memberProfileIDs)
    if membersChanged, isTeamRunning(channelID: channelID) {
      throw ToolRegistryError.invalidInput(
        "Wait for the team to finish before changing its members")
    }
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBrief = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    let lead = orchestratorProfileID.flatMap { members.contains($0) ? $0 : nil } ?? members[0]
    channel.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
    channel.instructions = (trimmedBrief?.isEmpty ?? true) ? nil : trimmedBrief
    channel.memberProfileIDs = members
    channel.orchestratorProfileID = lead
    channel.profileID = lead
    channel.permissionMode = permissionMode?.rawValue
    let saved = try botChannels.save(channel)
    if membersChanged {
      if botGroups.latestSession(forChannel: channelID) == nil {
        _ = try botGroups.open(members: members, channelID: channelID)
      } else {
        try botGroups.updateMembers(channelID: channelID, members: members)
      }
    }
    objectWillChange.send()
    return saved
  }
}

import Combine
import Foundation
import OttoModels

private struct PersistedBotChannels: Codable {
  var schemaVersion: Int
  var channels: [BotChannel]
}

/// Maps a saved profile to its canonical durable conversation. Task sessions remain
/// independent; the botChannel is the pinned inbox for that profile.
@MainActor
public final class BotChannelStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var channels: [BotChannel] = []
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath)
      .appending(path: ".otto/bot-channels.json")
    load()
  }

  public func channel(id: UUID) -> BotChannel? { channels.first { $0.id == id } }

  public func canonicalChannel(for profileID: UUID) -> BotChannel? {
    channels.first { $0.profileID == profileID && $0.kind == .botChannel }
  }

  @discardableResult
  public func ensureCanonicalChannel(for profileID: UUID) throws -> BotChannel {
    if let existing = canonicalChannel(for: profileID) { return existing }
    return try save(
      BotChannel(profileID: profileID, kind: .botChannel, memberProfileIDs: [profileID]))
  }

  @discardableResult
  public func bindNode(profileID: UUID, nodeID: UUID) throws -> BotChannel {
    var channel = try ensureCanonicalChannel(for: profileID)
    channel.nodeID = nodeID
    return try save(channel)
  }

  @discardableResult
  public func save(_ candidate: BotChannel) throws -> BotChannel {
    var channel = candidate
    let now = Date.now
    if let index = channels.firstIndex(where: { $0.id == channel.id }) {
      channel.createdAt = channels[index].createdAt
      channel.revision = max(channels[index].revision + 1, channel.revision)
      channel.updatedAt = now
      channels[index] = channel
    } else {
      channel.revision = max(1, channel.revision)
      channel.createdAt = now
      channel.updatedAt = now
      channels.append(channel)
    }
    try persist()
    return channel
  }

  /// Deleting a profile archives its channel. Sessions stay recoverable; nothing is
  /// silently destroyed.
  @discardableResult
  public func archive(profileID: UUID, at date: Date = .now) throws -> [BotChannel] {
    var archived: [BotChannel] = []
    for index in channels.indices
    where channels[index].profileID == profileID
      || channels[index].memberProfileIDs.contains(profileID)
    {
      if channels[index].archived {
        guard channels[index].archivedByProfileIDs != nil else { continue }
        if channels[index].archivedByProfileIDs?.contains(profileID) == false {
          channels[index].archivedByProfileIDs?.append(profileID)
          channels[index].revision += 1
          channels[index].updatedAt = date
          archived.append(channels[index])
        }
        continue
      }
      channels[index].archived = true
      channels[index].archivedAt = date
      channels[index].archivedByProfileIDs = [profileID]
      channels[index].revision += 1
      channels[index].updatedAt = date
      archived.append(channels[index])
    }
    if !archived.isEmpty { try persist() }
    return archived
  }

  @discardableResult
  public func restore(profileID: UUID, at date: Date = .now) throws -> [BotChannel] {
    var restored: [BotChannel] = []
    for index in channels.indices
    where channels[index].profileID == profileID
      || channels[index].memberProfileIDs.contains(profileID)
    {
      guard var blockers = channels[index].archivedByProfileIDs,
        blockers.contains(profileID)
      else { continue }
      blockers.removeAll { $0 == profileID }
      channels[index].archivedByProfileIDs = blockers.isEmpty ? nil : blockers
      channels[index].archived = !blockers.isEmpty
      if blockers.isEmpty { channels[index].archivedAt = nil }
      channels[index].revision += 1
      channels[index].updatedAt = date
      restored.append(channels[index])
    }
    if !restored.isEmpty { try persist() }
    return restored
  }

  @discardableResult
  public func archive(channelID: UUID, at date: Date = .now) throws -> BotChannel? {
    guard let index = channels.firstIndex(where: { $0.id == channelID }) else { return nil }
    guard !channels[index].archived else { return channels[index] }
    channels[index].archived = true
    channels[index].archivedAt = date
    channels[index].revision += 1
    channels[index].updatedAt = date
    try persist()
    return channels[index]
  }

  /// Compensating delete used only while a new bot aggregate is still being created. Once
  /// creation succeeds, normal user deletion archives channels instead.
  func removeForCreationRollback(profileID: UUID) throws {
    channels.removeAll { $0.profileID == profileID }
    try persist()
  }

  @discardableResult
  public func createGroupChannel(
    memberProfileIDs: [UUID],
    name: String? = nil,
    instructions: String? = nil,
    orchestratorProfileID: UUID? = nil,
    permissionMode: String? = nil
  ) throws -> BotChannel {
    let unique = Array(Set(memberProfileIDs)).sorted { $0.uuidString < $1.uuidString }
    guard unique.count >= BotGroupSession.minMembers else { throw BotStoreError.groupTooSmall }
    guard unique.count <= BotGroupSession.maxMembers else { throw BotStoreError.groupTooLarge }
    let lead = orchestratorProfileID.flatMap { unique.contains($0) ? $0 : nil } ?? unique[0]
    let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedBrief = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
    return try save(
      BotChannel(
        profileID: lead,
        kind: .group,
        memberProfileIDs: unique,
        name: (trimmedName?.isEmpty ?? true) ? nil : trimmedName,
        instructions: (trimmedBrief?.isEmpty ?? true) ? nil : trimmedBrief,
        orchestratorProfileID: lead,
        permissionMode: permissionMode
      ))
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotChannels.self, from: fileURL, fileManager: fileManager)
      {
        channels = persisted.channels
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot channels: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      try WorkspaceJSONFile.save(
        PersistedBotChannels(schemaVersion: Self.currentSchemaVersion, channels: channels),
        to: fileURL,
        fileManager: fileManager
      )
      persistenceError = nil
    } catch {
      persistenceError = "Could not save bot channels: \(error.localizedDescription)"
      throw error
    }
  }
}

import Foundation
import OttoModels
import OttoRuntime
import OttoTools

/// Control-plane group room. No provider owns the room. Caps are the feature:
/// 10 messages per turn, 3 rounds, then the room settles.
@MainActor
public final class BotGroupCoordinator {
  public struct PromptContext: Equatable, Sendable {
    public var summary: String?
    public var recentMessages: [BotGroupMessage]
    public var wasCompacted: Bool { summary?.isEmpty == false }
  }

  public static let promptRecentMessageLimit = 16
  public static let automaticCompactionTokenThreshold = 4_000
  public static let summaryCharacterLimit = 6_000
  private var sessions: [UUID: BotGroupSession] = [:]
  public private(set) var persistenceError: String?
  private let eventBus: OttoEventBus
  private let audit: BotAuditLog
  private let fileURL: URL?
  private let fileManager: FileManager

  public init(
    eventBus: OttoEventBus,
    audit: BotAuditLog,
    workspacePath: String? = nil,
    fileManager: FileManager = .default
  ) {
    self.eventBus = eventBus
    self.audit = audit
    self.fileManager = fileManager
    self.fileURL = workspacePath.map {
      URL(fileURLWithPath: $0, isDirectory: true)
        .appending(path: ".otto/bot-group-sessions.json")
    }
    if let fileURL {
      do {
        if let restored = try WorkspaceJSONFile.load(
          [BotGroupSession].self, from: fileURL, fileManager: fileManager)
        {
          sessions = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        }
      } catch {
        persistenceError = "Could not load team rooms: \(error.localizedDescription)"
      }
    }
  }

  public func session(id: UUID) -> BotGroupSession? { sessions[id] }
  public var allSessions: [BotGroupSession] {
    sessions.values.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func session(forChannel channelID: UUID) -> BotGroupSession? {
    sessions.values.first { $0.channelID == channelID && $0.supersededAt == nil && !$0.settled }
  }

  public func latestSession(forChannel channelID: UUID) -> BotGroupSession? {
    sessions.values.filter { $0.channelID == channelID && $0.supersededAt == nil }.max {
      $0.updatedAt < $1.updatedAt
    }
  }

  /// Applies an edited team roster to the live session so history is kept rather than restarted.
  public func updateMembers(channelID: UUID, members: [UUID]) throws {
    guard var session = latestSession(forChannel: channelID) else { return }
    let unique = Array(Set(members))
    guard unique.count >= BotGroupSession.minMembers else { throw BotStoreError.groupTooSmall }
    guard unique.count <= BotGroupSession.maxMembers else { throw BotStoreError.groupTooLarge }
    session.memberProfileIDs = unique
    session.mentionedProfileIDs.removeAll { !unique.contains($0) }
    try save(session)
  }

  /// Starts a clean conversational context while retaining previous sessions on disk.
  @discardableResult
  public func startNewSession(members: [UUID], channelID: UUID) throws -> BotGroupSession {
    try open(members: members, channelID: channelID)
  }

  public func promptContext(sessionID: UUID) -> PromptContext? {
    guard let session = sessions[sessionID] else { return nil }
    let uncompacted = session.messages.filter {
      guard let boundary = session.contextCompactedAt else { return true }
      return $0.createdAt > boundary
    }
    let summary = [
      session.contextConstraints?.joined(separator: "\n"),
      session.contextDecisions?.joined(separator: "\n"), session.contextSummary,
    ]
    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    return PromptContext(
      summary: summary.isEmpty ? nil : String(summary.prefix(Self.summaryCharacterLimit)),
      recentMessages: boundedRecentMessages(
        Array(uncompacted.suffix(Self.promptRecentMessageLimit)))
    )
  }

  private func boundedRecentMessages(_ messages: [BotGroupMessage]) -> [BotGroupMessage] {
    var remaining = 12_000
    return messages.reversed().compactMap { message in
      guard remaining > 0 else { return nil }
      var bounded = message
      bounded.text = String(message.text.prefix(min(remaining, 4_000)))
      remaining -= bounded.text.count
      return bounded
    }.reversed()
  }

  @discardableResult
  public func compactLatestSession(channelID: UUID) throws -> BotGroupSession {
    guard var session = latestSession(forChannel: channelID) else {
      throw BotStoreError.profileNotFound
    }
    compact(&session, force: true)
    try save(session)
    return session
  }

  public func checkpoint(sessionID: UUID, state: BotTeamCheckpoint?) throws {
    guard var session = sessions[sessionID] else { throw BotStoreError.profileNotFound }
    session.teamCheckpoint = state
    session.updatedAt = .now
    try save(session)
  }

  /// In-flight calls cannot safely be replayed after a host crash. Keep their assignment and
  /// remaining queue on disk, and show a room message asking the user to reconcile the result.
  public func recoverInterruptedTeams(channelID: UUID? = nil) throws {
    if let persistenceError { throw ToolRegistryError.invalidInput(persistenceError) }
    for var session in allSessions
    where session.supersededAt == nil && session.teamCheckpoint?.activeRuntimeID != nil
      && (channelID == nil || session.channelID == channelID)
    {
      guard let assignment = session.teamCheckpoint?.activeAssignment else { continue }
      if !session.needsUser {
        session.messages.append(
          BotGroupMessage(
            author: .bot(assignment.profileID),
            text:
              "@user Otto restarted during this assignment: \(assignment.task)\nIts outcome is uncertain. Check any changes before asking the team to continue."
          ))
      }
      session.needsUser = true
      session.settled = true
      session.updatedAt = .now
      try save(session)
    }
  }

  public func roomMessageTexts(for profileID: UUID) -> Set<String> {
    Set(
      sessions.values
        .filter { $0.memberProfileIDs.contains(profileID) }
        .flatMap(\.messages)
        .compactMap { message in
          guard case .bot = message.author else { return nil }
          return message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    )
  }

  public func roomUserMessageDates(for profileID: UUID) -> [Date] {
    sessions.values
      .filter { $0.memberProfileIDs.contains(profileID) }
      .flatMap(\.messages)
      .compactMap { message in
        guard case .user = message.author else { return nil }
        return message.createdAt
      }
      .sorted()
  }

  private func save(_ session: BotGroupSession) throws {
    if let persistenceError { throw ToolRegistryError.invalidInput(persistenceError) }
    var updated = sessions
    if sessions[session.id] == nil {
      for id in updated.keys where updated[id]?.channelID == session.channelID {
        updated[id]?.supersededAt = session.createdAt
      }
    }
    updated[session.id] = session
    if let fileURL {
      try WorkspaceJSONFile.save(Array(updated.values), to: fileURL, fileManager: fileManager)
    }
    sessions = updated
    eventBus.publish(OttoEvent(type: .botChannelUpdated, channelID: session.channelID))
  }

  @discardableResult
  public func beginTurn(
    members: [UUID], channelID: UUID, mentioned: [UUID]
  ) throws -> BotGroupSession {
    var session: BotGroupSession
    if let existing = latestSession(forChannel: channelID) {
      session = existing
    } else {
      session = try open(members: members, channelID: channelID, mentioned: mentioned)
    }
    session.memberProfileIDs = Array(Set(members))
    session.mentionedProfileIDs = mentioned
    session.round = 0
    session.messagesThisTurn = 0
    session.silentRound = true
    session.settled = false
    session.needsUser = false
    session.teamCheckpoint = nil
    session.updatedAt = .now
    try save(session)
    return session
  }

  @discardableResult
  public func recordUserMessage(
    sessionID: UUID, text: String, messageID: UUID? = nil,
    projectContext: ConversationProjectContext? = nil
  ) throws -> BotGroupSession {
    guard var session = sessions[sessionID] else { throw BotStoreError.profileNotFound }
    session.messages.append(
      BotGroupMessage(
        id: messageID ?? UUID(), author: .user, text: text, projectContext: projectContext))
    compact(&session, force: false)
    session.updatedAt = .now
    try save(session)
    return session
  }

  public func open(
    members: [UUID],
    channelID: UUID,
    mentioned: [UUID] = []
  ) throws -> BotGroupSession {
    let unique = Array(Set(members))
    guard unique.count >= BotGroupSession.minMembers else { throw BotStoreError.groupTooSmall }
    guard unique.count <= BotGroupSession.maxMembers else { throw BotStoreError.groupTooLarge }
    let session = BotGroupSession(
      memberProfileIDs: unique,
      channelID: channelID,
      mentionedProfileIDs: mentioned
    )
    try save(session)
    return session
  }

  /// Bots that should speak this round: mentioned members, or everyone when none mentioned.
  public func respondents(in session: BotGroupSession) -> [UUID] {
    if session.mentionedProfileIDs.isEmpty { return session.memberProfileIDs }
    return session.memberProfileIDs.filter { session.mentionedProfileIDs.contains($0) }
  }

  @discardableResult
  public func recordTurn(
    sessionID: UUID,
    profileID: UUID,
    kind: BotGroupTurnKind,
    text: String,
    speakerName: String? = nil,
    projectContext: ConversationProjectContext? = nil,
    checkpoint: BotTeamCheckpoint? = nil,
    updatesCheckpoint: Bool = false
  ) throws -> BotGroupSession {
    guard var session = sessions[sessionID] else { throw BotStoreError.profileNotFound }
    guard !session.settled else { throw BotStoreError.groupSettled }
    guard session.messagesThisTurn < BotGroupSession.maxMessagesPerTurn else {
      throw BotStoreError.groupCapReached("messages-per-turn")
    }
    if updatesCheckpoint { session.teamCheckpoint = checkpoint }
    let turn = BotGroupTurn(profileID: profileID, kind: kind, text: text)
    if let speakerName {
      var names = session.contextSpeakerNames ?? [:]
      names[profileID] = speakerName
      session.contextSpeakerNames = names
    }
    session.turns.append(turn)
    if kind == .reply {
      session.messages.append(
        BotGroupMessage(author: .bot(profileID), text: text, projectContext: projectContext))
      compact(&session, force: false)
    }
    session.messagesThisTurn += 1
    session.updatedAt = .now
    if kind == .reply { session.silentRound = false }
    if text.localizedCaseInsensitiveContains("@user") {
      session.needsUser = true
      eventBus.publish(
        OttoEvent(
          type: .botNeedsUser,
          nodeID: nil,
          profileID: profileID,
          channelID: session.channelID
        ))
    }
    try save(session)
    audit.record(
      BotInteractionAudit(
        kind: "group.turn",
        senderProfileID: profileID,
        receiverProfileID: nil,
        source: ToolInvocationSource.automation.rawValue,
        succeeded: true
      ))
    return session
  }

  /// Advance one serial round. A full silent round settles the room.
  @discardableResult
  public func completeRound(sessionID: UUID) throws -> BotGroupSession {
    guard var session = sessions[sessionID] else { throw BotStoreError.profileNotFound }
    guard !session.settled else { throw BotStoreError.groupSettled }
    session.round += 1
    session.messagesThisTurn = 0
    if session.silentRound || session.round >= BotGroupSession.maxRounds {
      session.settled = true
    } else {
      session.silentRound = true
    }
    session.updatedAt = .now
    try save(session)
    return session
  }

  private func compact(_ session: inout BotGroupSession, force: Bool) {
    let pending = session.messages.filter {
      guard let boundary = session.contextCompactedAt else { return true }
      return $0.createdAt > boundary
    }
    let estimatedTokens = pending.reduce(0) {
      $0 + max(1, Int(ceil(Double($1.text.count) / 4.0)))
    }
    guard pending.count > Self.promptRecentMessageLimit,
      force || estimatedTokens >= Self.automaticCompactionTokenThreshold
    else { return }

    let compacted = pending.dropLast(Self.promptRecentMessageLimit)
    guard let last = compacted.last else { return }
    let lines = compacted.map { message in
      let label: String
      switch message.author {
      case .user: label = "User"
      case .bot(let profileID):
        label = session.contextSpeakerNames?[profileID] ?? "Bot \(profileID.uuidString.prefix(8))"
      }
      let cap = message.author == .user ? 1_200 : 600
      let cleaned = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")
      let excerpt = cleaned.count <= cap ? cleaned : String(cleaned.prefix(cap)) + "…"
      return
        "\(message.projectContext?.attribution ?? "[Project: legacy room history]") \(label): \(excerpt)"
    }.joined(separator: "\n")
    let combined = [session.contextSummary, lines]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    var boundedLines = combined.components(separatedBy: "\n").map {
      $0.hasPrefix("[Project:") ? $0 : "[Project: legacy room history] " + $0
    }
    while boundedLines.joined(separator: "\n").count > Self.summaryCharacterLimit
      && !boundedLines.isEmpty
    {
      boundedLines.removeFirst()
    }
    session.contextSummary = boundedLines.joined(separator: "\n")
    session.contextCompactedAt = last.createdAt
    let contextMessages = compacted.map { message -> BotContextMessage in
      switch message.author {
      case .user:
        return BotContextMessage(
          id: message.id,
          speaker: (message.projectContext?.attribution ?? "[Project: legacy room history]")
            + " User", text: message.text, createdAt: message.createdAt)
      case .bot(let profileID):
        return BotContextMessage(
          id: message.id,
          speaker: (message.projectContext?.attribution ?? "[Project: legacy room history]") + " "
            + (session.contextSpeakerNames?[profileID]
              ?? "Bot \(profileID.uuidString.prefix(8))"),
          text: message.text,
          createdAt: message.createdAt)
      }
    }
    session.contextDecisions = merged(
      session.contextDecisions, structured(contextMessages, markers: ["decision:", "decided"]))
    session.contextArtifacts = merged(
      session.contextArtifacts,
      structured(contextMessages, markers: ["artifact:", "file:", "https://"]))
    session.contextConstraints = merged(
      session.contextConstraints, structured(contextMessages, markers: ["constraint:", "must "]))
    session.contextRisks = merged(
      session.contextRisks, structured(contextMessages, markers: ["risk:", "blocked", "failure"]))
    session.contextOpenWork = contextMessages.compactMap { message in
      let lower = message.text.lowercased()
      guard lower.contains("owner:") || lower.contains("todo") || lower.contains("will ") else {
        return nil
      }
      return BotOwnedWork(owner: message.speaker, text: String(message.text.prefix(500)))
    }
  }

  private func merged(_ previous: [String]?, _ new: [String]) -> [String] {
    var seen = Set<String>()
    return ((previous ?? []) + new).filter { seen.insert($0).inserted }
  }

  private func structured(_ messages: [BotContextMessage], markers: [String]) -> [String] {
    messages.compactMap { message in
      guard markers.contains(where: message.text.lowercased().contains) else { return nil }
      return "\(message.speaker): \(String(message.text.prefix(500)))"
    }
  }
}

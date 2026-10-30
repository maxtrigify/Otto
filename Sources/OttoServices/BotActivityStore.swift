#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels
import OttoRuntime

private struct PersistedBotActivity: Codable {
  var schemaVersion: Int
  var items: [BotActivityItem]
  var notifications: [BotActivityNotification]
  var streamID: UUID?
  var lastSequence: Int
}

@MainActor
public final class BotActivityStore: ObservableObject {
  public static let currentSchemaVersion = 1
  @Published public private(set) var items: [BotActivityItem] = []
  @Published public private(set) var notifications: [BotActivityNotification] = []
  @Published public private(set) var persistenceError: String?
  private var streamID: UUID?
  public private(set) var lastSequence = 0

  private let fileURL: URL
  private let fileManager: FileManager
  private var observation: Task<Void, Never>?

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/bot-activity.json")
    load()
  }

  public var needsUser: [BotActivityItem] { items.filter { $0.state == .needsUser } }
  public var active: [BotActivityItem] {
    items.filter { $0.state == .working || $0.state == .needsUser }
  }

  public func start(eventBus: OttoEventBus) {
    guard observation == nil else { return }
    beginStream(eventBus.streamID)
    let cursor = lastSequence
    observation = Task { [weak self] in
      for await event in eventBus.stream(afterSequence: cursor) {
        guard !Task.isCancelled else { return }
        self?.consume(event)
      }
    }
  }

  public func stop() {
    observation?.cancel()
    observation = nil
  }

  public func consume(_ event: OttoEvent) {
    if let streamID = event.streamID { beginStream(streamID) }
    guard event.sequence > lastSequence else { return }
    lastSequence = event.sequence
    guard let projected = Self.project(event) else {
      try? persist()
      return
    }
    let previousState = items.first(where: { $0.id == projected.id })?.state
    if let index = items.firstIndex(where: { $0.id == projected.id }) {
      items[index] = projected
    } else {
      items.append(projected)
    }
    items.sort { $0.updatedAt > $1.updatedAt }
    if previousState != projected.state,
      [.needsUser, .completed, .failed].contains(projected.state)
    {
      let key = "\(projected.id):\(projected.state.rawValue):\(event.id)"
      if !notifications.contains(where: { $0.transitionKey == key }) {
        notifications.append(
          BotActivityNotification(
            transitionKey: key, activityID: projected.id, state: projected.state,
            deepLink: projected.deepLink, createdAt: event.timestamp))
      }
    }
    try? persist()
  }

  private func beginStream(_ id: UUID) {
    guard streamID != id else { return }
    streamID = id
    lastSequence = 0
    // A previous process cannot still own these runs. Fresh runtime events replace this state.
    for index in items.indices where items[index].state == .working {
      items[index].state = .failed
      items[index].title = "Work interrupted when Otto restarted"
    }
    try? persist()
  }

  private nonisolated static func project(_ event: OttoEvent) -> BotActivityItem? {
    let state: BotActivityState
    switch event.type {
    case .agentRunStarted: state = .working
    case .botNeedsUser: state = .needsUser
    case .agentRunCompleted, .routineCompleted, .botMessageDelivered: state = .completed
    case .agentRunFailed: state = .failed
    case .agentExited:
      // Process exit is transport cleanup, not a second run outcome. A clean provider exit after
      // `agent.run_completed` must not turn completed work back into a failure.
      guard event.exitCode != 0 else { return nil }
      state = .failed
    default: return nil
    }
    let id: String
    let link: BotActivityDeepLink
    if let runID = event.runID, let routineID = event.routineID {
      id = "routine:\(routineID):\(runID)"
      link = .routine(routineID: routineID, runID: runID)
    } else if let nodeID = event.nodeID {
      id = "agent:\(nodeID)"
      link = .agent(nodeID: nodeID)
    } else if let channelID = event.channelID {
      id = "channel:\(channelID)"
      link =
        event.profileID.map { .bot(profileID: $0, channelID: channelID) }
        ?? .team(channelID: channelID)
    } else if let profileID = event.profileID ?? event.receiverProfileID {
      id = "bot:\(profileID)"
      link = .bot(profileID: profileID, channelID: event.channelID)
    } else {
      return nil
    }
    return BotActivityItem(
      id: id, state: state, title: Self.title(event), profileID: event.profileID,
      channelID: event.channelID, deepLink: link, sourceEventSequence: event.sequence,
      updatedAt: event.timestamp)
  }

  private nonisolated static func title(_ event: OttoEvent) -> String {
    switch event.type {
    case .agentRunStarted: "Work started"
    case .botNeedsUser: "Needs you"
    case .agentRunCompleted: "Work completed"
    case .agentRunFailed, .agentExited: "Work failed"
    case .routineCompleted: "Routine completed"
    case .botMessageDelivered: "Message delivered"
    default: "Activity"
    }
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedBotActivity.self, from: fileURL, fileManager: fileManager)
      {
        items = persisted.items
        notifications = persisted.notifications
        lastSequence = persisted.lastSequence
        streamID = persisted.streamID
      }
      persistenceError = nil
    } catch {
      persistenceError = "Could not load bot activity: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    try WorkspaceJSONFile.save(
      PersistedBotActivity(
        schemaVersion: Self.currentSchemaVersion, items: items,
        notifications: notifications, streamID: streamID, lastSequence: lastSequence),
      to: fileURL, fileManager: fileManager)
  }
}

import Foundation
import OttoModels

private struct PersistedMobileEventJournal: Codable {
  var schemaVersion: Int
  var events: [MobileHostEvent]
}

public actor MobileEventJournal {
  public static let currentSchemaVersion = 1
  private let fileURL: URL
  private let maximumEvents: Int
  private var events: [MobileHostEvent]

  public init(stateDirectory: URL, maximumEvents: Int = 10_000) throws {
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    fileURL = stateDirectory.appending(path: "mobile-events.json")
    self.maximumEvents = max(100, maximumEvents)
    if let data = try? Data(contentsOf: fileURL),
      let value = try? MobileChatCodec.decode(PersistedMobileEventJournal.self, from: data)
    {
      guard value.events.enumerated().allSatisfy({ $0.element.sequence == Int64($0.offset + 1) })
      else { throw RemoteError.journal("Mobile event sequences are not contiguous.") }
      events = value.events
    } else {
      events = []
    }
  }

  @discardableResult
  public func append(
    type: MobileHostEventType, threadID: UUID? = nil, profileID: UUID? = nil,
    correlationID: UUID? = nil, causationID: UUID? = nil, payload: Data? = nil,
    now: Date = .now
  ) throws -> MobileHostEvent {
    guard events.count < maximumEvents else {
      throw RemoteError.resourceLimit("mobile event journal reached its configured limit")
    }
    let event = MobileHostEvent(
      sequence: Int64(events.count + 1),
      timestamp: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000),
      type: type, threadID: threadID, profileID: profileID,
      correlationID: correlationID, causationID: causationID, payload: payload)
    events.append(event)
    try persist()
    return event
  }

  public func page(after sequence: Int64, limit: Int = 500) -> MobileEventPage {
    MobileEventPage(
      events: Array(
        events.lazy.filter { $0.sequence > sequence }.prefix(max(1, min(limit, 1_000)))),
      latestSequence: events.last?.sequence ?? 0)
  }

  private func persist() throws {
    try MobileChatCodec.encode(
      PersistedMobileEventJournal(schemaVersion: Self.currentSchemaVersion, events: events)
    ).write(to: fileURL, options: [.atomic])
  }
}

public struct MobilePushEnvelope: Codable, Equatable, Sendable, Identifiable {
  public var id: String { transitionKey }
  public var transitionKey: String
  public var environmentID: UUID
  public var activityID: String
  public var threadID: UUID?
  public var state: BotActivityState
  public var preview: String?
  public var deepLink: BotActivityDeepLink

  public init(
    transitionKey: String, environmentID: UUID, activityID: String, threadID: UUID?,
    state: BotActivityState, preview: String?, deepLink: BotActivityDeepLink
  ) {
    self.transitionKey = transitionKey
    self.environmentID = environmentID
    self.activityID = activityID
    self.threadID = threadID
    self.state = state
    self.preview = preview
    self.deepLink = deepLink
  }
}

public actor MobilePushProjector {
  private var emitted: Set<String> = []

  public init() {}

  public func project(
    notification: BotActivityNotification, item: BotActivityItem,
    environmentID: UUID, showPreview: Bool
  ) -> MobilePushEnvelope? {
    guard emitted.insert(notification.transitionKey).inserted else { return nil }
    return MobilePushEnvelope(
      transitionKey: notification.transitionKey, environmentID: environmentID,
      activityID: item.id, threadID: item.channelID, state: notification.state,
      preview: showPreview ? item.detail : nil, deepLink: notification.deepLink)
  }
}

public enum MobileMethodAuthorization {
  public static func requiredScope(for method: MobileChatMethod) -> RemoteDeviceScope {
    switch method {
    case .capabilities, .botList, .teamList, .activityList, .activitySubscribe:
      .readActivity
    case .threadList, .threadSnapshot, .threadSubscribe, .attachmentDownload:
      .readThreads
    case .threadCreate, .messageSend, .attachmentPrepareUpload:
      .sendMessages
    case .approvalRespond:
      .respondApprovals
    case .runInterrupt, .runStop:
      .interruptRuns
    case .computerAcquire, .computerInput, .computerHandBack:
      .controlComputer
    case .deviceList:
      .readActivity
    case .deviceRevoke:
      .manageDevices
    }
  }
}

public struct MobileRPCRequest: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var method: MobileChatMethod
  public var params: Data?

  public init(id: UUID = UUID(), method: MobileChatMethod, params: Data? = nil) {
    self.id = id
    self.method = method
    self.params = params
  }
}

public struct MobileRPCResponse: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var result: Data?

  public init(id: UUID, result: Data? = nil) {
    self.id = id
    self.result = result
  }
}

public protocol MobileRPCHandling: Sendable {
  func handle(
    request: MobileRPCRequest, device: RemotePairedDevice
  ) async throws -> MobileRPCResponse
}

public actor MobileHostRPCGateway {
  private let pairing: RemotePairingStore
  private let handler: any MobileRPCHandling

  public init(pairing: RemotePairingStore, handler: any MobileRPCHandling) {
    self.pairing = pairing
    self.handler = handler
  }

  public func call(
    _ request: MobileRPCRequest, deviceID: UUID, credential: String, now: Date = .now
  ) async throws -> MobileRPCResponse {
    let scope = MobileMethodAuthorization.requiredScope(for: request.method)
    let device = try await pairing.authorize(
      deviceID: deviceID, credential: credential, scope: scope, now: now)
    return try await handler.handle(request: request, device: device)
  }
}

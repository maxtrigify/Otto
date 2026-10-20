import Foundation
import OttoModels

public struct OttoMobileNotificationDelivery: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { eventID }
  public var eventID: UUID
  public var threadID: UUID
  public var kind: RunEventNotification
  public var title: String
  public var body: String

  public init(
    eventID: UUID,
    threadID: UUID,
    kind: RunEventNotification,
    title: String,
    body: String
  ) {
    self.eventID = eventID
    self.threadID = threadID
    self.kind = kind
    self.title = title
    self.body = body
  }

  public init?(
    event: RunEvent,
    threadTitle: String
  ) {
    guard event.content.notification != .none else { return nil }
    eventID = event.id
    threadID = event.threadID
    kind = event.content.notification
    title =
      switch kind {
      case .completion: "\(threadTitle) finished"
      case .failure: "\(threadTitle) failed"
      case .needsUser: "\(threadTitle) needs you"
      case .approval: "\(threadTitle) needs approval"
      case .none: "Otto update"
      }
    let fallbackBody =
      switch kind {
      case .completion: "Open Otto to review the result."
      case .failure: "Open Otto to inspect the failure and continue."
      case .needsUser: "Open Otto to answer and keep the run moving."
      case .approval: "Open Otto to review the requested action."
      case .none: ""
      }
    body = event.content.detail ?? fallbackBody
  }
}

public protocol OttoMobileNotificationDelivering: Sendable {
  func deliver(_ notification: OttoMobileNotificationDelivery) async
}

public enum OttoMobileNotificationPermissionState: Equatable, Sendable {
  case unknown
  case authorized
  case denied
  case unavailable
}

public actor OttoMobileNoopNotificationDelivery: OttoMobileNotificationDelivering {
  public init() {}
  public func deliver(_: OttoMobileNotificationDelivery) {}
}

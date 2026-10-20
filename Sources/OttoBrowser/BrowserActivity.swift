import Foundation

public enum BrowserActivityKind: String, Codable, Equatable, Sendable {
  case navigation
  case observation
  case interaction
  case evidence
  case warning
}

public struct BrowserActivityEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var kind: BrowserActivityKind
  public var title: String
  public var detail: String?
  public var succeeded: Bool

  public init(
    id: UUID = UUID(),
    timestamp: Date = .now,
    kind: BrowserActivityKind,
    title: String,
    detail: String? = nil,
    succeeded: Bool = true
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.title = title
    self.detail = detail
    self.succeeded = succeeded
  }
}

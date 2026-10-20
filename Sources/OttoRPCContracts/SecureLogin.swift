import Foundation

/// Dedicated native-to-host input; never place this payload in chat, tools, events, or caches.
public struct SecureLoginInput: Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public enum Action: String, Codable, Sendable { case list, form, fill, click, finish, cancel }
  public var action: Action
  public var requestID: UUID?
  public var revision: UUID?
  public var elementID: String?
  public var value: String?
  public var fields: [String: String]?
  public init(
    action: Action, requestID: UUID? = nil, revision: UUID? = nil, elementID: String? = nil,
    value: String? = nil, fields: [String: String]? = nil
  ) {
    self.action = action
    self.requestID = requestID
    self.revision = revision
    self.elementID = elementID
    self.value = value
    self.fields = fields
  }
  public var description: String { "<secure login input redacted>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["value": "<redacted>"]) }
}

public struct SecureLoginElement: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var label: String
  public var kind: String
  public var purpose: String?
  public init(id: String, label: String, kind: String, purpose: String? = nil) {
    self.id = id
    self.label = label
    self.kind = kind
    self.purpose = purpose
  }
}
public struct SecureLoginRequest: Codable, Sendable, Identifiable, Equatable {
  public var id: UUID
  public var origin: String
  public var expiresAt: Date
  public init(id: UUID, origin: String, expiresAt: Date) {
    self.id = id
    self.origin = origin
    self.expiresAt = expiresAt
  }
}
public struct SecureLoginOutput: Codable, Sendable, Equatable {
  public var requests: [SecureLoginRequest]
  public var revision: UUID?
  public var elements: [SecureLoginElement]
  public var message: String
  public init(
    requests: [SecureLoginRequest] = [], revision: UUID? = nil, elements: [SecureLoginElement] = [],
    message: String = ""
  ) {
    self.requests = requests
    self.revision = revision
    self.elements = elements
    self.message = message
  }
}

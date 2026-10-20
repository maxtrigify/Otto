import Foundation

public struct PrivatePhoneCommand: Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public var action: String
  public var capability: Data?
  public var input: SecureLoginInput?
  public var remember: Bool?
  public var description: String { "<private phone input redacted>" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["input": "<redacted>"]) }
}

public struct PrivatePhoneView: Codable, Sendable {
  public var mode: String
  public var title: String
  public var origin: String
  public var message: String
  public var form: SecureLoginOutput?
  public init(
    mode: String, title: String, origin: String, message: String,
    form: SecureLoginOutput? = nil
  ) {
    self.mode = mode
    self.title = title
    self.origin = origin
    self.message = message
    self.form = form
  }
}

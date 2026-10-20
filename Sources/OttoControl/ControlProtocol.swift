import Foundation
import OttoTools

public enum ControlMethod: String, Codable, Sendable {
  case toolsList = "tools/list"
  case toolsCall = "tools/call"
}

public struct ControlRequest: Codable, Sendable, Equatable {
  public var id: String
  public var method: ControlMethod
  public var token: String
  public var toolName: String?
  public var arguments: JSONValue?
  public var confirmed: Bool
  public var sourceNodeID: UUID?
  public var sourceCanvasID: UUID?
  public var targetCanvasID: UUID?

  public init(
    id: String = UUID().uuidString,
    method: ControlMethod,
    token: String,
    toolName: String? = nil,
    arguments: JSONValue? = nil,
    confirmed: Bool = false,
    sourceNodeID: UUID? = nil,
    sourceCanvasID: UUID? = nil,
    targetCanvasID: UUID? = nil
  ) {
    self.id = id
    self.method = method
    self.token = token
    self.toolName = toolName
    self.arguments = arguments
    self.confirmed = confirmed
    self.sourceNodeID = sourceNodeID
    self.sourceCanvasID = sourceCanvasID
    self.targetCanvasID = targetCanvasID
  }
}

public struct ControlFailure: Codable, Sendable, Equatable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct ControlResponse: Codable, Sendable, Equatable {
  public var id: String
  public var result: JSONValue?
  public var error: ControlFailure?

  public init(id: String, result: JSONValue? = nil, error: ControlFailure? = nil) {
    self.id = id
    self.result = result
    self.error = error
  }
}

public enum ControlProtocolError: Error, LocalizedError, Sendable {
  case socket(String)
  case invalidRequest(String)
  case unauthorized
  case responseTooLarge
  case remote(ControlFailure)

  public var errorDescription: String? {
    switch self {
    case .socket(let message): "Control socket error: \(message)"
    case .invalidRequest(let message): "Invalid control request: \(message)"
    case .unauthorized: "Control token is invalid or expired"
    case .responseTooLarge: "Control message exceeded the one-megabyte limit"
    case .remote(let failure): "Control call failed (\(failure.code)): \(failure.message)"
    }
  }
}

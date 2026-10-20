import Foundation
import OttoControl
import OttoTools

public enum OttoCLIError: Error, LocalizedError, Sendable {
  case usage(String)

  public var errorDescription: String? {
    switch self {
    case .usage(let message): message
    }
  }
}

public struct OttoCLIRunner: Sendable {
  private let client: ControlClient

  public init(client: ControlClient) {
    self.client = client
  }

  public func run(arguments: [String]) throws -> String {
    guard let command = arguments.first else { throw OttoCLIError.usage(Self.usage) }
    switch command {
    case "tools":
      return try runTools(arguments: Array(arguments.dropFirst()))
    case "call":
      return try runCall(arguments: Array(arguments.dropFirst()))
    default:
      throw OttoCLIError.usage("Unknown command: \(command)\n\n\(Self.usage)")
    }
  }

  private func runTools(arguments: [String]) throws -> String {
    guard arguments == ["list"] else { throw OttoCLIError.usage("Usage: ottoctl tools list") }
    let value = try JSONValue.encode(client.listTools())
    return try render(value)
  }

  private func runCall(arguments: [String]) throws -> String {
    guard let name = arguments.first else {
      throw OttoCLIError.usage("Usage: ottoctl call <tool-name> [json-arguments]")
    }
    let input: JSONValue
    if arguments.count > 1 {
      guard let data = arguments[1].data(using: .utf8) else {
        throw OttoCLIError.usage("Arguments must be UTF-8 JSON")
      }
      input = try JSONDecoder().decode(JSONValue.self, from: data)
    } else {
      input = .object([:])
    }
    return try render(client.call(name, arguments: input))
  }

  private func render(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  public static let usage = """
    Usage:
      ottoctl tools list
      ottoctl call <tool-name> [json-arguments]
    """
}

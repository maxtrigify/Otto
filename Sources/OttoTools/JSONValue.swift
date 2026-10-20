import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }
}

extension JSONValue {
  public static func objectSchema(
    properties: [String: JSONValue] = [:],
    required: [String] = [],
    additionalProperties: Bool = false
  ) -> JSONValue {
    var schema: [String: JSONValue] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(additionalProperties),
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
  }

  public static func stringSchema(description: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("string")]
    if let description { schema["description"] = .string(description) }
    return .object(schema)
  }

  public static func numberSchema(description: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("number")]
    if let description { schema["description"] = .string(description) }
    return .object(schema)
  }

  public static func integerSchema(description: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("integer")]
    if let description { schema["description"] = .string(description) }
    return .object(schema)
  }

  public static func booleanSchema(description: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("boolean")]
    if let description { schema["description"] = .string(description) }
    return .object(schema)
  }

  public static func arraySchema(of items: JSONValue, description: String? = nil) -> JSONValue {
    var schema: [String: JSONValue] = ["type": .string("array"), "items": items]
    if let description { schema["description"] = .string(description) }
    return .object(schema)
  }

  public static func encode<T: Encodable & Sendable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder.ottoTools.encode(value)
    return try JSONDecoder.ottoTools.decode(JSONValue.self, from: data)
  }

  public func decode<T: Decodable & Sendable>(_ type: T.Type) throws -> T {
    let data = try JSONEncoder.ottoTools.encode(self)
    return try JSONDecoder.ottoTools.decode(type, from: data)
  }
}

extension JSONEncoder {
  fileprivate static var ottoTools: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var ottoTools: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

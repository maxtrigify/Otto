import Foundation

enum ToolInputSchemaValidator {
  static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "input") throws
  {
    guard case .object(let rules) = schema else { return }

    if case .array(let allowed)? = rules["enum"], !allowed.contains(value) {
      throw ToolRegistryError.invalidInput("\(path) is not one of the allowed values")
    }

    guard let type = rules["type"]?.stringValue else { return }
    switch (type, value) {
    case ("object", .object(let object)):
      let properties: [String: JSONValue]
      if case .object(let declared)? = rules["properties"] {
        properties = declared
      } else {
        properties = [:]
      }

      if case .array(let required)? = rules["required"] {
        for name in required.compactMap(\.stringValue) where object[name] == nil {
          throw ToolRegistryError.invalidInput("\(path).\(name) is required")
        }
      }
      if rules["additionalProperties"] == .bool(false) {
        let unexpected = Set(object.keys).subtracting(properties.keys).sorted()
        if let first = unexpected.first {
          throw ToolRegistryError.invalidInput("\(path).\(first) is not a supported property")
        }
      }
      for (name, child) in object {
        if let childSchema = properties[name] {
          try validate(child, against: childSchema, path: "\(path).\(name)")
        }
      }

    case ("array", .array(let values)):
      if let itemSchema = rules["items"] {
        for (index, item) in values.enumerated() {
          try validate(item, against: itemSchema, path: "\(path)[\(index)]")
        }
      }

    case ("string", .string):
      break
    case ("number", .number(let number)):
      try validateBounds(number, rules: rules, path: path)
    case ("integer", .number(let number)) where number.isFinite && number.rounded() == number:
      try validateBounds(number, rules: rules, path: path)
    case ("boolean", .bool):
      break
    case ("null", .null):
      break
    default:
      throw ToolRegistryError.invalidInput("\(path) must be \(type)")
    }
  }

  private static func validateBounds(
    _ number: Double,
    rules: [String: JSONValue],
    path: String
  ) throws {
    if let minimum = rules["minimum"]?.numberValue, number < minimum {
      throw ToolRegistryError.invalidInput("\(path) must be at least \(minimum)")
    }
    if let maximum = rules["maximum"]?.numberValue, number > maximum {
      throw ToolRegistryError.invalidInput("\(path) must be at most \(maximum)")
    }
  }
}

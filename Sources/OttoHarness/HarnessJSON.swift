import Foundation
import OttoTools

enum HarnessJSON {
  static func value(_ object: Any) throws -> JSONValue {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  static func object(_ value: JSONValue) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }
}

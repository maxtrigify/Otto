import Foundation
import OttoTools

enum HarnessJSON {
  /// Request bodies are written with sorted keys. Swift dictionaries do not keep an order, so
  /// otherwise the same tools and messages serialize differently on every request, and servers
  /// that reuse an unchanged prompt start (llama.cpp, vLLM, Strata, provider prompt caches)
  /// re-read the whole prompt each time.
  static var stableEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  static func value(_ object: Any) throws -> JSONValue {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  static func object(_ value: JSONValue) throws -> Any {
    try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }
}

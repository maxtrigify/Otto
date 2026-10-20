import Foundation

/// The command palette is a projection of the registered tool catalog, never a second list of
/// hand-maintained actions. Keeping the projection here also makes its schema-derived starter
/// input testable without launching SwiftUI.
public enum CommandPaletteCatalog {
  public static func actions(
    from definitions: [ToolDefinition],
    matching query: String = ""
  ) -> [ToolDefinition] {
    let ordered = definitions.filter { !$0.isProviderInternal }.sorted { $0.name < $1.name }
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return ordered }
    return ordered.filter {
      $0.name.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
    }
  }

  public static func inputTemplate(for definition: ToolDefinition) -> String {
    guard case .object(let root) = definition.inputSchema,
      case .object(let properties)? = root["properties"]
    else { return "{}" }

    let required: Set<String>
    if case .array(let values)? = root["required"] {
      required = Set(values.compactMap(\.stringValue))
    } else {
      required = []
    }

    var object: [String: JSONValue] = [:]
    for name in required.sorted() {
      guard case .object(let property)? = properties[name] else { continue }
      switch property["type"]?.stringValue {
      case "number", "integer": object[name] = .number(0)
      case "boolean": object[name] = .bool(false)
      case "array": object[name] = .array([])
      case "object": object[name] = .object([:])
      default: object[name] = .string("")
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(JSONValue.object(object))) ?? Data("{}".utf8)
    return String(decoding: data, as: UTF8.self)
  }
}

import Foundation
import OttoModels

public enum ReferenceResolution: Sendable, Equatable {
  case resolved(UUID)
  case ambiguous([UUID])
  case notFound
}

public enum ReferenceResolver {
  public static func resolve(_ reference: String, nodes: [OttoNode]) -> ReferenceResolution {
    let normalized = normalize(reference)
    let activeNodes = nodes.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt { return lhs.zIndex < rhs.zIndex }
      return lhs.createdAt < rhs.createdAt
    }

    let exact = activeNodes.filter { normalize($0.displayName) == normalized }
    if exact.count == 1, let id = exact.first?.id { return .resolved(id) }
    if exact.count > 1 { return .ambiguous(exact.map(\.id)) }

    if let ordinal = ordinal(in: normalized) {
      let kind: NodeKind? = normalized.contains("agent") ? .agent : nil
      let candidates =
        kind.map { expected in activeNodes.filter { $0.kind == expected } } ?? activeNodes
      if candidates.indices.contains(ordinal) { return .resolved(candidates[ordinal].id) }
    }

    let partial = activeNodes.filter { normalize($0.displayName).contains(normalized) }
    if partial.count == 1, let id = partial.first?.id { return .resolved(id) }
    if partial.count > 1 { return .ambiguous(partial.map(\.id)) }
    return .notFound
  }

  private static func normalize(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func ordinal(in value: String) -> Int? {
    let mappings: [(String, Int)] = [
      ("first", 0), ("1st", 0), ("second", 1), ("2nd", 1), ("third", 2), ("3rd", 2),
      ("fourth", 3), ("4th", 3),
    ]
    return mappings.first(where: { value.contains($0.0) })?.1
  }
}

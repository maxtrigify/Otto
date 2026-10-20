import Foundation

public enum DocumentExternalChangeDecision: Equatable, Sendable {
  case apply(String)
  case conflict(externalText: String)
}

public enum DocumentConflictPolicy {
  public static func decide(
    draft: String,
    baseline: String,
    isEditing: Bool,
    externalText: String
  ) -> DocumentExternalChangeDecision {
    if isEditing, draft != baseline, externalText != draft {
      return .conflict(externalText: externalText)
    }
    return .apply(externalText)
  }
}

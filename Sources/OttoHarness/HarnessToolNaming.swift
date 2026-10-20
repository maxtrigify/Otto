import Foundation

public enum HarnessToolNaming {
  /// Provider-safe name to canonical Otto tool name. The same mapping is used at request and
  /// execution boundaries so providers never get to choose a different tool by punctuation.
  public static func safeNames(_ tools: [HarnessTool]) -> [String: String] {
    var result: [String: String] = [:]
    for tool in tools {
      let base = tool.name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
      var candidate = String(base.prefix(56))
      if candidate.first?.isNumber == true { candidate = "tool_\(candidate)" }
      if candidate.isEmpty { candidate = "tool" }
      let original = candidate
      var suffix = 2
      while result[candidate] != nil {
        candidate = "\(original)_\(suffix)"
        suffix += 1
      }
      result[candidate] = tool.name
    }
    return result
  }
}

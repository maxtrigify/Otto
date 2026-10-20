import Foundation

/// Untrusted content must not become durable, automatically injected instructions.
/// This provenance gate quarantines external material; it does not certify its truth.
public enum MemorySourcePolicy {
  public static let untrustedPrefixes = [
    "web:", "browser:", "email:", "inbox:", "url:", "http://", "https://", "bot-message:",
  ]

  public static func confidence(for sources: [String]) -> MemoryConfidence {
    sources.contains { source in
      let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return untrustedPrefixes.contains { normalized.hasPrefix($0) }
    } ? .proposed : .confirmed
  }
}

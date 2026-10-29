import Foundation
import OttoModels

public enum ProviderCompatibilityState: String, Codable, Sendable, Equatable {
  case supported
  case untested
  case unsupported
}

public struct ProviderCompatibilityResult: Codable, Sendable, Equatable {
  public var state: ProviderCompatibilityState
  public var detail: String

  public init(state: ProviderCompatibilityState, detail: String) {
    self.state = state
    self.detail = detail
  }
}

public enum ProviderCompatibilityPolicy {
  /// Dynamic workflows landed in Claude Code 2.1.154. A nil result means the provider did not
  /// report a parseable version, so callers may launch with the same caution as other untested
  /// provider versions rather than disabling a potentially supported installation.
  public static func supportsClaudeDynamicWorkflows(reportedVersion: String) -> Bool? {
    guard let version = SemanticVersion(reportedVersion) else { return nil }
    return version >= SemanticVersion(2, 1, 154)
  }

  public static func evaluate(
    provider: AgentProvider,
    reportedVersion: String
  ) -> ProviderCompatibilityResult {
    if provider == .shell {
      return ProviderCompatibilityResult(
        state: .supported,
        detail: "Uses the configured macOS login shell."
      )
    }
    if provider == .openAI {
      return ProviderCompatibilityResult(
        state: .supported,
        detail: "Uses Otto's owned harness with direct OpenAI, Anthropic, xAI, or Moonshot models."
      )
    }
    if provider == .hermes {
      return ProviderCompatibilityResult(
        state: .untested,
        detail:
          "Hermes launches through its supported CLI or gateway protocol; version compatibility is checked at connection time."
      )
    }

    // Cursor stamps calendar builds ("2026.08.04-aaa8809"), not semver, so the shared parser
    // below would classify every install as unparseable. The CLI self-updates and keeps its
    // documented flag surface stable across builds, so a well-formed build stamp is supported.
    if provider == .cursor {
      let isCalendarBuild =
        reportedVersion.prefix(4).allSatisfy(\.isNumber) && reportedVersion.contains(".")
      return ProviderCompatibilityResult(
        state: isCalendarBuild ? .supported : .untested,
        detail: isCalendarBuild
          ? "Tested with Cursor CLI calendar builds from 2026.08."
          : "Otto could not read this Cursor build stamp; launch remains available with caution."
      )
    }

    guard let version = SemanticVersion(reportedVersion) else {
      return ProviderCompatibilityResult(
        state: .untested,
        detail: "Otto could not parse this provider version; launch remains available with caution."
      )
    }

    let bounds: (minimum: SemanticVersion, nextUntested: SemanticVersion)
    switch provider {
    case .claudeCode:
      bounds = (SemanticVersion(2, 1, 0), SemanticVersion(3, 0, 0))
    case .codex:
      bounds = (SemanticVersion(0, 100, 0), SemanticVersion(1, 0, 0))
    case .openAI:
      preconditionFailure("OpenAI API compatibility is handled above")
    case .kimi:
      // Kimi Code CLI is pre-1.0 and ships often. Otto drives it through print mode with
      // stream-json I/O, --session resume, and --mcp-config, which is the flag surface
      // documented for 0.34; older builds are rejected rather than launched blind.
      bounds = (SemanticVersion(0, 34, 0), SemanticVersion(1, 0, 0))
    case .openCode:
      // OpenCode ships continuously. Otto drives it through `run --format json` with `--session`
      // resume and an OPENCODE_CONFIG_CONTENT injection, which is the surface documented for
      // 1.18; older builds are rejected rather than launched blind.
      bounds = (SemanticVersion(1, 18, 0), SemanticVersion(2, 0, 0))
    case .pi:
      // Pi 1.0 (the @earendil-works/pi-coding-agent package) is the first release with
      // `--mode json`, `--session-id`, `--approve`, `--tools` allowlists and built-in MCP, which
      // is the surface Otto drives. The deprecated 0.x @mariozechner package lacks `--approve`
      // and MCP and is rejected rather than launched blind.
      bounds = (SemanticVersion(1, 0, 0), SemanticVersion(2, 0, 0))
    case .grok:
      // Grok Build TUI 1.0 ships `-p` headless, `streaming-messages-json`, `--resume` by session
      // id, `--permission-mode`, `--sandbox`, and project `.grok/config.toml` MCP. Older 0.x
      // builds are rejected rather than launched blind.
      bounds = (SemanticVersion(1, 0, 0), SemanticVersion(2, 0, 0))
    case .cursor:
      preconditionFailure("Cursor compatibility is handled above")
    case .hermes:
      preconditionFailure("Hermes compatibility is handled above")
    case .shell:
      preconditionFailure("Shell compatibility is handled above")
    }

    if version < bounds.minimum {
      return ProviderCompatibilityResult(
        state: .unsupported,
        detail:
          "Update \(provider.rawValue) to \(bounds.minimum.description) or newer before launching it from Otto."
      )
    }
    if version >= bounds.nextUntested {
      return ProviderCompatibilityResult(
        state: .untested,
        detail:
          "This newer \(provider.rawValue) version is outside Otto's tested range; launch remains available with caution."
      )
    }
    return ProviderCompatibilityResult(
      state: .supported,
      detail:
        "Tested with \(provider.rawValue) \(bounds.minimum.description)–<\(bounds.nextUntested.description)."
    )
  }
}

private struct SemanticVersion: Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int

  init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  init?(_ reportedVersion: String) {
    let components = reportedVersion.split { !$0.isNumber && $0 != "." }
    guard let candidate = components.first(where: { $0.contains(".") }) else { return nil }
    let numbers = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard numbers.count >= 2,
      let major = Int(numbers[0]),
      let minor = Int(numbers[1]),
      let patch = numbers.count > 2 ? Int(numbers[2]) : 0
    else { return nil }
    self.init(major, minor, patch)
  }

  var description: String { "\(major).\(minor).\(patch)" }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

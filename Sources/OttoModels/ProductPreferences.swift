import Foundation

/// Stable preference keys shared by the app UI and typed control-plane tools.
public enum OttoPreferenceKey {
  public static let latestSelectedTheme = "otto.appearance.latestSelectedTheme"
  public static let fontScale = "otto.appearance.fontScale"
  public static let matteOpacity = "otto.appearance.matteOpacity"
  public static let agentNamingMode = "otto.agents.naming.mode"
  public static let agentCustomNames = "otto.agents.naming.customNames"
  public static let agentDefaultView = "otto.agents.defaultView"
  public static let claudePermissionMode = "otto.agents.permissions.claudeCode"
  public static let codexPermissionMode = "otto.agents.permissions.codex"
  public static let hermesPermissionMode = "otto.agents.permissions.hermes"
  public static let cursorPermissionMode = "otto.agents.permissions.cursor"
  public static let kimiPermissionMode = "otto.agents.permissions.kimi"
  public static let openCodePermissionMode = "otto.agents.permissions.openCode"
  public static let grokPermissionMode = "otto.agents.permissions.grok"
  public static let shellPermissionMode = "otto.agents.permissions.shell"
  public static let hermesConnectionMode = "otto.agents.hermes.connectionMode"
  public static let hermesRemoteURL = "otto.agents.hermes.remoteURL"
  public static let hermesRemoteProfile = "otto.agents.hermes.remoteProfile"
  public static let hermesRemoteWorkingDirectory = "otto.agents.hermes.remoteWorkingDirectory"
  public static let hermesSessionTokenSecret = "agents.hermes.sessionToken"
  public static let onDeviceWorkTitles = "otto.summarizer.onDeviceWorkTitles"
}

public enum AgentDefaultView: String, Codable, CaseIterable, Sendable {
  case chat
  case terminal

  public var presentationMode: NodePresentationMode {
    switch self {
    case .chat: .conversation
    case .terminal: .terminal
    }
  }

  public static func load(from defaults: UserDefaults = .standard) -> Self {
    Self(rawValue: defaults.string(forKey: OttoPreferenceKey.agentDefaultView) ?? "") ?? .chat
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: OttoPreferenceKey.agentDefaultView)
  }
}

public enum HermesConnectionMode: String, Codable, CaseIterable, Sendable {
  case local
  case remote
}

public struct HermesConnectionConfiguration: Codable, Equatable, Sendable {
  public var mode: HermesConnectionMode
  public var remoteURL: String
  public var remoteProfile: String
  public var remoteWorkingDirectory: String

  public init(
    mode: HermesConnectionMode = .local,
    remoteURL: String = "",
    remoteProfile: String = "",
    remoteWorkingDirectory: String = ""
  ) {
    self.mode = mode
    self.remoteURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    self.remoteProfile = remoteProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    self.remoteWorkingDirectory = remoteWorkingDirectory.trimmingCharacters(
      in: .whitespacesAndNewlines)
  }

  public static func load(from defaults: UserDefaults = .standard) -> Self {
    Self(
      mode: HermesConnectionMode(
        rawValue: defaults.string(forKey: OttoPreferenceKey.hermesConnectionMode) ?? "")
        ?? .local,
      remoteURL: defaults.string(forKey: OttoPreferenceKey.hermesRemoteURL) ?? "",
      remoteProfile: defaults.string(forKey: OttoPreferenceKey.hermesRemoteProfile) ?? "",
      remoteWorkingDirectory: defaults.string(
        forKey: OttoPreferenceKey.hermesRemoteWorkingDirectory) ?? ""
    )
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: OttoPreferenceKey.hermesConnectionMode)
    defaults.set(remoteURL, forKey: OttoPreferenceKey.hermesRemoteURL)
    defaults.set(remoteProfile, forKey: OttoPreferenceKey.hermesRemoteProfile)
    defaults.set(remoteWorkingDirectory, forKey: OttoPreferenceKey.hermesRemoteWorkingDirectory)
  }

  public var normalizedRemoteURL: URL? {
    guard mode == .remote, let url = URL(string: remoteURL),
      let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
      url.host != nil, url.user == nil, url.password == nil, url.fragment == nil
    else { return nil }
    return url
  }
}

/// Resolution policy for the adjustable matte surface opacity. The preference is a Double
/// under `OttoPreferenceKey.matteOpacity`; values at or below zero (including "never set")
/// fall back to the active theme's `nodeOpacity`, so a fresh install shows each matte
/// theme at its designed density.
public enum OttoMatteTransparency {
  /// Below the floor, text panels lose legibility over bright backdrop regions;
  /// 1.0 is fully opaque (matte transparency off).
  public static let range: ClosedRange<Double> = 0.55...1.0

  public static func clamped(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  public static func resolve(preference: Double?, themeDefault: Double) -> Double {
    guard let preference, preference > 0 else { return clamped(themeDefault) }
    return clamped(preference)
  }
}

/// Window glass is intentionally much sheerer than a flat matte surface. Its cards receive a
/// local system material, so this value is only the colour wash above that blur.
public enum OttoWindowGlassTransparency {
  public static let range: ClosedRange<Double> = 0.12...0.42

  public static func clamped(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }
}

public enum OttoFontScale: String, Codable, CaseIterable, Sendable {
  case extraSmall
  case small
  case standard
  case large
  case extraLarge

  public var multiplier: Double {
    switch self {
    case .extraSmall: 0.8
    case .small: 0.9
    case .standard: 1
    case .large: 1.15
    case .extraLarge: 1.3
    }
  }

  public var label: String {
    switch self {
    case .extraSmall: "Extra Small"
    case .small: "Small"
    case .standard: "Standard"
    case .large: "Large"
    case .extraLarge: "Extra Large"
    }
  }
}

public enum AgentNamingMode: String, Codable, CaseIterable, Sendable {
  case otto
  case custom

  /// Accepts the pre-rename stored value `muse` as `.otto`.
  public init?(rawValue: String) {
    switch rawValue {
    case "otto", "muse": self = .otto
    case "custom": self = .custom
    default: return nil
    }
  }

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let value = Self(rawValue: raw) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Unknown naming mode \(raw)"))
    }
    self = value
  }
}

public struct AgentNamingPolicy: Codable, Equatable, Sendable {
  public static let ottoRoster = ["Aria", "Beck", "Coda", "Echo", "Fable", "Lyric"]

  public var mode: AgentNamingMode
  public var customNames: [String]

  public init(mode: AgentNamingMode = .otto, customNames: [String] = []) {
    self.mode = mode
    self.customNames = Self.normalized(customNames)
  }

  public var roster: [String] {
    mode == .custom && !customNames.isEmpty ? customNames : Self.ottoRoster
  }

  public func nextName(existingNames: [String]) -> String {
    let occupied = Set(
      existingNames.map {
        $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      })
    var generation = 0
    while true {
      for base in roster {
        let candidate = generation == 0 ? base : "\(base) \(generation + 1)"
        let folded = candidate.folding(
          options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !occupied.contains(folded) { return candidate }
      }
      generation += 1
    }
  }

  public static func normalized(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return names.compactMap { raw in
      let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
      guard !value.isEmpty else { return nil }
      let folded = value.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      guard seen.insert(folded).inserted else { return nil }
      return value
    }
  }

  public static func load(from defaults: UserDefaults = .standard) -> AgentNamingPolicy {
    AgentNamingPolicy(
      mode: AgentNamingMode(
        rawValue: defaults.string(forKey: OttoPreferenceKey.agentNamingMode) ?? "") ?? .otto,
      customNames: defaults.stringArray(forKey: OttoPreferenceKey.agentCustomNames) ?? []
    )
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(mode.rawValue, forKey: OttoPreferenceKey.agentNamingMode)
    defaults.set(customNames, forKey: OttoPreferenceKey.agentCustomNames)
  }
}

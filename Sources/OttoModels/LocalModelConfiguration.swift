import Foundation

/// Non-secret connection settings for a user's OpenAI-compatible server.
/// Credentials are stored separately using OttoHarnessProvider.local.credentialKey.
public struct LocalModelConfiguration: Sendable, Equatable {
  public static let baseURLKey = "otto.harness.local.base-url"
  public static let modelIDKey = "otto.harness.local.model-id"
  public static let exampleURL = "http://127.0.0.1:11434/v1"

  public let baseURL: URL
  public let modelID: String

  public init(baseURL input: String, modelID: String) throws {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: raw),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      !raw.contains("\n"), !raw.contains("\r"),
      scheme == "https" || (scheme == "http" && Self.isPrivateHost(host))
    else { throw LocalModelConfigurationError.invalidURL }

    let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty, identifier.count <= 200,
      !identifier.contains("\n"), !identifier.contains("\r")
    else { throw LocalModelConfigurationError.invalidModel }

    // The setting is an API base, never a user-provided full method URL.
    let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !path.hasSuffix("/chat/completions"), path != "chat/completions",
      !path.hasSuffix("/models"), path != "models"
    else { throw LocalModelConfigurationError.invalidURL }
    var normalized = components
    normalized.path =
      components.path.hasSuffix("/") && components.path != "/"
      ? String(components.path.dropLast()) : components.path
    guard let parsed = normalized.url else { throw LocalModelConfigurationError.invalidURL }
    self.baseURL = parsed
    self.modelID = identifier
  }

  public var apiBaseURL: URL {
    baseURL.path.split(separator: "/").last == "v1"
      ? baseURL : baseURL.appending(path: "v1")
  }
  public var modelsURL: URL { apiBaseURL.appending(path: "models") }
  public var completionsURL: URL { apiBaseURL.appending(path: "chat/completions") }

  public static func load(defaults: UserDefaults = .standard) -> LocalModelConfiguration? {
    guard let address = defaults.string(forKey: baseURLKey),
      let model = defaults.string(forKey: modelIDKey)
    else { return nil }
    return try? LocalModelConfiguration(baseURL: address, modelID: model)
  }

  public func save(defaults: UserDefaults = .standard) {
    defaults.set(baseURL.absoluteString, forKey: Self.baseURLKey)
    defaults.set(modelID, forKey: Self.modelIDKey)
  }

  private static func isPrivateHost(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
      || host.hasSuffix(".local") || host.hasSuffix(".internal")
      || (!host.contains(".") && !host.contains(":"))
    {
      return true
    }
    let pieces = host.split(separator: ".").compactMap { UInt8($0) }
    guard pieces.count == 4, host.split(separator: ".").count == 4 else { return false }
    return pieces[0] == 127 || pieces[0] == 10 || (pieces[0] == 192 && pieces[1] == 168)
      || (pieces[0] == 172 && (16...31).contains(Int(pieces[1])))
      || (pieces[0] == 169 && pieces[1] == 254)
  }
}

public enum LocalModelConfigurationError: Error, LocalizedError {
  case invalidURL
  case invalidModel

  public var errorDescription: String? {
    switch self {
    case .invalidURL:
      "Enter an HTTPS server URL or an HTTP loopback/private-LAN URL, with no credentials or query string."
    case .invalidModel:
      "Enter the exact model ID served by your OpenAI-compatible API."
    }
  }
}

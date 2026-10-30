import Foundation

/// Non-secret connection settings for a user's OpenAI-compatible server.
/// Credentials are stored separately using OttoHarnessProvider.local.credentialKey.
public struct LocalModelConfiguration: Sendable, Equatable {
  public static let baseURLKey = "otto.harness.local.base-url"
  public static let modelIDKey = "otto.harness.local.model-id"
  /// Every model the person picked from the server, primary first.
  public static let modelIDsKey = "otto.harness.local.model-ids"
  public static let maxModels = 50
  public static let exampleURL = "http://127.0.0.1:11434/v1"

  public let baseURL: URL
  public let modelID: String
  /// The models offered in every Otto Harness picker: `modelID` first, then the others.
  public let modelIDs: [String]

  public init(baseURL input: String, modelID: String, additionalModelIDs: [String] = []) throws {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    // People commonly paste a local server's IP:port without the scheme.
    // Default to HTTP only for an address that subsequently passes our
    // private-network allowlist. Never infer HTTP for public servers.
    let address = raw.contains("://") ? raw : "http://\(raw)"
    guard let components = URLComponents(string: address),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      !raw.contains("\n"), !raw.contains("\r"), !raw.contains("\\"),
      scheme == "https" || (scheme == "http" && Self.isPrivateHost(host))
    else { throw LocalModelConfigurationError.invalidURL }

    let identifier = try Self.validatedModelID(modelID)
    var identifiers = [identifier]
    for candidate in additionalModelIDs {
      let extra = try Self.validatedModelID(candidate)
      if !identifiers.contains(extra) { identifiers.append(extra) }
    }
    guard identifiers.count <= Self.maxModels else {
      throw LocalModelConfigurationError.invalidModel
    }

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
    self.modelIDs = identifiers
  }

  private static func validatedModelID(_ value: String) throws -> String {
    let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty, identifier.count <= 200,
      !identifier.contains("\n"), !identifier.contains("\r")
    else { throw LocalModelConfigurationError.invalidModel }
    return identifier
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
    let others = (defaults.stringArray(forKey: modelIDsKey) ?? []).filter { $0 != model }
    return try? LocalModelConfiguration(
      baseURL: address, modelID: model, additionalModelIDs: others)
  }

  public func save(defaults: UserDefaults = .standard) {
    defaults.set(baseURL.absoluteString, forKey: Self.baseURLKey)
    defaults.set(modelID, forKey: Self.modelIDKey)
    defaults.set(modelIDs, forKey: Self.modelIDsKey)
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
    // Tailscale devices use 100.64.0.0/10. The range is non-public and
    // shared with CGNAT, so it must still be a trusted/private connection.
    return pieces[0] == 127 || pieces[0] == 10
      || (pieces[0] == 100 && (64...127).contains(Int(pieces[1])))
      || (pieces[0] == 192 && pieces[1] == 168)
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
      "Enter an HTTPS URL or local/LAN/Tailnet HTTP address without credentials or a query string. macOS may require HTTPS for remote HTTP hosts."
    case .invalidModel:
      "Enter the exact model ID served by your OpenAI-compatible API."
    }
  }
}

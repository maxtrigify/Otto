import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct HermesRemoteProfile: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var isDefault: Bool
  public var model: String?
  public var provider: String?

  public var id: String { name }

  public init(
    name: String,
    isDefault: Bool = false,
    model: String? = nil,
    provider: String? = nil
  ) {
    self.name = name
    self.isDefault = isDefault
    self.model = model
    self.provider = provider
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case isDefault = "is_default"
    case model
    case provider
  }
}

public enum HermesRemoteProfileCatalogError: Error, LocalizedError, Sendable {
  case invalidResponse
  case requestFailed(Int)
  case emptyCatalog

  public var errorDescription: String? {
    switch self {
    case .invalidResponse: "Hermes returned an invalid profile catalog."
    case .requestFailed(let status): "Hermes profile discovery failed (HTTP \(status))."
    case .emptyCatalog: "Hermes did not report any profiles."
    }
  }
}

public struct HermesRemoteProfileCatalog: Sendable {
  private struct Response: Decodable {
    var profiles: [HermesRemoteProfile]
  }

  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func profiles(baseURL: URL, sessionToken: String) async throws
    -> [HermesRemoteProfile]
  {
    let endpoint = baseURL.appending(path: "api/profiles")
    var request = URLRequest(url: endpoint, timeoutInterval: 60)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(sessionToken, forHTTPHeaderField: "X-Hermes-Session-Token")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw HermesRemoteProfileCatalogError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw HermesRemoteProfileCatalogError.requestFailed(http.statusCode)
    }
    let decoded = try JSONDecoder().decode(Response.self, from: data)
    var seen = Set<String>()
    let profiles = decoded.profiles.compactMap { profile -> HermesRemoteProfile? in
      var normalized = profile
      normalized.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !normalized.name.isEmpty, seen.insert(normalized.name).inserted else { return nil }
      normalized.model = normalized.model?.trimmingCharacters(in: .whitespacesAndNewlines)
      normalized.provider = normalized.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
      return normalized
    }
    .sorted {
      if $0.isDefault != $1.isDefault { return $0.isDefault }
      return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    guard !profiles.isEmpty else { throw HermesRemoteProfileCatalogError.emptyCatalog }
    return profiles
  }
}

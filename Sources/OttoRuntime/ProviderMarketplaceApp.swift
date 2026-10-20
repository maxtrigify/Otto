import Foundation

/// Public metadata from the provider's supported catalogue RPC; contains no account secrets.
public struct ProviderMarketplaceApp: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let installURL: URL?
  public let isAccessible: Bool
  public let isEnabled: Bool
  public let isCallable: Bool?

  public init(
    id: String, name: String, description: String, installURL: URL?,
    isAccessible: Bool, isEnabled: Bool, isCallable: Bool? = nil
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.installURL = Self.safeInstallURL(installURL?.absoluteString)
    self.isAccessible = isAccessible
    self.isEnabled = isEnabled
    self.isCallable = isCallable
  }

  /// Only open the provider's actual HTTPS connection screens, never arbitrary catalogue URLs.
  public static func safeInstallURL(_ raw: String?) -> URL? {
    guard let raw, raw.utf8.count < 4096, let url = URL(string: raw),
      url.scheme == "https", url.host?.lowercased() == "chatgpt.com",
      url.user == nil, url.password == nil, url.port == nil,
      url.path.hasPrefix("/apps/") || url.path.hasPrefix("/plugins/")
    else { return nil }
    return url
  }

  static func parse(_ rows: [[String: Any]], installed: [[String: Any]]) -> [Self] {
    var states: [String: Bool] = [:]
    for row in installed {
      if let id = row["id"] as? String, let enabled = row["enabled"] as? Bool,
        let callable = row["callable"] as? Bool
      {
        states[id] = enabled && callable
      }
    }
    var seen = Set<String>()
    return rows.compactMap { row in
      guard let id = row["id"] as? String, !id.isEmpty, id.count <= 256,
        let name = row["name"] as? String, !name.isEmpty, name.count <= 200,
        seen.insert(id).inserted
      else { return nil }
      return Self(
        id: id, name: name, description: String((row["description"] as? String ?? "").prefix(2000)),
        installURL: safeInstallURL(row["installUrl"] as? String),
        isAccessible: row["isAccessible"] as? Bool == true,
        isEnabled: row["isEnabled"] as? Bool == true, isCallable: states[id])
    }
  }
}

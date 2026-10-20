import Foundation
import OttoModels

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Public metadata only. These feeds describe packages, not account entitlements or OAuth state.
public struct PublicMarketplacePlugin: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let summary: String
  public let provider: AgentProvider
  public let sourceURL: URL
  public let installSource: String?
  public let nativeInstall: Bool
  public let remoteURL: URL?

  public init(
    id: String, name: String, summary: String, provider: AgentProvider,
    sourceURL: URL, installSource: String?, nativeInstall: Bool, remoteURL: URL? = nil
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.provider = provider
    self.sourceURL = sourceURL
    self.installSource = installSource
    self.nativeInstall = nativeInstall
    self.remoteURL = remoteURL
  }
}

public enum PublicPluginCatalog {
  public static let providers: [AgentProvider] = [.claudeCode, .cursor, .grok, .kimi]
  public static func feed(for provider: AgentProvider) -> URL? {
    let value: String
    switch provider {
    case .claudeCode:
      value =
        "https://raw.githubusercontent.com/anthropics/claude-plugins-official/main/.claude-plugin/marketplace.json"
    case .cursor:
      value =
        "https://raw.githubusercontent.com/cursor/plugins/main/.cursor-plugin/marketplace.json"
    case .grok:
      value =
        "https://raw.githubusercontent.com/xai-org/plugin-marketplace/main/.grok-plugin/marketplace.json"
    case .kimi: value = "https://code.kimi.com/kimi-code/plugins/marketplace.json"
    default: return nil
    }
    return URL(string: value)
  }

  public static func load(provider: AgentProvider) async throws -> [PublicMarketplacePlugin] {
    guard let url = feed(for: provider) else { return [] }
    return try parse(await fetch(url), provider: provider)
  }

  static func fetch(_ url: URL) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 20
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(from: url)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      acceptsResponse(request: url, response: response.url),
      response.expectedContentLength <= 4_194_304
    else { throw CatalogError.unavailable }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 4_194_304 else { throw CatalogError.tooLarge }
      data.append(byte)
    }
    return data
  }

  static func acceptsResponse(request: URL, response: URL?) -> Bool {
    if request == response { return true }
    // The documented Kimi feed currently redirects to its first-party CDN. No other
    // cross-origin or path-changing redirect is accepted for catalogue metadata.
    return request == feed(for: .kimi)
      && response == URL(string: "https://cdn.kimi.com/kimi-code/plugins/marketplace.json")
  }

  public static func parse(_ data: Data, provider: AgentProvider) throws
    -> [PublicMarketplacePlugin]
  {
    guard data.count <= 4_194_304, let feed = feed(for: provider),
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let plugins = root["plugins"] as? [[String: Any]], plugins.count <= 10_000
    else { throw CatalogError.unavailable }
    var seen = Set<String>()
    return plugins.compactMap { item in
      guard let id = (item["id"] ?? item["name"]) as? String, validID(id),
        seen.insert(id).inserted
      else { return nil }
      let name = String(((item["displayName"] as? String) ?? id).prefix(200))
      let summary = String(((item["description"] as? String) ?? "").prefix(2_000))
      var install: String?
      switch provider {
      case .claudeCode:
        // Install by official marketplace identity; never execute commands supplied by metadata.
        // Command sources require an interactive trust decision in Claude's own UI.
        let source = item["source"] as? [String: Any]
        if source?["source"] as? String != "command" {
          install = "\(id)@claude-plugins-official"
        }
      case .grok:
        if let source = item["source"] as? [String: Any] {
          if let raw = source["url"] as? String, let url = githubRepository(raw),
            let sha = source["sha"] as? String, validSHA(sha)
          {
            install = url.absoluteString + "@" + sha
          } else if let path = source["path"] as? String, validPath(path) {
            install =
              "https://github.com/xai-org/plugin-marketplace.git#"
              + path.replacingOccurrences(of: "./", with: "")
          }
        }
      case .kimi:
        if let raw = item["source"] as? String {
          if raw.hasPrefix("./"), validPath(raw) {
            install = URL(string: raw, relativeTo: feed)?.absoluteURL.absoluteString
          } else if let url = githubRepository(raw) {
            install = url.absoluteString
          }
        }
      case .cursor:
        if let path = item["source"] as? String, validPath(path) {
          let path = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
          install = "https://raw.githubusercontent.com/cursor/plugins/main/\(path)/mcp.json"
        }
      default: break
      }
      return PublicMarketplacePlugin(
        id: id, name: name, summary: summary, provider: provider,
        sourceURL: feed, installSource: install,
        nativeInstall: install != nil && (provider == .claudeCode || provider == .grok))
    }
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 200 && value.first != "-"
      && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
  }
  private static func validSHA(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy { "0123456789abcdef".contains($0) }
  }
  private static func validPath(_ value: String) -> Bool {
    let path = value.hasPrefix("./") ? String(value.dropFirst(2)) : value
    return !path.isEmpty && !path.hasPrefix("/") && path.count < 500
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
          && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
      }
  }
  private static func githubRepository(_ raw: String) -> URL? {
    guard let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
      url.user == nil, url.password == nil, url.port == nil, url.query == nil,
      url.fragment == nil, url.path.split(separator: "/").count == 2,
      validPath(String(url.path.dropFirst()))
    else { return nil }
    return url
  }
  public enum CatalogError: Error { case unavailable, tooLarge }
}

public struct CursorMCPInstallLink: Equatable, Sendable, Identifiable {
  public let id: String
  public let serverURL: URL
  public let installURL: URL
}

public enum CursorMCPInstallLinks {
  public static func load(_ plugin: PublicMarketplacePlugin) async -> [CursorMCPInstallLink] {
    guard plugin.provider == .cursor, let source = plugin.installSource,
      let url = URL(string: source), url.scheme == "https",
      url.host == "raw.githubusercontent.com", url.path.hasPrefix("/cursor/plugins/main/"),
      url.path.hasSuffix("/mcp.json"), url.user == nil, url.password == nil, url.query == nil
    else { return [] }
    guard let data = try? await PublicPluginCatalog.fetch(url) else { return [] }
    return parse(data)
  }

  public static func parse(_ data: Data) -> [CursorMCPInstallLink] {
    guard data.count <= 262_144,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = root["mcpServers"] as? [String: Any], servers.count <= 20
    else { return [] }
    return servers.sorted { $0.key < $1.key }.compactMap { id, entry in
      guard !id.isEmpty, id.count <= 200, !id.hasPrefix("-"),
        let config = entry as? [String: Any], config["command"] == nil,
        (config["headers"] as? [String: Any] ?? [:]).isEmpty,
        let raw = config["url"] as? String, let url = URL(string: raw),
        url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, !raw.contains("{")
      else { return nil }
      // Only remote transport is forwarded. Commands, environment values, headers and
      // plugin execution components remain in the provider's reviewed package flow.
      guard let encoded = try? JSONSerialization.data(withJSONObject: ["url": raw]) else {
        return nil
      }
      var link = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")!
      link.queryItems = [
        URLQueryItem(name: "name", value: id),
        URLQueryItem(name: "config", value: encoded.base64EncodedString()),
      ]
      link.percentEncodedQuery = link.percentEncodedQuery?.replacingOccurrences(
        of: "+", with: "%2B")
      guard let installURL = link.url else { return nil }
      return CursorMCPInstallLink(id: id, serverURL: url, installURL: installURL)
    }
  }
}

/// A bounded community fallback for OpenCode, which has no verified native app directory.
/// Registry presence is provenance, not compatibility, authentication or plan eligibility.
public enum CommunityMCPCatalog {
  public static func load() async throws -> [PublicMarketplacePlugin] {
    var entries: [PublicMarketplacePlugin] = []
    var cursor: String?
    var seen = Set<String>()
    // Five latest-version pages; keep this explicitly bounded rather than blocking the UI
    // on the whole registry. Users can browse the full registry through the source link.
    for _ in 0..<5 {
      var components = URLComponents(
        string: "https://registry.modelcontextprotocol.io/v0.1/servers")!
      components.queryItems = [
        URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "version", value: "latest"),
      ]
      if let cursor { components.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
      let data = try await PublicPluginCatalog.fetch(components.url!)
      let page = try parse(data)
      entries += page.plugins.filter { seen.insert($0.id).inserted }
      guard let next = page.cursor, next != cursor else { break }
      cursor = next
    }
    return entries
  }

  static func parse(_ data: Data) throws -> (plugins: [PublicMarketplacePlugin], cursor: String?) {
    guard data.count <= 4_194_304,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let servers = root["servers"] as? [[String: Any]], servers.count <= 100
    else { throw PublicPluginCatalog.CatalogError.unavailable }
    let entries: [PublicMarketplacePlugin] = servers.compactMap { item in
      guard let server = item["server"] as? [String: Any], let id = server["name"] as? String,
        !id.isEmpty, id.count < 250,
        let remotes = server["remotes"] as? [[String: Any]],
        let remote = remotes.first(where: { $0["type"] as? String == "streamable-http" }),
        (remote["headers"] as? [Any] ?? []).isEmpty,
        let raw = remote["url"] as? String, let url = URL(string: raw),
        url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
        url.query == nil, url.fragment == nil, !raw.contains("{")
      else { return nil }
      let name = String(((server["title"] as? String) ?? id).prefix(200))
      return PublicMarketplacePlugin(
        id: id, name: name,
        summary: String(((server["description"] as? String) ?? "Remote MCP server").prefix(2_000)),
        provider: .openCode, sourceURL: URL(string: "https://registry.modelcontextprotocol.io")!,
        installSource: nil, nativeInstall: false, remoteURL: url)
    }
    let cursor = (root["metadata"] as? [String: Any])?["nextCursor"] as? String
    guard (cursor?.count ?? 0) <= 1_000 else { throw PublicPluginCatalog.CatalogError.unavailable }
    return (entries, cursor)
  }
}

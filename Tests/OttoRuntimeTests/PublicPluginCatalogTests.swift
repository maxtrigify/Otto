import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Public marketplace catalogues")
struct PublicPluginCatalogTests {
  @Test func catalogueIsMetadataNotConnectionState() throws {
    let data = Data(
      #"{"plugins":[{"name":"slack","description":"Chat","source":"./external_plugins/slack"},{"name":"slack","source":"./duplicate"},{"name":"--danger"}]}"#
        .utf8)
    let plugins = try PublicPluginCatalog.parse(data, provider: .claudeCode)
    #expect(plugins.count == 1)
    #expect(plugins[0].nativeInstall)
    #expect(
      MarketplaceInstaller.arguments(for: plugins[0]) == [
        "plugin", "install", "slack@claude-plugins-official", "--scope", "user",
      ])
  }

  @Test func commandSourcesAndUnpinnedRepositoriesCannotAutoInstall() throws {
    let command = Data(
      #"{"plugins":[{"name":"unsafe","source":{"source":"command","command":"do anything"}}]}"#.utf8
    )
    #expect(try PublicPluginCatalog.parse(command, provider: .claudeCode)[0].nativeInstall == false)
    let data = Data(
      #"{"plugins":[{"name":"missing-sha","source":{"url":"https://github.com/vendor/repo"}},{"name":"credentials","source":{"url":"https://user:password@github.com/vendor/repo","sha":"0123456789012345678901234567890123456789"}},{"name":"traversal","source":{"path":"./plugins/../unsafe"}}]}"#
        .utf8)
    let plugins = try PublicPluginCatalog.parse(data, provider: .grok)
    #expect(plugins.allSatisfy { !$0.nativeInstall && $0.installSource == nil })
  }

  @Test func grokPinsAndKimiRelativeURLsArePreserved() throws {
    let grok = Data(
      #"{"plugins":[{"name":"linear","source":{"url":"https://github.com/vendor/repo.git","sha":"0123456789012345678901234567890123456789"}},{"name":"local","source":{"path":"./plugins/local"}}]}"#
        .utf8)
    let plugins = try PublicPluginCatalog.parse(grok, provider: .grok)
    #expect(
      plugins[0].installSource
        == "https://github.com/vendor/repo.git@0123456789012345678901234567890123456789")
    #expect(
      plugins[1].installSource == "https://github.com/xai-org/plugin-marketplace.git#plugins/local")
    #expect(!MarketplaceInstaller.arguments(for: plugins[0])!.contains("--trust"))
    let kimi = Data(
      #"{"plugins":[{"id":"official","displayName":"Kimi App","source":"./official/app.zip"}]}"#
        .utf8)
    let app = try PublicPluginCatalog.parse(kimi, provider: .kimi)[0]
    #expect(app.installSource == "https://code.kimi.com/kimi-code/plugins/official/app.zip")
    #expect(!app.nativeInstall)
  }

  @Test func boundedMalformedAndUnsupportedFeedsFailClosed() {
    #expect(throws: (any Error).self) {
      try PublicPluginCatalog.parse(Data(#"{"items":[]}"#.utf8), provider: .cursor)
    }
    #expect(throws: (any Error).self) {
      try PublicPluginCatalog.parse(Data(repeating: 0, count: 4_194_305), provider: .claudeCode)
    }
    #expect(PublicPluginCatalog.feed(for: .hermes) == nil)
    #expect(PublicPluginCatalog.feed(for: .openCode) == nil)
  }

  @Test func nativeJobsTimeoutAndReportFailureWithoutInference() {
    #expect(MarketplaceInstaller.run("/usr/bin/true", arguments: [], timeout: 2) == .installed)
    #expect(
      MarketplaceInstaller.run("/usr/bin/false", arguments: [], timeout: 2) == .needsProviderSetup)
    #expect(MarketplaceInstaller.run("/bin/sleep", arguments: ["5"], timeout: 0.1) == .timedOut)
  }

  @Test func remoteAuthenticationOnlyUsesConfiguredProviderIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = root.appending(path: ".cursor")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(
      #"{"mcpServers":{"slack":{"url":"https://example.com/mcp"},"local":{"command":"some-program"},"--unsafe":{"url":"https://example.com"}}}"#
        .utf8
    )
    .write(to: dir.appending(path: "mcp.json"))
    #expect(
      HarnessPluginCatalog.authenticationServer(
        named: "Slack", provider: .cursor,
        workspacePath: root.path, homeDirectory: root.path) == "slack")
    #expect(
      HarnessPluginCatalog.authenticationServer(
        named: "Local", provider: .cursor,
        workspacePath: root.path, homeDirectory: root.path) == nil)
    #expect(
      HarnessPluginCatalog.authenticationServer(
        named: "Slack", provider: .kimi,
        workspacePath: root.path, homeDirectory: root.path) == nil)
  }

  @Test func liveOfficialFeedsWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_LIVE_PUBLIC_MARKETPLACE"] == "1" else { return }
    for provider in PublicPluginCatalog.providers {
      let entries = try await PublicPluginCatalog.load(provider: provider)
      #expect(!entries.isEmpty)
      print("Public \(provider.rawValue) catalogue: \(entries.count) entries")
    }
    let community = try await CommunityMCPCatalog.load()
    #expect(!community.isEmpty)
    print(
      "Community remote MCP catalogue: \(community.count) entries from up to 500 registry records")
  }

  @Test func communityRegistryRejectsTemplatesCredentialsAndRequiredHeaders() throws {
    let data = Data(
      #"{"servers":[{"server":{"name":"org/valid","remotes":[{"type":"streamable-http","url":"https://example.com/mcp"}]}},{"server":{"name":"org/secret","remotes":[{"type":"streamable-http","url":"https://user:password@example.com/mcp"}]}},{"server":{"name":"org/template","remotes":[{"type":"streamable-http","url":"https://example.com/{key}"}]}},{"server":{"name":"org/header","remotes":[{"type":"streamable-http","url":"https://example.com/mcp","headers":[{"name":"Authorization","isRequired":true}]}]}}],"metadata":{"nextCursor":"next"}}"#
        .utf8)
    let page = try CommunityMCPCatalog.parse(data)
    #expect(page.plugins.count == 1)
    #expect(page.plugins[0].remoteURL?.absoluteString == "https://example.com/mcp")
    #expect(page.cursor == "next")
    #expect(page.plugins[0].provider == .openCode)
  }

  @Test func registrationPreservesSettingsAndRefusesJSONCOrConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "opencode.json")
    let original = Data(
      #"{"theme":"night","mcp":{"existing":{"type":"remote","url":"https://old.example/mcp"}}}"#
        .utf8)
    try original.write(to: file)
    let url = URL(string: "https://example.com/mcp")!
    let id = try MarketplaceInstaller.registerOpenCodeRemote(
      url: url, identity: "org/app", directory: root)
    let saved = try Data(contentsOf: file)
    let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
    #expect(object["theme"] as? String == "night")
    #expect((object["mcp"] as? [String: Any])?["existing"] != nil)
    #expect(
      try MarketplaceInstaller.registerOpenCodeRemote(
        url: url, identity: "org/app", directory: root) == id)
    #expect(throws: (any Error).self) {
      try MarketplaceInstaller.registerOpenCodeRemote(
        url: URL(string: "https://different.example/mcp")!, identity: "org/app", directory: root)
    }
    try Data("{}".utf8).write(to: root.appending(path: "opencode.jsonc"))
    #expect(throws: (any Error).self) {
      try MarketplaceInstaller.registerOpenCodeRemote(
        url: url, identity: "new/app", directory: root)
    }
    #expect(try Data(contentsOf: file) == saved)
  }

  @Test func cursorLinksCarryOnlyRemoteTransportAndEscapeBase64() throws {
    let data = Data(
      #"{"mcpServers":{"remote":{"url":"https://example.com/mcp","extra":"ignored"},"local":{"command":"npx","url":"https://example.com/mcp"},"secret":{"url":"https://example.com/mcp","headers":{"Authorization":"required"}},"template":{"url":"https://example.com/{key}"}}}"#
        .utf8)
    let links = CursorMCPInstallLinks.parse(data)
    #expect(links.count == 1)
    let parts = try #require(
      URLComponents(url: links[0].installURL, resolvingAgainstBaseURL: false))
    #expect(parts.scheme == "cursor")
    #expect(parts.host == "anysphere.cursor-deeplink")
    let encoded = try #require(parts.queryItems?.first { $0.name == "config" }?.value)
    let config = try #require(Data(base64Encoded: encoded))
    let object = try #require(try JSONSerialization.jsonObject(with: config) as? [String: String])
    #expect(object == ["url": "https://example.com/mcp"])
    #expect(parts.queryItems?.first { $0.name == "name" }?.value == "remote")
  }

  @Test func onlyTheVerifiedKimiCDNRedirectIsAccepted() throws {
    let feed = try #require(PublicPluginCatalog.feed(for: .kimi))
    #expect(
      PublicPluginCatalog.acceptsResponse(
        request: feed,
        response: URL(string: "https://cdn.kimi.com/kimi-code/plugins/marketplace.json")))
    #expect(
      !PublicPluginCatalog.acceptsResponse(
        request: feed,
        response: URL(string: "https://cdn.kimi.com/another/path")))
    #expect(
      !PublicPluginCatalog.acceptsResponse(
        request: feed,
        response: URL(string: "https://untrusted.example/marketplace.json")))
  }
}

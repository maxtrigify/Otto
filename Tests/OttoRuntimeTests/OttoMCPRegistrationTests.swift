import Foundation
import Testing

@testable import OttoRuntime

@Suite("Otto MCP registration after the Muse rename")
struct OttoMCPRegistrationTests {
  private let legacyBridge = "/Applications/Muse.app/Contents/MacOS/muse-mcp"
  private let bridge = "/Applications/Otto.app/Contents/MacOS/otto-mcp"

  private func workspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "otto-mcp-rename-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func servers(in file: URL) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    return try #require(root?["mcpServers"] as? [String: Any])
  }

  @Test("Only the muse entry Muse wrote is removed")
  func removesOnlyMuseWrittenEntry() {
    let written: [String: Any] = [
      "muse": ["command": legacyBridge, "toolTimeoutMs": 3_600_000],
      "linear": ["command": "npx"],
    ]
    let cleaned = OttoMCPRegistration.removingLegacyEntry(
      from: written, writtenKeys: ["command", "toolTimeoutMs"])
    #expect(cleaned["muse"] == nil)
    #expect(cleaned["linear"] != nil)

    // Another command under the same name is the user's own server.
    let userCommand: [String: Any] = ["muse": ["command": "/usr/local/bin/muse-notes"]]
    #expect(
      OttoMCPRegistration.removingLegacyEntry(from: userCommand, writtenKeys: ["command"])["muse"]
        != nil)
    // Our bridge, but with settings Muse never wrote: also the user's.
    let userSettings: [String: Any] = ["muse": ["command": legacyBridge, "args": ["--debug"]]]
    #expect(
      OttoMCPRegistration.removingLegacyEntry(from: userSettings, writtenKeys: ["command"])["muse"]
        != nil)
  }

  @Test("Cursor's project mcp.json swaps the Muse entry for otto and keeps user servers")
  func cursorRewrite() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: ".cursor/mcp.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      #"{"mcpServers":{"muse":{"command":"\#(legacyBridge)"},"linear":{"command":"npx"}}}"#.utf8
    ).write(to: file)

    CursorAdapter(executablePath: "/usr/bin/false").registerOttoMCPServer(
      command: bridge, workingDirectory: root.path)

    let servers = try servers(in: file)
    #expect(servers["muse"] == nil)
    #expect((servers["otto"] as? [String: Any])?["command"] as? String == bridge)
    #expect(servers["linear"] != nil)
  }

  @Test("Kimi keeps a user-authored muse server")
  func kimiKeepsUserEntry() throws {
    let root = try workspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: ".kimi-code/mcp.json")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"mcpServers":{"muse":{"command":"/usr/local/bin/muse-notes"}}}"#.utf8)
      .write(to: file)

    KimiAdapter(executablePath: "/usr/bin/false").registerOttoMCPServer(
      command: bridge, workingDirectory: root.path)

    let servers = try servers(in: file)
    #expect(
      (servers["muse"] as? [String: Any])?["command"] as? String == "/usr/local/bin/muse-notes")
    #expect((servers["otto"] as? [String: Any])?["command"] as? String == bridge)
  }

  @Test("Grok drops Muse's [mcp_servers.muse] tables but never a user's")
  func grokTables() {
    let written = """
      [mcp_servers.linear]
      url = "https://mcp.linear.app/mcp"

      [mcp_servers.muse]
      command = "\(legacyBridge)"
      tool_timeout_sec = 3600

      [mcp_servers.muse.env]
      MUSE_CONTROL_SOCKET = "${MUSE_CONTROL_SOCKET}"
      """
    let cleaned = GrokAdapter.removingLegacySection(from: written)
    #expect(cleaned.contains("[mcp_servers.linear]"))
    #expect(!cleaned.contains("mcp_servers.muse"))
    #expect(!cleaned.contains("MUSE_CONTROL_SOCKET"))

    let user = """
      [mcp_servers.muse]
      command = "/usr/local/bin/muse-notes"
      """
    #expect(GrokAdapter.removingLegacySection(from: user) == user)
  }

  @Test("Tool names from either server name resolve to the same tool")
  func toolNames() {
    #expect(
      OttoMCPRegistration.unqualifiedToolName("mcp__otto__agent_ask_user") == "agent_ask_user")
    #expect(
      OttoMCPRegistration.unqualifiedToolName("mcp__muse__agent_ask_user") == "agent_ask_user")
    #expect(OttoMCPRegistration.unqualifiedToolName("mcp__linear__search") == nil)
    #expect(OttoMCPRegistration.isOttoExecutable("/x/otto-mcp"))
    #expect(OttoMCPRegistration.isOttoExecutable(legacyBridge))
    #expect(!OttoMCPRegistration.isOttoExecutable("/usr/bin/npx"))
  }

  @Test("The Hermes tool tunnel accepts the pre-rename marker")
  func tunnelMarker() {
    #expect(HermesOttoToolTunnelProtocol.marker == "__OTTO_TOOL_V1__")
    let body = #"{"name":"node.list","arguments":{}}"#
    for marker in ["__OTTO_TOOL_V1__", "__MUSE_TOOL_V1__"] {
      guard case .request(let request) = HermesOttoToolTunnelProtocol.parse(question: marker + body)
      else {
        Issue.record("\(marker) was not parsed")
        continue
      }
      #expect(request.name == "node.list")
    }
  }
}

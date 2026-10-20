import Foundation
import OttoCLI
import OttoControl
import OttoMCP
import OttoTools
import Testing

private struct SumInput: Codable, Sendable { let values: [Int] }
private struct SumOutput: Codable, Sendable, Equatable { let total: Int }

private struct SumTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.sum",
    description: "Adds integer values.",
    inputSchema: .object([
      "type": .string("object"),
      "required": .array([.string("values")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: SumInput, context: ToolContext) async throws -> SumOutput {
    SumOutput(total: input.values.reduce(0, +))
  }
}

@Suite("CLI and MCP protocol adapters")
struct ProtocolAdapterTests {
  @Test(
    "Private account approval/sign-in remains connected beyond the ordinary socket deadline",
    arguments: ["request_login", "click"])
  func privateAccountHumanWait(action: String) async throws {
    let directory = URL(fileURLWithPath: "/tmp/otto-private-wait-" + UUID().uuidString.prefix(10))
    let registry = ToolRegistry()
    try await registry.register(SlowPrivateAccountTool())
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(actorID: "synthetic", scopes: [.canvasRead])
    let server = try ControlServer(
      socketPath: directory.appending(path: "control.sock").path, registry: registry,
      authenticator: authenticator)
    defer {
      server.stop()
      try? FileManager.default.removeItem(at: directory)
    }
    let bridge = MCPBridge(client: ControlClient(socketPath: server.socketPath, token: token))
    let result = try await Task.detached {
      try bridge.handle(
        MCPRequest(
          id: .number(20), method: "tools/call",
          params: .object([
            "name": .string("browser_account"), "arguments": .object(["action": .string(action)]),
          ])))
    }.value
    #expect(result.result?["isError"] == .bool(false))
    #expect(result.result?["content"]?[0]?["text"]?.stringValue?.contains("11") == true)
  }

  @Test("ottoctl routes list and call through the control socket")
  func cliEndToEnd() async throws {
    let fixture = try await ProtocolFixture()
    defer { fixture.cleanup() }
    let runner = OttoCLIRunner(client: fixture.client)

    let listing = try runner.run(arguments: ["tools", "list"])
    #expect(listing.contains("test.sum"))
    let result = try runner.run(arguments: ["call", "test.sum", #"{"values":[2,3,5]}"#])
    #expect(result.contains("10"))
  }

  @Test("MCP initialize, tools/list, and tools/call use the same registry")
  func mcpEndToEnd() async throws {
    let fixture = try await ProtocolFixture()
    defer { fixture.cleanup() }
    let bridge = MCPBridge(client: fixture.client)

    let initialized = try bridge.handle(
      MCPRequest(id: .number(1), method: "initialize"))
    #expect(initialized.result?["serverInfo"]?["name"] == .string("otto-mcp"))

    let listed = try bridge.handle(MCPRequest(id: .number(2), method: "tools/list"))
    #expect(
      listed.result?["tools"]
        == .array([
          .object([
            "name": .string("test.sum"),
            "description": .string("Adds integer values."),
            "inputSchema": SumTool.definition.inputSchema,
          ])
        ]))

    let called = try bridge.handle(
      MCPRequest(
        id: .number(3),
        method: "tools/call",
        params: .object([
          "name": .string("test.sum"),
          "arguments": .object(["values": .array([.number(4), .number(6)])]),
        ])
      ))
    #expect(called.result?["isError"] == .bool(false))
    #expect(called.result?["content"]?[0]?["text"]?.stringValue?.contains("10") == true)
  }
}

private struct SlowPrivateAccountTool: OttoTool {
  struct Input: Codable, Sendable { let action: String }
  static let definition = ToolDefinition(
    name: "browser.account", description: "Synthetic human wait",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]), requiredScopes: [.canvasRead],
    riskLevel: .read)
  func call(_ input: Input, context: ToolContext) async throws -> SumOutput {
    try await Task.sleep(for: .seconds(11))
    return SumOutput(total: 11)
  }
}

private struct ProtocolFixture {
  let directory: URL
  let server: ControlServer
  let client: ControlClient

  init() async throws {
    directory = URL(fileURLWithPath: "/tmp/otto-proto-\(UUID().uuidString.prefix(10))")
    let registry = ToolRegistry()
    try await registry.register(SumTool())
    let authenticator = ControlAuthenticator()
    let token = await authenticator.issue(actorID: "protocol-test", scopes: [.canvasRead])
    let socketPath = directory.appending(path: "control.sock").path
    server = try ControlServer(
      socketPath: socketPath,
      registry: registry,
      authenticator: authenticator
    )
    client = ControlClient(socketPath: socketPath, token: token)
  }

  func cleanup() {
    server.stop()
    try? FileManager.default.removeItem(at: directory)
  }
}

extension JSONValue {
  fileprivate subscript(index: Int) -> JSONValue? {
    guard case .array(let array) = self, array.indices.contains(index) else { return nil }
    return array[index]
  }
}

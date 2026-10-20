import OttoTools
import Testing

private struct EchoInput: Codable, Sendable {
  let text: String
}

private struct EchoOutput: Codable, Sendable, Equatable {
  let echoed: String
}

private struct EchoTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.echo",
    description: "Echoes bounded test input.",
    inputSchema: .object([
      "type": .string("object"),
      "required": .array([.string("text")]),
      "properties": .object(["text": .object(["type": .string("string")])]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: EchoInput, context: ToolContext) async throws -> EchoOutput {
    EchoOutput(echoed: input.text)
  }
}

private struct FocusTool: OttoTool {
  static let definition = ToolDefinition(
    name: "node.focus",
    description: "Test interaction policy.",
    inputSchema: .objectSchema(),
    outputSchema: .objectSchema(),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  func call(_ input: EmptyToolInput, context: ToolContext) async throws -> EmptyToolInput {
    input
  }
}

private struct SpeakTool: OttoTool {
  static let definition = ToolDefinition(
    name: "voice.speak",
    description: "Test speech interaction policy.",
    inputSchema: .objectSchema(),
    outputSchema: .objectSchema(),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  func call(_ input: EmptyToolInput, context: ToolContext) async throws -> EmptyToolInput {
    input
  }
}

private struct EmptyToolInput: Codable, Sendable, Equatable {}

@Suite("Typed tool registry")
struct ToolRegistryTests {
  @Test("Lists and dispatches the exact registered schema")
  func listAndCall() async throws {
    let registry = ToolRegistry()
    try await registry.register(EchoTool())

    let definitions = await registry.definitions()
    #expect(definitions == [EchoTool.definition])

    let output = try await registry.call(
      name: "test.echo",
      input: .object(["text": .string("hello")]),
      context: ToolContext(actorID: "test", scopes: [.canvasRead]),
      requestID: "req-1"
    )
    #expect(try output.decode(EchoOutput.self) == EchoOutput(echoed: "hello"))
    #expect(await registry.auditLog().count == 1)
  }

  @Test("Denies calls without every required scope")
  func deniesMissingScope() async throws {
    let registry = ToolRegistry()
    try await registry.register(EchoTool())

    await #expect(throws: ToolRegistryError.missingScopes([.canvasRead])) {
      try await registry.call(
        name: "test.echo",
        input: .object(["text": .string("blocked")]),
        context: ToolContext(actorID: "restricted-agent", scopes: [])
      )
    }
  }

  @Test("Rejects invalid input before invoking a handler")
  func validatesInput() async throws {
    let registry = ToolRegistry()
    try await registry.register(EchoTool())

    await #expect(throws: (any Error).self) {
      try await registry.call(
        name: "test.echo",
        input: .object(["wrong": .bool(true)]),
        context: ToolContext(actorID: "test", scopes: [.canvasRead])
      )
    }
  }

  @Test("Agent calls cannot perform user-interface interactions")
  func deniesAgentFocus() async throws {
    let registry = ToolRegistry()
    try await registry.register(FocusTool())

    await #expect(throws: ToolRegistryError.interactionDenied(.focusUserInterface)) {
      try await registry.call(
        name: "node.focus",
        input: .object([:]),
        context: ToolContext(
          actorID: "background-agent",
          scopes: [.canvasWrite],
          source: .agent
        )
      )
    }
  }

  @Test("Voice calls retain intentional user-interface interaction privileges")
  func allowsVoiceFocus() async throws {
    let registry = ToolRegistry()
    try await registry.register(FocusTool())

    let output = try await registry.call(
      name: "node.focus",
      input: .object([:]),
      context: ToolContext(
        actorID: "voice",
        scopes: [.canvasWrite],
        source: .voice
      )
    )

    #expect(try output.decode(EmptyToolInput.self) == EmptyToolInput())
  }

  @Test("Agent calls cannot initiate speech")
  func deniesAgentSpeech() async throws {
    let registry = ToolRegistry()
    try await registry.register(SpeakTool())

    await #expect(throws: ToolRegistryError.interactionDenied(.speak)) {
      try await registry.call(
        name: "voice.speak",
        input: .object([:]),
        context: ToolContext(
          actorID: "background-agent",
          scopes: [.canvasWrite],
          source: .agent
        )
      )
    }
  }
}

import Foundation
import OttoTools
import Testing

@Suite("Command palette catalog")
struct CommandPaletteCatalogTests {
  @Test("Every palette action comes from the registry and remains searchable")
  func registryProjection() async throws {
    let registry = ToolRegistry()
    try await registry.register(PaletteFixtureTool())
    try await registry.register(SecondPaletteFixtureTool())
    let definitions = await registry.definitions()

    let actions = CommandPaletteCatalog.actions(from: definitions)
    #expect(actions.map(\.name) == definitions.map(\.name))
    #expect(
      CommandPaletteCatalog.actions(from: definitions, matching: "SECOND").map(\.name) == [
        "palette.second"
      ])
    #expect(CommandPaletteCatalog.actions(from: definitions, matching: "fixture action").count == 2)
  }

  @Test("Schema starter input is valid JSON and registry decoding rejects a wrong shape")
  func schemaConformance() async throws {
    let registry = ToolRegistry()
    try await registry.register(PaletteFixtureTool())
    let definition = try #require(await registry.definitions().first)
    let template = CommandPaletteCatalog.inputTemplate(for: definition)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(template.utf8))
    #expect(decoded == .object(["count": .number(0), "title": .string("")]))

    await #expect(throws: ToolRegistryError.self) {
      try await registry.call(
        name: definition.name,
        input: .string("not an object"),
        context: ToolContext(actorID: "palette-test", scopes: [.canvasRead])
      )
    }
  }
}

private struct PaletteInput: Codable, Sendable {
  let title: String
  let count: Int
}

private struct PaletteFixtureTool: OttoTool {
  static let definition = ToolDefinition(
    name: "palette.fixture",
    description: "Fixture action for the command palette",
    inputSchema: .object([
      "type": .string("object"),
      "required": .array([.string("title"), .string("count")]),
      "properties": .object([
        "title": .object(["type": .string("string")]),
        "count": .object(["type": .string("integer")]),
      ]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: PaletteInput, context: ToolContext) async throws -> Bool { true }
}

private struct SecondPaletteFixtureTool: OttoTool {
  static let definition = ToolDefinition(
    name: "palette.second",
    description: "Second fixture action",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: EmptyPaletteInput, context: ToolContext) async throws -> Bool { true }
}

private struct EmptyPaletteInput: Codable, Sendable {}

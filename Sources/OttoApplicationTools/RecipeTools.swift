import Foundation
import OttoCore
import OttoRecipes
import OttoTools

public struct RecipeListInput: Codable, Sendable {
  public init() {}
}

public struct RecipeSummary: Codable, Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var version: Int
  public var description: String
  public var nodeCount: Int
  public var updatedAt: Date

  init(record: RecipeRecord) {
    id = record.id
    name = record.definition.name
    version = record.definition.version
    description = record.definition.description
    nodeCount = record.definition.nodes.count
    updatedAt = record.updatedAt
  }
}

public struct RecipeSaveInput: Codable, Sendable {
  public var id: String
  public var name: String
  public var description: String?

  public init(id: String, name: String, description: String? = nil) {
    self.id = id
    self.name = name
    self.description = description
  }
}

public struct RecipeBootInput: Codable, Sendable {
  public var id: String
  public init(id: String) { self.id = id }
}

public struct RecipeBootOutput: Codable, Sendable, Equatable {
  public var recipeID: String
  public var nodeIDs: [UUID]
  public var message: String
}

public struct RecipeListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recipe.list",
    description: "Lists saved versioned workspace recipes.",
    inputSchema: .objectSchema(),
    outputSchema: .object(["type": .string("array")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let recipes: RecipeStore
  public init(recipes: RecipeStore) { self.recipes = recipes }

  public func call(_ input: RecipeListInput, context: ToolContext) async throws -> [RecipeSummary] {
    try await recipes.list().map(RecipeSummary.init)
  }
}

public struct RecipeSaveTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recipe.save",
    description: "Saves the active canvas layout and typed node configuration as a recipe.",
    inputSchema: .objectSchema(
      properties: [
        "id": .stringSchema(description: "Stable recipe ID"),
        "name": .stringSchema(description: "Human-readable recipe name"),
        "description": .stringSchema(description: "Optional recipe description"),
      ],
      required: ["id", "name"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead, .canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let recipes: RecipeStore

  public init(store: CanvasStore, recipes: RecipeStore) {
    self.store = store
    self.recipes = recipes
  }

  public func call(_ input: RecipeSaveInput, context: ToolContext) async throws -> RecipeSummary {
    let existingVersion = try await recipes.get(id: input.id)?.definition.version ?? 0
    let canvas = try await store.canvas(for: context)
    let definition = RecipeCapture.capture(
      id: input.id,
      name: input.name,
      description: input.description ?? "Saved from \(canvas.name)",
      version: existingVersion + 1,
      canvas: canvas
    )
    return RecipeSummary(record: try await recipes.save(definition))
  }
}

public struct RecipeBootTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recipe.boot",
    description:
      "Recreates a saved recipe on the active canvas without running prompts or commands.",
    inputSchema: .objectSchema(
      properties: ["id": .stringSchema(description: "Stable recipe ID to boot")],
      required: ["id"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let recipes: RecipeStore

  public init(store: CanvasStore, recipes: RecipeStore) {
    self.store = store
    self.recipes = recipes
  }

  public func call(_ input: RecipeBootInput, context: ToolContext) async throws -> RecipeBootOutput
  {
    guard let record = try await recipes.get(id: input.id) else {
      throw ToolRegistryError.invalidInput("Recipe not found: \(input.id)")
    }
    let targetCanvasID = try await store.resolvedCanvasID(for: context)
    let ids = try await RecipeEngine.boot(
      record.definition,
      into: store,
      targetCanvasID: targetCanvasID
    )
    return RecipeBootOutput(
      recipeID: record.id,
      nodeIDs: ids,
      message: "Booted \(record.definition.name) with \(ids.count) nodes"
    )
  }
}

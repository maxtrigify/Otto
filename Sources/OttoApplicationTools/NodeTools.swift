import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools

public struct NodeListInput: Codable, Sendable {
  public init() {}
}

public struct NodeIDInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct NodeListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.list",
    description: "Lists resources in the active workspace.",
    inputSchema: .emptyObjectSchema,
    outputSchema: .object([
      "type": .string("array"),
      "items": .object(["type": .string("object")]),
    ]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: NodeListInput, context: ToolContext) async throws -> [OttoNode] {
    try await store.canvas(for: context).nodes
  }
}

public struct NodeGetTool: OttoTool {
  public static let definition = nodeReadDefinition(
    name: "node.get", description: "Returns one node by stable ID.")
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: NodeIDInput, context: ToolContext) async throws -> OttoNode {
    try await store.requiredNode(input.nodeID, context: context)
  }
}

public struct NodeFocusTool: OttoTool {
  public static let definition = nodeMutationDefinition(
    name: "node.focus", description: "Focuses and raises one node by stable ID.")
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: NodeIDInput, context: ToolContext) async throws -> OttoNode {
    _ = try await store.requiredNode(input.nodeID, context: context)
    _ = try await store.dispatch(.focusNode(input.nodeID), context: context)
    return try await store.requiredNode(input.nodeID, context: context)
  }
}

public struct NodeExpandTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.expand",
    description:
      "Expands one node/window/card/panel as the primary staged item and brings it forward in a single action.",
    inputSchema: nodeIDSchema(description: "Stable UUID of the node to expand"),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: NodeIDInput, context: ToolContext) async throws -> OttoNode {
    _ = try await store.requiredNode(input.nodeID, context: context)
    _ = try await store.dispatch(.focusNode(input.nodeID), context: context)
    _ = try await store.dispatch(.setLayout(.stage), context: context)
    return try await store.requiredNode(input.nodeID, context: context)
  }
}

public struct NodeCreateInput: Codable, Sendable {
  public var kind: NodeKind
  public var x: Double
  public var y: Double

  public init(kind: NodeKind, x: Double, y: Double) {
    self.kind = kind
    self.x = x
    self.y = y
  }
}

public struct NodeCreateOutput: Codable, Sendable, Equatable {
  public var node: OttoNode
  public var message: String
}

public struct NodeCreateTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.create",
    description: "Creates a typed node at a world-coordinate position.",
    inputSchema: .objectSchema(
      properties: [
        "kind": .stringSchema(
          description:
            "Resource kind: agent, terminal, browser, markdown, or media. Use docs.create for documents, spreadsheets and presentations."
        ),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
      ],
      required: ["kind", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore

  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: NodeCreateInput, context: ToolContext) async throws -> NodeCreateOutput
  {
    guard [.agent, .terminal, .browser, .markdown, .media].contains(input.kind) else {
      throw ToolRegistryError.invalidInput(
        "This resource type is retired. Use docs.create for documents and home.add_card for dashboard cards.")
    }
    let receipt = try await store.dispatch(
      .createNode(kind: input.kind, at: WorldPoint(x: input.x, y: input.y)),
      context: context
    )
    guard let id = receipt.affectedNodeIDs.first,
      let node = try await store.canvas(for: context).nodes.first(where: { $0.id == id })
    else {
      throw ToolRegistryError.invalidInput("Node creation produced no node")
    }
    return NodeCreateOutput(node: node, message: receipt.message)
  }
}

public struct NodeCloseInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct MutationOutput: Codable, Sendable, Equatable {
  public var message: String
  public var affectedNodeIDs: [UUID]
}

public struct NodeCloseTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.close",
    description:
      "Closes one Otto node, window, card, or panel by stable ID. Use node.close_all instead when the user asks to close every window or node.",
    inputSchema: .objectSchema(
      properties: ["nodeID": .stringSchema(description: "Stable UUID of the node to close")],
      required: ["nodeID"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  public init(store: CanvasStore, supervisor: AgentSupervisor) {
    self.store = store
    self.supervisor = supervisor
  }

  public func call(_ input: NodeCloseInput, context: ToolContext) async throws -> MutationOutput {
    _ = try await store.requiredNode(input.nodeID, context: context)
    _ = try await supervisor.stopIfPresent(agentID: input.nodeID)
    let receipt = try await store.dispatch(.closeNode(input.nodeID), context: context)
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

public struct NodeCloseAllTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.close_all",
    description:
      "Closes every node/window/card/panel in the active workspace in one action and reports the exact count. Use this directly for 'close all', 'close everything', or plural 'close the windows'; never inspect or close nodes individually first.",
    inputSchema: .emptyObjectSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.globalDestructive],
    riskLevel: .destructive,
    requiresConfirmation: true
  )

  private let store: CanvasStore
  private let supervisor: AgentSupervisor
  public init(store: CanvasStore, supervisor: AgentSupervisor) {
    self.store = store
    self.supervisor = supervisor
  }

  public func call(_ input: NodeListInput, context: ToolContext) async throws -> MutationOutput {
    for node in try await store.canvas(for: context).nodes {
      _ = try await supervisor.stopIfPresent(agentID: node.id)
    }
    let receipt = try await store.dispatch(.closeAll, context: context)
    return MutationOutput(message: receipt.message, affectedNodeIDs: receipt.affectedNodeIDs)
  }
}

extension JSONValue {
  fileprivate static var emptyObjectSchema: JSONValue {
    .objectSchema()
  }
}

private func nodeMutationDefinition(name: String, description: String) -> ToolDefinition {
  let inputSchema: JSONValue
  inputSchema = name == "node.focus"
    ? nodeIDSchema(description: "Stable UUID of the resource to focus") : .objectSchema()
  return ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
}

private func nodeReadDefinition(name: String, description: String) -> ToolDefinition {
  ToolDefinition(
    name: name,
    description: description,
    inputSchema: nodeIDSchema(description: "Stable UUID of the node to inspect"),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
}

private func nodeIDSchema(description: String) -> JSONValue {
  .objectSchema(
    properties: ["nodeID": .stringSchema(description: description)],
    required: ["nodeID"]
  )
}


import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools

public struct CanvasGetInput: Codable, Sendable {
  public init() {}
}

public struct CanvasSummary: Codable, Sendable, Equatable, Identifiable {
  public var id: UUID
  public var name: String
  public var nodeCount: Int
  public var active: Bool
}

public struct CanvasCreateInput: Codable, Sendable {
  public var name: String
  public init(name: String) { self.name = name }
}

public struct CanvasIDInput: Codable, Sendable {
  public var canvasID: UUID
  public init(canvasID: UUID) { self.canvasID = canvasID }
}

public struct CanvasRenameInput: Codable, Sendable {
  public var name: String
  public init(name: String) { self.name = name }
}

public struct NodeIDInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct WhiteboardCreateShapesInput: Codable, Sendable {
  public var nodeID: UUID
  public var shapes: [WhiteboardShape]

  public init(nodeID: UUID, shapes: [WhiteboardShape]) {
    self.nodeID = nodeID
    self.shapes = shapes
  }
}

public struct WhiteboardDeleteShapesInput: Codable, Sendable {
  public var nodeID: UUID
  public var shapeIDs: [String]

  public init(nodeID: UUID, shapeIDs: [String]) {
    self.nodeID = nodeID
    self.shapeIDs = shapeIDs
  }
}

public struct WhiteboardStateOutput: Codable, Equatable, Sendable {
  public var nodeID: UUID
  public var document: String?
  public var pendingActionCount: Int
  public var queuedActionID: UUID?
}

public struct CanvasListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "canvas.list",
    description: "Lists every canvas and identifies the active canvas.",
    inputSchema: .emptyObjectSchema,
    outputSchema: .object(["type": .string("array")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: CanvasGetInput, context: ToolContext) async throws -> [CanvasSummary] {
    let snapshot = await store.snapshot
    return snapshot.canvases.map {
      CanvasSummary(
        id: $0.id,
        name: $0.name,
        nodeCount: $0.nodes.count,
        active: $0.id == snapshot.activeCanvasID
      )
    }
  }
}

public struct CanvasCreateTool: OttoTool {
  public static let definition = canvasMutationDefinition(
    name: "canvas.create", description: "Creates and switches to a new persistent canvas.")
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: CanvasCreateInput, context: ToolContext) async throws -> CanvasSummary {
    _ = await store.dispatch(.createCanvas(name: input.name))
    let canvas = await store.activeCanvas
    return CanvasSummary(id: canvas.id, name: canvas.name, nodeCount: 0, active: true)
  }
}

public struct CanvasSwitchTool: OttoTool {
  public static let definition = canvasMutationDefinition(
    name: "canvas.switch", description: "Switches the active canvas by stable ID.")
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: CanvasIDInput, context: ToolContext) async throws -> CanvasSummary {
    guard await store.snapshot.canvases.contains(where: { $0.id == input.canvasID }) else {
      throw ToolRegistryError.invalidInput("Canvas not found: \(input.canvasID)")
    }
    _ = await store.dispatch(.switchCanvas(input.canvasID))
    let canvas = await store.activeCanvas
    return CanvasSummary(
      id: canvas.id, name: canvas.name, nodeCount: canvas.nodes.count, active: true)
  }
}

public struct CanvasRenameTool: OttoTool {
  public static let definition = canvasMutationDefinition(
    name: "canvas.rename", description: "Renames the active canvas.")
  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }
  public func call(_ input: CanvasRenameInput, context: ToolContext) async throws -> CanvasSummary {
    guard !input.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ToolRegistryError.invalidInput("Canvas name is required")
    }
    _ = try await store.dispatch(.renameCanvas(input.name), context: context)
    let canvas = try await store.canvas(for: context)
    let activeCanvasID = await store.snapshot.activeCanvasID
    return CanvasSummary(
      id: canvas.id,
      name: canvas.name,
      nodeCount: canvas.nodes.count,
      active: canvas.id == activeCanvasID
    )
  }
}

public struct CanvasGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "canvas.get",
    description: "Returns the active canvas and every visible node.",
    inputSchema: .emptyObjectSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: CanvasStore

  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: CanvasGetInput, context: ToolContext) async throws -> OttoCanvas {
    try await store.canvas(for: context)
  }
}

public struct NodeListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "node.list",
    description: "Lists every node on the active canvas.",
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
  public func call(_ input: CanvasGetInput, context: ToolContext) async throws -> [OttoNode] {
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
  public static let definition = canvasMutationDefinition(
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
            "Node kind: agent, terminal, browser, markdown, media, group, connector, whiteboard, or widget. Prefer widget.create for configured custom widgets."
        ),
        "x": .numberSchema(description: "Canvas X position"),
        "y": .numberSchema(description: "Canvas Y position"),
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
    guard input.kind != .gtmGrid else {
      throw ToolRegistryError.invalidInput(
        "GTM Grid has been removed from Otto. Use docs.create with kind spreadsheet for tables.")
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

public struct WhiteboardGetTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "whiteboard.get",
    description:
      "Returns a whiteboard's persisted Excalidraw scene and number of queued canvas actions.",
    inputSchema: nodeIDSchema(description: "Stable UUID of the whiteboard node"),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: NodeIDInput, context: ToolContext) async throws
    -> WhiteboardStateOutput
  {
    let state = try await whiteboardState(nodeID: input.nodeID, store: store, context: context)
    return WhiteboardStateOutput(
      nodeID: input.nodeID,
      document: state.document,
      pendingActionCount: state.pendingActions.count,
      queuedActionID: nil
    )
  }
}

public struct WhiteboardCreateShapesTool: OttoTool {
  public static let definition = whiteboardMutationDefinition(
    name: "whiteboard.create_shapes",
    description:
      "Creates rectangles, ellipses, diamonds, text, notes, or arrows on an Excalidraw whiteboard.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable UUID of the whiteboard node"),
        "shapes": .object([
          "type": .string("array"),
          "items": .objectSchema(
            properties: [
              "id": .stringSchema(description: "Unique stable shape ID"),
              "type": .stringSchema(
                description: "rectangle, ellipse, diamond, text, note, or arrow"),
              "x": .numberSchema(description: "Whiteboard X position"),
              "y": .numberSchema(description: "Whiteboard Y position"),
              "width": .numberSchema(description: "Width; arrow endpoint delta X"),
              "height": .numberSchema(description: "Height; arrow endpoint delta Y"),
              "text": .stringSchema(description: "Optional label"),
              "color": .stringSchema(description: "Optional Excalidraw color name"),
            ],
            required: ["id", "type", "x", "y"]
          ),
        ]),
      ],
      required: ["nodeID", "shapes"]
    )
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: WhiteboardCreateShapesInput, context: ToolContext) async throws
    -> WhiteboardStateOutput
  {
    guard !input.shapes.isEmpty, input.shapes.count <= 200 else {
      throw ToolRegistryError.invalidInput("Provide between 1 and 200 whiteboard shapes")
    }
    let allowedColors: Set<String> = [
      "black", "blue", "green", "grey", "light-blue", "light-green", "light-red",
      "light-violet", "orange", "red", "violet", "white", "yellow",
    ]
    var seenIDs: Set<String> = []
    for shape in input.shapes {
      guard shape.x.isFinite, shape.y.isFinite,
        shape.width?.isFinite != false, shape.height?.isFinite != false
      else { throw ToolRegistryError.invalidInput("Shape geometry must be finite") }
      guard !shape.id.isEmpty, seenIDs.insert(shape.id).inserted else {
        throw ToolRegistryError.invalidInput("Every shape needs a unique non-empty ID")
      }
      if let width = shape.width, width <= 0, shape.type != .arrow {
        throw ToolRegistryError.invalidInput("Shape widths must be positive")
      }
      if let height = shape.height, height <= 0, shape.type != .arrow {
        throw ToolRegistryError.invalidInput("Shape heights must be positive")
      }
      if let color = shape.color, !allowedColors.contains(color) {
        throw ToolRegistryError.invalidInput("Unsupported Excalidraw color: \(color)")
      }
    }
    return try await queueWhiteboardAction(
      nodeID: input.nodeID,
      action: WhiteboardAction(kind: .createShapes, shapes: input.shapes),
      store: store,
      context: context
    )
  }
}

public struct WhiteboardDeleteShapesTool: OttoTool {
  public static let definition = whiteboardMutationDefinition(
    name: "whiteboard.delete_shapes",
    description: "Deletes shapes from an Excalidraw whiteboard by stable shape ID.",
    inputSchema: .objectSchema(
      properties: [
        "nodeID": .stringSchema(description: "Stable UUID of the whiteboard node"),
        "shapeIDs": .object([
          "type": .string("array"),
          "items": .object(["type": .string("string")]),
        ]),
      ],
      required: ["nodeID", "shapeIDs"]
    )
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: WhiteboardDeleteShapesInput, context: ToolContext) async throws
    -> WhiteboardStateOutput
  {
    guard !input.shapeIDs.isEmpty else {
      throw ToolRegistryError.invalidInput("At least one shape ID is required")
    }
    return try await queueWhiteboardAction(
      nodeID: input.nodeID,
      action: WhiteboardAction(kind: .deleteShapes, shapeIDs: input.shapeIDs),
      store: store,
      context: context
    )
  }
}

public struct WhiteboardClearTool: OttoTool {
  public static let definition = whiteboardMutationDefinition(
    name: "whiteboard.clear",
    description: "Deletes every shape from an Excalidraw whiteboard.",
    inputSchema: nodeIDSchema(description: "Stable UUID of the whiteboard node"),
    destructive: true
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: NodeIDInput, context: ToolContext) async throws
    -> WhiteboardStateOutput
  {
    try await queueWhiteboardAction(
      nodeID: input.nodeID,
      action: WhiteboardAction(kind: .clear),
      store: store,
      context: context
    )
  }
}

public struct WhiteboardFitTool: OttoTool {
  public static let definition = whiteboardMutationDefinition(
    name: "whiteboard.fit",
    description: "Fits all shapes into the visible Excalidraw whiteboard viewport.",
    inputSchema: nodeIDSchema(description: "Stable UUID of the whiteboard node")
  )

  private let store: CanvasStore
  public init(store: CanvasStore) { self.store = store }

  public func call(_ input: NodeIDInput, context: ToolContext) async throws
    -> WhiteboardStateOutput
  {
    try await queueWhiteboardAction(
      nodeID: input.nodeID,
      action: WhiteboardAction(kind: .fit),
      store: store,
      context: context
    )
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
      "Closes every node/window/card/panel on the active canvas in one action and reports the exact count. Use this directly for 'close all', 'close everything', or plural 'close the windows'; never inspect or close nodes individually first.",
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

  public func call(_ input: CanvasGetInput, context: ToolContext) async throws -> MutationOutput {
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

private func canvasMutationDefinition(name: String, description: String) -> ToolDefinition {
  let inputSchema: JSONValue
  switch name {
  case "canvas.create", "canvas.rename":
    inputSchema = .objectSchema(
      properties: ["name": .stringSchema(description: "Canvas name")],
      required: ["name"]
    )
  case "canvas.switch":
    inputSchema = .objectSchema(
      properties: ["canvasID": .stringSchema(description: "Stable canvas UUID")],
      required: ["canvasID"]
    )
  case "node.focus":
    inputSchema = nodeIDSchema(description: "Stable UUID of the node to focus and bring forward")
  default:
    inputSchema = .objectSchema()
  }
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

private func whiteboardMutationDefinition(
  name: String,
  description: String,
  inputSchema: JSONValue,
  destructive: Bool = false
) -> ToolDefinition {
  ToolDefinition(
    name: name,
    description: description,
    inputSchema: inputSchema,
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [destructive ? .globalDestructive : .canvasWrite],
    riskLevel: destructive ? .destructive : .reversible,
    requiresConfirmation: destructive
  )
}

private func whiteboardState(
  nodeID: UUID,
  store: CanvasStore,
  context: ToolContext
) async throws -> (document: String?, pendingActions: [WhiteboardAction]) {
  let node = try await store.requiredNode(nodeID, context: context)
  guard node.kind == .whiteboard,
    case .whiteboard(let document, let pendingActions) = node.content
  else { throw ToolRegistryError.invalidInput("Node \(nodeID) is not a whiteboard") }
  return (document, pendingActions)
}

private func queueWhiteboardAction(
  nodeID: UUID,
  action: WhiteboardAction,
  store: CanvasStore,
  context: ToolContext
) async throws -> WhiteboardStateOutput {
  var state = try await whiteboardState(nodeID: nodeID, store: store, context: context)
  state.pendingActions.append(action)
  _ = try await store.dispatch(
    .setNodeContent(
      id: nodeID,
      content: .whiteboard(document: state.document, pendingActions: state.pendingActions)
    ),
    context: context
  )
  return WhiteboardStateOutput(
    nodeID: nodeID,
    document: state.document,
    pendingActionCount: state.pendingActions.count,
    queuedActionID: action.id
  )
}

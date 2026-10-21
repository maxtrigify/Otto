import Foundation
import OttoCore
import OttoMedia
import OttoModels
import OttoTools

public struct MediaOpenInput: Codable, Sendable {
  public var source: String
  public var x: Double
  public var y: Double
  public init(source: String, x: Double, y: Double) {
    self.source = source
    self.x = x
    self.y = y
  }
}

public struct MediaNodeInput: Codable, Sendable {
  public var nodeID: UUID
  public init(nodeID: UUID) { self.nodeID = nodeID }
}

public struct MediaVolumeInput: Codable, Sendable {
  public var nodeID: UUID
  public var volume: Double
  public init(nodeID: UUID, volume: Double) {
    self.nodeID = nodeID
    self.volume = volume
  }
}

public struct MediaSeekInput: Codable, Sendable {
  public var nodeID: UUID
  public var position: Double
  public init(nodeID: UUID, position: Double) {
    self.nodeID = nodeID
    self.position = position
  }
}

public struct MediaOpenTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "media.open",
    description: "Creates a media node for a workspace audio/video file or HTTP(S) media URL.",
    inputSchema: .objectSchema(
      properties: [
        "source": .stringSchema(description: "Workspace audio/video path or HTTP(S) media URL"),
        "x": .numberSchema(description: "Internal resource X position"),
        "y": .numberSchema(description: "Internal resource Y position"),
      ],
      required: ["source", "x", "y"]
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
  private let store: CanvasStore
  private let runtime: MediaRuntime
  private let workspacePath: String

  public init(store: CanvasStore, runtime: MediaRuntime, workspacePath: String) {
    self.store = store
    self.runtime = runtime
    self.workspacePath = workspacePath
  }

  public func call(_ input: MediaOpenInput, context: ToolContext) async throws -> NodeCreateOutput {
    let source = try validatedMediaSource(input.source, workspacePath: workspacePath)
    let receipt = try await store.dispatch(
      .createNode(kind: .media, at: WorldPoint(x: input.x, y: input.y)),
      context: context
    )
    guard let id = receipt.affectedNodeIDs.first else {
      throw ToolRegistryError.invalidInput("Media creation failed")
    }
    _ = try await store.dispatch(
      .setNodeContent(id: id, content: .media(source: source)),
      context: context
    )
    await runtime.register(nodeID: id, source: source)
    guard let node = try await store.canvas(for: context).nodes.first(where: { $0.id == id }) else {
      throw ToolRegistryError.invalidInput("Media creation produced no node")
    }
    return NodeCreateOutput(node: node, message: receipt.message)
  }
}

public struct MediaPlayTool: OttoTool {
  public static let definition = mediaCommandDefinition(
    name: "media.play", description: "Starts playback for a media node.")
  private let store: CanvasStore
  private let runtime: MediaRuntime
  public init(store: CanvasStore, runtime: MediaRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: MediaNodeInput, context: ToolContext) async throws -> MediaRuntimeState
  {
    try await ensureMediaSession(
      input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.play(nodeID: input.nodeID)
  }
}

public struct MediaPauseTool: OttoTool {
  public static let definition = mediaCommandDefinition(
    name: "media.pause", description: "Pauses playback for a media node.")
  private let store: CanvasStore
  private let runtime: MediaRuntime
  public init(store: CanvasStore, runtime: MediaRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: MediaNodeInput, context: ToolContext) async throws -> MediaRuntimeState
  {
    try await ensureMediaSession(
      input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.pause(nodeID: input.nodeID)
  }
}

public struct MediaStopTool: OttoTool {
  public static let definition = mediaCommandDefinition(
    name: "media.stop", description: "Stops playback and seeks a media node to the start.")
  private let store: CanvasStore
  private let runtime: MediaRuntime
  public init(store: CanvasStore, runtime: MediaRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: MediaNodeInput, context: ToolContext) async throws -> MediaRuntimeState
  {
    try await ensureMediaSession(
      input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.stop(nodeID: input.nodeID)
  }
}

public struct MediaSetVolumeTool: OttoTool {
  public static let definition = mediaCommandDefinition(
    name: "media.set_volume", description: "Sets media-node volume from zero to one.")
  private let store: CanvasStore
  private let runtime: MediaRuntime
  public init(store: CanvasStore, runtime: MediaRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: MediaVolumeInput, context: ToolContext) async throws
    -> MediaRuntimeState
  {
    try await ensureMediaSession(
      input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.setVolume(nodeID: input.nodeID, volume: input.volume)
  }
}

public struct MediaSeekTool: OttoTool {
  public static let definition = mediaCommandDefinition(
    name: "media.seek", description: "Seeks a media node to a position in seconds.")
  private let store: CanvasStore
  private let runtime: MediaRuntime
  public init(store: CanvasStore, runtime: MediaRuntime) {
    self.store = store
    self.runtime = runtime
  }
  public func call(_ input: MediaSeekInput, context: ToolContext) async throws -> MediaRuntimeState
  {
    try await ensureMediaSession(
      input.nodeID, store: store, runtime: runtime, context: context)
    return try await runtime.seek(nodeID: input.nodeID, position: input.position)
  }
}

private func mediaCommandDefinition(name: String, description: String) -> ToolDefinition {
  let properties: [String: JSONValue]
  let required: [String]
  switch name {
  case "media.set_volume":
    properties = [
      "nodeID": .stringSchema(description: "Stable media node UUID"),
      "volume": .numberSchema(description: "Volume from zero through one"),
    ]
    required = ["nodeID", "volume"]
  case "media.seek":
    properties = [
      "nodeID": .stringSchema(description: "Stable media node UUID"),
      "position": .numberSchema(description: "Playback position in seconds"),
    ]
    required = ["nodeID", "position"]
  default:
    properties = ["nodeID": .stringSchema(description: "Stable media node UUID")]
    required = ["nodeID"]
  }
  return ToolDefinition(
    name: name,
    description: description,
    inputSchema: .objectSchema(properties: properties, required: required),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )
}

private func ensureMediaSession(
  _ nodeID: UUID,
  store: CanvasStore,
  runtime: MediaRuntime,
  context: ToolContext
) async throws {
  if await runtime.state(nodeID: nodeID) != nil { return }
  let node = try await store.requiredNode(nodeID, context: context)
  guard case .media(let source) = node.content,
    !source.isEmpty
  else {
    throw ToolRegistryError.invalidInput("Node is not configured media")
  }
  await runtime.register(nodeID: nodeID, source: source)
}

private func validatedMediaSource(_ value: String, workspacePath: String) throws -> String {
  if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) {
    return url.absoluteString
  }
  let root = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
  let candidate = URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL
  guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/"),
    FileManager.default.fileExists(atPath: candidate.path)
  else {
    throw ToolRegistryError.invalidInput("Local media must exist inside the active workspace")
  }
  return candidate.absoluteString
}

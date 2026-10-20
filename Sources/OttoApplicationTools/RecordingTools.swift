import Foundation
import OttoCore
import OttoMedia
import OttoModels
import OttoTools

public struct RecordingStartInput: Codable, Sendable {
  public init() {}
}

public struct RecordingStartOutput: Codable, Sendable, Equatable {
  public var path: String
  public var message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

public struct RecordingStopInput: Codable, Sendable {
  /// Where to place the finished recording's media node on the canvas; defaults keep it near
  /// the origin cluster when the caller has no better position.
  public var x: Double?
  public var y: Double?

  public init(x: Double? = nil, y: Double? = nil) {
    self.x = x
    self.y = y
  }
}

public struct RecordingStopOutput: Codable, Sendable, Equatable {
  public var path: String
  public var durationSeconds: Double
  public var nodeID: UUID?
  public var message: String

  public init(path: String, durationSeconds: Double, nodeID: UUID?, message: String) {
    self.path = path
    self.durationSeconds = durationSeconds
    self.nodeID = nodeID
    self.message = message
  }
}

public struct RecordingStatusInput: Codable, Sendable {
  public init() {}
}

/// Starts recording the Otto window to an .mp4 in the workspace's Recordings folder. The
/// capture is a screen recording of the whole canvas window, so everything the user sees —
/// browser nodes, terminals, agent activity — lands in the video.
public struct RecordingStartTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recording.start",
    description:
      "Starts a screen recording of the Otto canvas window into the workspace's Recordings folder. For a demo of one node (for example a browser walkthrough), stage that node first with layout.stage so it fills the canvas, then start recording and drive it. Stop with recording.stop. Requires the user's one-time macOS Screen Recording permission.",
    inputSchema: .objectSchema(properties: [:], required: []),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential
  )

  private let recorder: CanvasRecorder
  private let workspacePath: String

  public init(recorder: CanvasRecorder, workspacePath: String) {
    self.recorder = recorder
    self.workspacePath = workspacePath
  }

  public func call(_ input: RecordingStartInput, context: ToolContext) async throws
    -> RecordingStartOutput
  {
    let directory = (workspacePath as NSString).appendingPathComponent("Recordings")
    let path = try await recorder.start(directory: directory)
    return RecordingStartOutput(
      path: path,
      message: "Recording the canvas to \(path). Call recording.stop to finish."
    )
  }
}

/// Stops the active recording and drops the finished video onto the canvas as a media node so
/// the user can review it immediately.
public struct RecordingStopTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recording.stop",
    description:
      "Stops the active canvas recording, saves the .mp4, and places it on the canvas as a playable media node. Returns the file path and duration.",
    inputSchema: .objectSchema(
      properties: [
        "x": .numberSchema(description: "Canvas X for the media node (optional)"),
        "y": .numberSchema(description: "Canvas Y for the media node (optional)"),
      ],
      required: []
    ),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasWrite],
    riskLevel: .reversible
  )

  private let recorder: CanvasRecorder
  private let store: CanvasStore
  private let mediaRuntime: MediaRuntime

  public init(recorder: CanvasRecorder, store: CanvasStore, mediaRuntime: MediaRuntime) {
    self.recorder = recorder
    self.store = store
    self.mediaRuntime = mediaRuntime
  }

  public func call(_ input: RecordingStopInput, context: ToolContext) async throws
    -> RecordingStopOutput
  {
    let result = try await recorder.stop()
    let point = WorldPoint(x: input.x ?? 320, y: input.y ?? 220)
    let source = URL(fileURLWithPath: result.path).absoluteString
    var nodeID: UUID?
    // The recording is already safe on disk; canvas placement failing (unlikely) should not
    // turn a successful capture into a tool error.
    if let receipt = try? await store.dispatch(
      .createNode(kind: .media, at: point), context: context),
      let id = receipt.affectedNodeIDs.first
    {
      _ = try? await store.dispatch(
        .setNodeContent(id: id, content: .media(source: source)), context: context)
      await mediaRuntime.register(nodeID: id, source: source)
      nodeID = id
    }
    let seconds = Int(result.durationSeconds.rounded())
    return RecordingStopOutput(
      path: result.path,
      durationSeconds: result.durationSeconds,
      nodeID: nodeID,
      message:
        "Saved a \(seconds)s recording to \(result.path)\(nodeID == nil ? "" : " and opened it on the canvas")."
    )
  }
}

public struct RecordingStatusTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "recording.status",
    description:
      "Reports whether a canvas recording is running, its file path, and elapsed seconds.",
    inputSchema: .objectSchema(properties: [:], required: []),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  private let recorder: CanvasRecorder

  public init(recorder: CanvasRecorder) {
    self.recorder = recorder
  }

  public func call(_ input: RecordingStatusInput, context: ToolContext) async throws
    -> CanvasRecordingStatus
  {
    await recorder.status()
  }
}

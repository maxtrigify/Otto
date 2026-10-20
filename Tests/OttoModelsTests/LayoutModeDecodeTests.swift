import Foundation
import OttoModels
import Testing

@Suite("Layout mode decode")
struct LayoutModeDecodeTests {
  @Test("Unknown layout modes fall back instead of failing the workspace")
  func unknownLayoutModeIsFreeform() throws {
    let data = Data(#""not-a-real-layout""#.utf8)
    let mode = try JSONDecoder().decode(LayoutMode.self, from: data)
    #expect(mode == .freeform)
  }

  @Test("Chat is no longer a canvas layout")
  func chatIsNotACanvasLayout() throws {
    #expect(LayoutMode.allCases.map(\.rawValue).contains("chat") == false)
    let legacy = try JSONDecoder().decode(LayoutMode.self, from: Data(#""chat""#.utf8))
    #expect(legacy == .freeform)
  }

  @Test("Legacy active Chat layout migrates to Chat plus geometry-preserving freeform")
  func legacyActiveChatLayoutMigrates() throws {
    let nodeID = UUID()
    let canvas = OttoCanvas(
      name: "Legacy chat",
      viewport: Viewport(centerX: 410, centerY: -230, scale: 1.7),
      nodes: [
        OttoNode(
          id: nodeID,
          kind: .markdown,
          displayName: "Brief",
          subtitle: "MARKDOWN",
          frame: WorldRect(x: 121, y: -88, width: 511, height: 377),
          zIndex: 0
        )
      ],
      selectedNodeID: nodeID,
      layoutMode: .grid
    )
    let snapshot = WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    let legacyData = try legacySnapshotData(snapshot, chatCanvasIndex: 0)

    let migrated = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyData)

    #expect(migrated.workspaceSurface == .chat)
    #expect(migrated.canvases[0].layoutMode == .freeform)
    #expect(migrated.canvases[0].nodes[0].frame == canvas.nodes[0].frame)
    #expect(migrated.canvases[0].viewport == canvas.viewport)
    #expect(migrated.canvases[0].selectedNodeID == nodeID)
  }

  @Test("An inactive legacy Chat canvas migrates spatially and the workspace opens in Chat")
  func inactiveLegacyChatLayoutMigratesSpatially() throws {
    let legacyCanvas = OttoCanvas(name: "Old chat", layoutMode: .grid)
    let activeCanvas = OttoCanvas(name: "Current", layoutMode: .columns)
    let snapshot = WorkspaceSnapshot(
      canvases: [legacyCanvas, activeCanvas],
      activeCanvasID: activeCanvas.id
    )
    let legacyData = try legacySnapshotData(snapshot, chatCanvasIndex: 0)

    let migrated = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyData)

    #expect(migrated.workspaceSurface == .chat)
    #expect(migrated.canvases[0].layoutMode == .freeform)
    #expect(migrated.canvases[1].layoutMode == .columns)
  }

  @Test("A workspace saved on the retired Canvas surface still loads, in Chat")
  func retiredCanvasSurfaceDecodesAsChat() throws {
    let canvas = OttoCanvas(name: "Board", layoutMode: .stage)
    let snapshot = WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    object["workspaceSurface"] = "canvas"

    let restored = try JSONDecoder().decode(
      WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(restored.workspaceSurface == .chat)
    #expect(restored.canvases == snapshot.canvases)
    #expect(restored.activeCanvasID == canvas.id)
  }

  @Test("Workspace surface and Chat navigation round trip independently")
  func workspaceNavigationRoundTrip() throws {
    let canvas = OttoCanvas(name: "Canvas", layoutMode: .stage)
    let profileID = UUID()
    let navigation = ChatSurfaceNavigationState(
      selectedProfileID: profileID,
      selectedAgentID: UUID(),
      sidebarList: .bots,
      destination: .conversation,
      libraryCanvasID: canvas.id
    )
    let snapshot = WorkspaceSnapshot(
      canvases: [canvas],
      activeCanvasID: canvas.id,
      workspaceSurface: .chat,
      chatNavigation: navigation
    )

    let restored = try JSONDecoder().decode(
      WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))

    #expect(restored == snapshot)
    #expect(restored.canvases[0].layoutMode == .stage)
    #expect(restored.chatNavigation.selectedProfileID == profileID)
  }

  private func legacySnapshotData(_ snapshot: WorkspaceSnapshot, chatCanvasIndex: Int) throws
    -> Data
  {
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    var canvases = try #require(object["canvases"] as? [[String: Any]])
    canvases[chatCanvasIndex]["layoutMode"] = "chat"
    object["canvases"] = canvases
    object.removeValue(forKey: "workspaceSurface")
    object.removeValue(forKey: "chatNavigation")
    return try JSONSerialization.data(withJSONObject: object)
  }
}

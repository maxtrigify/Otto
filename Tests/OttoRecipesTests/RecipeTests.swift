import Foundation
import OttoCore
import OttoModels
import OttoRecipes
import Testing

@MainActor
@Suite("Recipe validation and boot")
struct RecipeTests {
  @Test("Validated recipe boots typed nodes through shared commands")
  func boot() throws {
    let canvas = OttoCanvas(name: "Recipe")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let recipe = RecipeDefinition(
      id: "review-workspace",
      name: "Review workspace",
      description: "Agent, browser, and goals document",
      nodes: [
        RecipeNode(kind: .agent, x: 0, y: 0),
        RecipeNode(kind: .browser, x: 450, y: 0, content: .browser(url: "http://localhost:3000")),
        RecipeNode(
          kind: .markdown,
          x: 0,
          y: 340,
          content: .markdown(relativePath: "goals.md", text: "# Goals\n")),
      ],
      themeID: "halcyon",
      layoutMode: .organized
    )

    let ids = try RecipeEngine.boot(recipe, into: store)
    #expect(ids.count == 3)
    #expect(store.activeCanvas.nodes.count == 3)
    #expect(store.activeCanvas.themeID == "halcyon")
    #expect(store.activeCanvas.layoutMode == .grid)
  }

  @Test("Rejects embedded credentials and workspace escapes")
  func validation() {
    let secret = RecipeDefinition(
      id: "bad",
      name: "Bad",
      description: "api_key=do-not-store-this",
      nodes: []
    )
    #expect(throws: RecipeError.self) { try RecipeValidator.validate(secret) }

    let escape = RecipeDefinition(
      id: "escape",
      name: "Escape",
      description: "Bad path",
      nodes: [
        RecipeNode(
          kind: .markdown,
          x: 0,
          y: 0,
          content: .markdown(relativePath: "../outside.md", text: "no"))
      ]
    )
    #expect(throws: RecipeError.self) { try RecipeValidator.validate(escape) }

    let credentialURL = RecipeDefinition(
      id: "credential-url",
      name: "Credential URL",
      description: "Must fail",
      nodes: [
        RecipeNode(
          kind: .browser,
          x: 0,
          y: 0,
          content: .browser(url: "https://example.com?access_token=secret"))
      ]
    )
    #expect(throws: RecipeError.self) { try RecipeValidator.validate(credentialURL) }
  }

  @Test("Recipe store reloads versioned definitions from disk")
  func persistence() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-recipes-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let definition = RecipeDefinition(
      id: "persisted-workspace",
      name: "Persisted workspace",
      version: 3,
      description: "Stored on disk",
      nodes: [RecipeNode(kind: .terminal, x: 10, y: 20, content: .terminal(shell: "/bin/zsh"))]
    )

    let first = RecipeStore(directoryURL: directory)
    let saved = try await first.save(definition)
    #expect(saved.definition.version == 3)

    let restored = RecipeStore(directoryURL: directory)
    let records = try await restored.list()
    #expect(records.map(\.definition) == [definition])
    let restoredCreatedAt = try #require(records.first?.createdAt)
    #expect(abs(restoredCreatedAt.timeIntervalSince(saved.createdAt)) < 1)
  }

  @Test("Labels, groups, and connectors round-trip through recipe capture and boot")
  func lightweightSpatialNodes() throws {
    let sourceCanvas = OttoCanvas(name: "Spatial tools")
    let sourceStore = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [sourceCanvas], activeCanvasID: sourceCanvas.id)
    )
    let label = try #require(
      sourceStore.dispatch(.createNode(kind: .label, at: WorldPoint(x: 20, y: 30)))
        .affectedNodeIDs.first
    )
    sourceStore.dispatch(.setNodeContent(id: label, content: .label(text: "Release boundary")))
    _ = sourceStore.dispatch(.createNode(kind: .group, at: WorldPoint(x: 100, y: 120)))
    _ = sourceStore.dispatch(.createNode(kind: .connector, at: WorldPoint(x: 400, y: 160)))
    let recipe = RecipeCapture.capture(
      id: "spatial-tools",
      name: "Spatial tools",
      description: "Lightweight canvas structure",
      version: 1,
      canvas: sourceStore.activeCanvas
    )
    try RecipeValidator.validate(recipe)

    let destinationCanvas = OttoCanvas(name: "Booted")
    let destination = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [destinationCanvas],
        activeCanvasID: destinationCanvas.id
      )
    )
    _ = try RecipeEngine.boot(recipe, into: destination)
    #expect(destination.activeCanvas.nodes.map(\.kind) == [.label, .group, .connector])
    #expect(destination.activeCanvas.nodes.first?.content == .label(text: "Release boundary"))
    #expect(destination.activeCanvas.nodes[1].content == .group)
    #expect(
      destination.activeCanvas.nodes[2].content
        == .connector(sourceNodeID: nil, targetNodeID: nil)
    )
  }

  @Test("Whiteboards round-trip through recipe capture and boot")
  func whiteboardRoundTrip() throws {
    let sourceCanvas = OttoCanvas(name: "Visual plan")
    let source = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [sourceCanvas], activeCanvasID: sourceCanvas.id))
    let id = try #require(
      source.dispatch(.createNode(kind: .whiteboard, at: WorldPoint(x: 40, y: 60)))
        .affectedNodeIDs.first)
    let content = NodeContent.whiteboard(
      document: "{\"store\":{}}",
      pendingActions: [
        WhiteboardAction(
          kind: .createShapes,
          shapes: [WhiteboardShape(type: .note, x: 80, y: 90, text: "Review")]
        )
      ]
    )
    source.dispatch(.setNodeContent(id: id, content: content))
    let recipe = RecipeCapture.capture(
      id: "visual-plan",
      name: "Visual plan",
      description: "Whiteboard recipe",
      version: 1,
      canvas: source.activeCanvas
    )
    try RecipeValidator.validate(recipe)

    let destinationCanvas = OttoCanvas(name: "Destination")
    let destination = CanvasStore(
      snapshot: WorkspaceSnapshot(
        canvases: [destinationCanvas], activeCanvasID: destinationCanvas.id))
    _ = try RecipeEngine.boot(recipe, into: destination)
    #expect(destination.activeCanvas.nodes.first?.kind == .whiteboard)
    #expect(destination.activeCanvas.nodes.first?.content == content)
  }
}

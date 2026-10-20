import Foundation
import OttoCore
import OttoModels
import Testing

@testable import OttoServices

@MainActor
@Suite("Bot share manifests")
struct BotSharingTests {
  @Test("Export contains only portable fields and import grants no connections")
  func portableRoundTrip() throws {
    let sourceRoot = temporaryWorkspace()
    let targetRoot = temporaryWorkspace()
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: targetRoot)
    }
    let source = services(at: sourceRoot)
    let profile = try source.createBot(
      BotCreationRequest(
        name: "Scout",
        responsibility: "Research competitors",
        skillIDs: ["web-research"],
        avatarRef: "🦉",
        colorHex: "#397b69"
      ))
    _ = try source.botConnections.save(
      BotIntegration(
        id: "notion", name: "Notion", kind: .mcpServer, keychainRef: "otto:notion"))
    try source.botConnections.setAllowlist(profileID: profile.id, integrationIDs: ["notion"])
    _ = try source.botNotes.add(profileID: profile.id, body: "Private customer context")

    let manifest = try source.exportBotShareManifest(profileID: profile.id)
    let encoded = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    #expect(!encoded.contains(profile.id.uuidString))
    #expect(!encoded.contains("Private customer context"))
    #expect(!encoded.contains("keychainRef"))
    #expect(!encoded.contains("photoRelativePath"))
    #expect(manifest.suggestedConnectionIDs == ["notion"])

    let target = services(at: targetRoot)
    let imported = try target.importBotShareManifest(manifest)
    #expect(imported.name == "Scout")
    #expect(imported.skillIDs == ["web-research"])
    #expect(target.botConnections.allowlists[imported.id] == [])
  }

  @Test("Validation rejects secrets, machine paths, and unknown schema versions")
  func rejectsPrivateData() throws {
    let defaults = BotShareExecutionDefaults(provider: .codex)
    #expect(throws: BotShareManifestError.self) {
      try ApplicationServices.validateBotShareManifest(
        BotShareManifest(
          name: "Unsafe", role: "Research", instructions: "Use sk-proj-private",
          executionDefaults: defaults))
    }
    #expect(throws: BotShareManifestError.self) {
      try ApplicationServices.validateBotShareManifest(
        BotShareManifest(
          name: "Unsafe", role: "Research", instructions: "Read /Users/alice/private.txt",
          executionDefaults: defaults))
    }
    #expect(throws: BotShareManifestError.self) {
      try ApplicationServices.validateBotShareManifest(
        BotShareManifest(
          schemaVersion: 99, name: "Future", role: "Research", instructions: "Work safely",
          executionDefaults: defaults))
    }
  }

  private func services(at root: URL) -> ApplicationServices {
    let canvas = OttoCanvas(name: "Bots")
    return ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: root.path)
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-share-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

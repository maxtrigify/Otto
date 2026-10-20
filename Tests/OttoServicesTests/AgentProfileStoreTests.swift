import Foundation
import OttoCore
import OttoModels
import OttoServices
import Testing

@MainActor
@Suite("Custom agent profiles")
struct AgentProfileStoreTests {
  @Test("Account preference persists and older profiles inherit defaults")
  func accountPreferenceRoundTrip() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let saved = try AgentProfileStore(workspacePath: root.path).save(
      AgentProfile(name: "Personal bot", instructions: "Help", provider: .codex, accountID: id))
    #expect(AgentProfileStore(workspacePath: root.path).profile(id: saved.id)?.accountID == id)
    let data = try JSONEncoder().encode(saved)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "accountID")
    let restored = try JSONDecoder().decode(
      AgentProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.accountID == nil)
  }

  @Test("Profiles persist with stable identity and incrementing revisions")
  func persistenceAndRevision() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentProfileStore(workspacePath: root.path)

    var buz = try store.save(
      AgentProfile(
        name: " Buz ", role: "PR reviewer", instructions: "Review every changed file.",
        provider: .codex))
    #expect(buz.name == "Buz")
    #expect(buz.revision == 1)

    buz.instructions = "Review correctness, security, and tests."
    buz = try store.save(buz)
    #expect(buz.revision == 2)

    let restored = AgentProfileStore(workspacePath: root.path)
    #expect(restored.profile(id: buz.id)?.name == buz.name)
    #expect(restored.profile(id: buz.id)?.instructions == buz.instructions)
    #expect(restored.profile(id: buz.id)?.revision == buz.revision)
    #expect(restored.exactMatch(name: "bUz")?.id == buz.id)
  }

  @Test("Names are unique case-insensitively and v1 providers are bounded")
  func validation() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentProfileStore(workspacePath: root.path)
    _ = try store.save(
      AgentProfile(
        name: "Wang", instructions: "Create implementation plans.", provider: .claudeCode))

    #expect(throws: AgentProfileValidationError.duplicateName) {
      try store.save(
        AgentProfile(name: " wang ", instructions: "Duplicate.", provider: .codex))
    }
    #expect(throws: AgentProfileValidationError.unsupportedProvider) {
      try store.save(
        AgentProfile(name: "Other", instructions: "Unsupported.", provider: .shell))
    }
  }

  @Test("Archived bot names can be reused without reviving the old identity")
  func archivedNameReuse() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentProfileStore(workspacePath: root.path)
    let old = try store.save(AgentProfile(name: "Nova", instructions: "Old bot.", provider: .codex))
    try store.archive(id: old.id)
    let replacement = try store.save(
      AgentProfile(name: " nóva ", instructions: "New bot.", provider: .codex))
    #expect(old.id != replacement.id)
    let reloaded = AgentProfileStore(workspacePath: root.path)
    #expect(reloaded.exactMatch(name: "NOVA")?.id == replacement.id)
    #expect(reloaded.profile(id: old.id)?.isArchived == true)
    #expect(throws: AgentProfileValidationError.duplicateName) {
      try reloaded.restore(id: old.id)
    }
    #expect(reloaded.profile(id: old.id)?.isArchived == true)
    try reloaded.archive(id: replacement.id)
    try reloaded.restore(id: old.id)
    #expect(reloaded.exactMatch(name: "Nova")?.id == old.id)
  }

  @Test("Opening an existing profile restores a visible conversation and focuses it")
  func openingExistingProfile() async throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = AgentProfile(
      name: "Buz", instructions: "Review changes.", provider: .codex)
    let node = OttoNode(
      kind: .agent,
      displayName: profile.name,
      subtitle: "CODEX · LOCAL",
      frame: WorldRect(x: 0, y: 0, width: 420, height: 270),
      zIndex: 0,
      content: .agent(provider: .codex),
      agentDefinition: AgentDefinition(
        provider: .codex,
        workingDirectory: root.path,
        launchCommand: "codex",
        permissionMode: "workspaceWrite",
        profileID: profile.id,
        profileRevision: profile.revision,
        profileInstructions: profile.instructions
      ),
      presentationMode: .compact
    )
    let canvas = OttoCanvas(name: "Profiles", nodes: [node])
    let canvasStore = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let services = ApplicationServices(store: canvasStore, workspacePath: root.path)

    let openedID = try await services.openAgentProfile(
      profile, at: WorldPoint(x: 100, y: 100))

    #expect(openedID == node.id)
    #expect(canvasStore.activeCanvas.selectedNodeID == node.id)
    #expect(canvasStore.activeCanvas.nodes.first?.presentationMode == .conversation)
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-agent-profiles-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

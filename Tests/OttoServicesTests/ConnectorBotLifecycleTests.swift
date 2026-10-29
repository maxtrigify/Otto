import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

private actor LifecycleGoogle {
  func call(_ request: URLRequest) -> (Data, HTTPURLResponse) {
    (
      Data("{\"messages\": []}".utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

@MainActor
@Suite("Connector access follows bot lifecycle", .serialized)
struct ConnectorBotLifecycleTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-lifecycle-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("Rename keeps access, archive removes it, restore returns it")
  func lifecycle() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let google = LifecycleGoogle()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await google.call($0) }))
    try await apps.install(
      GmailConnection(
        id: UUID(), email: "fixture@example.com", scopes: [AppConnectionsStore.readScope],
        needsReconnect: false, shared: true, createdAt: .now),
      credential: GoogleCredential(
        accessToken: "a", refreshToken: "r", expiresAt: .now.addingTimeInterval(3600),
        clientID: "fixture.apps.googleusercontent.com"))

    let canvas = OttoCanvas(name: "Lifecycle")
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let supervisor = AgentSupervisor()
    let services = ApplicationServices(
      store: store, supervisor: supervisor, secrets: InMemorySecretStore(),
      appConnections: apps, workspacePath: root.path)
    try await services.registerAppConnectionTools()

    let profile = try services.saveAgentProfile(
      AgentProfile(name: "Scout", instructions: "Test", provider: .codex))
    try services.connectorAccess.setAllowed(true, profileID: profile.id, for: .gmail)

    let id = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    var definition = AgentDefinition(
      provider: .codex, workingDirectory: root.path,
      launchCommand: "fixture", permissionMode: "workspaceWrite")
    definition.profileID = profile.id
    store.dispatch(.setAgentDefinition(id: id, definition: definition))
    _ = try await supervisor.spawn(
      provider: .codex,
      specification: ProcessLaunchSpec(
        executable: "/bin/cat", arguments: [], workingDirectory: root.path), id: id)
    let context = ToolContext(
      actorID: "fixture", scopes: [.agentRead], source: .agent, sourceNodeID: id)

    func gmailVisible() async -> Bool {
      await services.registry.definitions(for: context).map(\.name).contains("gmail.search")
    }

    // Renaming changes the name only; the grant is keyed by the bot's ID.
    var renamed = profile
    renamed.name = "Scout Renamed"
    _ = try services.saveAgentProfile(renamed)
    #expect(services.connectorAccess.canUse(.gmail, profileID: profile.id))
    #expect(await gmailVisible())

    // Archiving hides the bot from Gmail even though its process still runs.
    _ = try services.agentProfiles.archive(id: profile.id)
    #expect(await gmailVisible() == false)

    // Restoring brings the grant back without the Mac owner re-ticking it.
    _ = try services.agentProfiles.restore(id: profile.id)
    #expect(await gmailVisible())
  }
}

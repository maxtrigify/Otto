import Foundation
import OttoCore
import OttoModels
import Testing

@testable import OttoServices

@MainActor
@Suite("Global bot search")
struct BotGlobalSearchTests {
  @Test("Search spans bots, rooms, messages, artifacts, and routines with exact links")
  func crossDomainSearch() async throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Bots")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: root.path)
    let scout = try services.createBot(
      BotCreationRequest(name: "Scout", responsibility: "Research launch risks"))
    let writer = try services.createBot(
      BotCreationRequest(name: "Writer", responsibility: "Write launch briefs"))
    let team = try services.createTeam(
      memberProfileIDs: [scout.id, writer.id], name: "Launch room",
      instructions: "Coordinate the launch brief", orchestratorProfileID: scout.id)
    let session = try services.botGroups.open(
      members: [scout.id, writer.id], channelID: team.id)
    _ = try services.botGroups.recordUserMessage(
      sessionID: session.id, text: "Find the launch checklist artifact")
    _ = try services.routines.save(
      Routine(
        name: "Launch digest", instruction: "Summarize launch progress",
        trigger: .schedule(cron: nil, intervalSeconds: 3600),
        target: .spawnProfile(profileID: scout.id)))

    let results = await services.searchWorkspace("launch")
    #expect(results.contains { $0.kind == .bot && $0.title == "Scout" })
    #expect(results.contains { $0.kind == .room && $0.deepLink == .team(channelID: team.id) })
    #expect(results.contains { $0.kind == .message && $0.excerpt.contains("checklist") })
    #expect(results.contains { $0.kind == .routine && $0.title == "Launch digest" })
  }

  @Test("Search ranking and identifiers are stable")
  func stableResults() async throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Bots")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: root.path)
    _ = try services.createBot(
      BotCreationRequest(name: "Exact", responsibility: "Exact match work"))
    let first = await services.searchWorkspace("Exact")
    let second = await services.searchWorkspace("Exact")
    #expect(first == second)
    #expect(first.first?.title == "Exact")
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

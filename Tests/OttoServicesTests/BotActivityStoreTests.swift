import Foundation
import OttoModels
import OttoRuntime
import Testing

@testable import OttoServices

@MainActor
@Suite("Derived bot activity")
struct BotActivityStoreTests {
  @Test("One source becomes one current state with meaningful transition notifications")
  func currentStateAndDeduplication() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotActivityStore(workspacePath: root.path)
    let nodeID = UUID()
    store.consume(OttoEvent(sequence: 1, type: .agentRunStarted, nodeID: nodeID))
    store.consume(OttoEvent(sequence: 2, type: .botNeedsUser, nodeID: nodeID))
    store.consume(OttoEvent(sequence: 2, type: .botNeedsUser, nodeID: nodeID))
    #expect(store.items.count == 1)
    #expect(store.items.first?.state == .needsUser)
    #expect(store.needsUser.count == 1)
    #expect(store.notifications.count == 1)

    store.consume(OttoEvent(sequence: 3, type: .agentRunCompleted, nodeID: nodeID))
    #expect(store.items.first?.state == .completed)
    #expect(store.notifications.map(\.state) == [.needsUser, .completed])

    store.consume(OttoEvent(sequence: 4, type: .agentExited, nodeID: nodeID, exitCode: 0))
    #expect(store.items.first?.state == .completed)
    #expect(store.notifications.map(\.state) == [.needsUser, .completed])

    let reloaded = BotActivityStore(workspacePath: root.path)
    #expect(reloaded.items.first?.state == .completed)
    #expect(reloaded.lastSequence == 4)
  }

  @Test("Routine and channel activity retain exact deep links")
  func deepLinks() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotActivityStore(workspacePath: root.path)
    let routineID = UUID()
    let runID = UUID()
    let channelID = UUID()
    let profileID = UUID()
    store.consume(
      OttoEvent(
        sequence: 1, type: .routineCompleted, routineID: routineID, runID: runID,
        outcome: "completed"))
    store.consume(
      OttoEvent(
        sequence: 2, type: .botNeedsUser, profileID: profileID, channelID: channelID))
    #expect(store.items.contains { $0.deepLink == .routine(routineID: routineID, runID: runID) })
    #expect(
      store.items.contains {
        $0.deepLink == .bot(profileID: profileID, channelID: channelID)
      })
  }

  @Test("A reloaded activity store accepts the first event of a fresh process")
  func restartCursor() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldBus = OttoEventBus()
    let oldStore = BotActivityStore(workspacePath: root.path)
    let oldNode = UUID()
    for _ in 0..<500 {
      oldStore.consume(oldBus.publish(OttoEvent(type: .agentRunStarted, nodeID: oldNode)))
    }
    let reloaded = BotActivityStore(workspacePath: root.path)
    let freshBus = OttoEventBus()
    let newNode = UUID()
    reloaded.consume(freshBus.publish(OttoEvent(type: .agentRunStarted, nodeID: newNode)))
    #expect(reloaded.lastSequence == 1)
    #expect(reloaded.items.first { $0.deepLink == .agent(nodeID: newNode) }?.state == .working)
    #expect(reloaded.items.first { $0.deepLink == .agent(nodeID: oldNode) }?.state == .failed)
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-activity-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

import Foundation
import OttoModels
import Testing

@testable import OttoApp

@Suite("Session order store")
@MainActor
struct SessionOrderStoreTests {
  @Test func emptyStoredOrderKeepsNaturalOrder() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let ids = [first, second, third]
    #expect(SessionOrderStore.arrange(ids, storedOrder: []) == ids)
  }

  @Test func storedOrderComesFirstAndStaleIdsAreDropped() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let stale = UUID()
    let natural = [a, b, c]
    let stored = [stale, b, a]
    let expected = [b, a, c]
    #expect(SessionOrderStore.arrange(natural, storedOrder: stored) == expected)
  }

  @Test func newlyAddedSessionsAppendAfterArrangedOnes() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let ids = [a, b, c]
    let stored = [a]
    let expected = [a, b, c]
    #expect(SessionOrderStore.arrange(ids, storedOrder: stored) == expected)
  }

  @Test func arrangeNodesKeepsTheSameOrder() {
    let a = UUID()
    let b = UUID()
    let frame = WorldRect(x: 0, y: 0, width: 1, height: 1)
    let first = OttoNode(
      id: a, kind: .agent, displayName: "A", subtitle: "",
      frame: frame, zIndex: 0)
    let second = OttoNode(
      id: b, kind: .agent, displayName: "B", subtitle: "",
      frame: frame, zIndex: 0)
    let nodes = [first, second]
    let ordered = SessionOrderStore.arrange(nodes, storedOrder: [b])
    let expected = [b, a]
    #expect(ordered.map(\.id) == expected)
  }

  @Test func moveSwapsAdjacentSessions() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let store = SessionOrderStore(defaults: makeDefaults())
    store.load(workspacePath: "/tmp/ws")
    store.move(a, by: 1, among: [a, b, c])
    let expected = [b, a, c]
    #expect(store.order == expected)
  }

  @Test func moveUpAtTheTopDoesNothing() {
    let a = UUID()
    let b = UUID()
    let store = SessionOrderStore(defaults: makeDefaults())
    store.load(workspacePath: "/tmp/ws")
    store.move(a, by: -1, among: [a, b])
    #expect(store.order.isEmpty)
  }

  @Test func moveDownAtTheBottomDoesNothing() {
    let a = UUID()
    let b = UUID()
    let store = SessionOrderStore(defaults: makeDefaults())
    store.load(workspacePath: "/tmp/ws")
    store.move(b, by: 1, among: [a, b])
    #expect(store.order.isEmpty)
  }

  @Test func movePersistsAndReloads() {
    let defaults = makeDefaults()
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let first = SessionOrderStore(defaults: defaults)
    first.load(workspacePath: "/tmp/ws")
    first.move(b, by: -1, among: [a, b, c])
    let expected = [b, a, c]
    #expect(first.order == expected)

    let second = SessionOrderStore(defaults: defaults)
    second.load(workspacePath: "/tmp/ws")
    #expect(second.order == expected)
  }

  @Test func loadIsIdempotentForTheSameWorkspace() {
    let store = SessionOrderStore(defaults: makeDefaults())
    store.load(workspacePath: "/tmp/ws")
    store.load(workspacePath: "/tmp/ws")
    #expect(store.order.isEmpty)
  }

  @Test func differentWorkspacesDoNotShareOrder() {
    let defaults = makeDefaults()
    let a = UUID()
    let b = UUID()
    let first = SessionOrderStore(defaults: defaults)
    first.load(workspacePath: "/tmp/one")
    first.move(a, by: 1, among: [a, b])
    let expected = [b, a]
    #expect(first.order == expected)

    let second = SessionOrderStore(defaults: defaults)
    second.load(workspacePath: "/tmp/two")
    #expect(second.order.isEmpty)
  }

  private func makeDefaults() -> UserDefaults {
    let name = "session-order-tests-\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }
}

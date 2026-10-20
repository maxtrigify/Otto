import Foundation
import Testing

@testable import OttoApp

@Suite("Home pins")
@MainActor
struct HomePinsTests {
  @Test("Layout, size and references survive relaunch and stay workspace-scoped")
  func persistence() throws {
    let suite = "HomePinsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomePinsStore(defaults: defaults)
    store.load(workspace: "/workspace/a")
    store.add(.markdown("Notes/Plan.md"))
    store.add(.widget(UUID()))
    let first = try #require(store.pins.first)
    store.resize(first.id)
    store.move(first.id, by: 1)
    let saved = store.pins
    let restored = HomePinsStore(defaults: defaults)
    restored.load(workspace: "/workspace/a")
    #expect(restored.pins == saved)
    #expect(restored.pins.last?.expanded == true)
    restored.load(workspace: "/workspace/b")
    #expect(restored.pins.isEmpty)
    restored.load(workspace: "/workspace/a")
    #expect(restored.pins == saved)
  }

  @Test("Duplicate pins and invalid moves cannot damage the saved layout")
  func mutations() throws {
    let suite = "HomePinsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomePinsStore(defaults: defaults)
    store.load(workspace: "/workspace")
    store.add(.markdown("Plan.md"))
    store.add(.markdown("Plan.md"))
    #expect(store.pins.count == 1)
    let pin = try #require(store.pins.first)
    store.move(pin.id, by: -1)
    store.move(pin.id, by: 1)
    #expect(store.pins == [pin])
    store.remove(pin.id)
    let restored = HomePinsStore(defaults: defaults)
    restored.load(workspace: "/workspace")
    #expect(restored.pins.isEmpty)
  }

  @Test("Each Home profile keeps its own pins; the first profile keeps pre-profile pins")
  func profileScoped() throws {
    let suite = "HomePinsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomePinsStore(defaults: defaults)
    store.load(workspace: "/workspace")
    store.add(.markdown("Shared.md"))
    let personal = UUID()
    store.load(workspace: "/workspace", profileID: personal)
    #expect(store.pins.isEmpty)
    store.add(.markdown("Budget.md"))
    store.load(workspace: "/workspace")
    #expect(store.pins.map(\.source) == [.markdown("Shared.md")])
    store.load(workspace: "/workspace", profileID: personal)
    #expect(store.pins.map(\.source) == [.markdown("Budget.md")])
  }
}

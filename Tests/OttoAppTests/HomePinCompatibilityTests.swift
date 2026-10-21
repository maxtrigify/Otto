import Foundation
import Testing
@testable import OttoApp

@Suite("Home pin compatibility")
struct HomePinCompatibilityTests {
  @Test("Old widget pins do not prevent Markdown pins from loading")
  @MainActor
  func legacyPinsRemainRecoverable() throws {
    let suite = "otto.pin-compatibility.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = [HomePin(source: .widget(UUID())), HomePin(source: .markdown("Notes/brief.md")), HomePin(source: .markdown("Notes/plan.md"))]
    let data = try JSONEncoder().encode(saved)
    defaults.set(data, forKey: "otto.home.pins.fixture")
    let pins = HomePinsStore(defaults: defaults)
    pins.load(workspace: "fixture")
    #expect(pins.pins == saved)
    #expect(pins.visiblePins == Array(saved.dropFirst()))
    #expect(defaults.data(forKey: "otto.home.pins.fixture") == data)
    pins.move(saved[2].id, by: -1)
    #expect(pins.pins == [saved[0], saved[2], saved[1]])
    pins.add(.widget(UUID()))
    #expect(pins.pins.count == 3)
  }
}

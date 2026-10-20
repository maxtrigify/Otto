import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Preference tools")
struct PreferenceToolsTests {
  @Test("Font scale and naming tools persist to their injected suite")
  func persistedPreferences() async throws {
    let suite = "otto.tests.preferences.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let defaults = try #require(UserDefaults(suiteName: suite))

    let font = try await ThemeSetFontScaleTool(suiteName: suite).call(
      SetFontScaleInput(scale: .extraLarge), context: context)
    #expect(font.multiplier == 1.3)
    #expect(
      defaults.string(forKey: OttoPreferenceKey.fontScale) == OttoFontScale.extraLarge.rawValue)

    let naming = try await AgentSetNamingTool(suiteName: suite).call(
      SetAgentNamingInput(mode: .custom, names: ["Ripley", "Vasquez"]), context: context)
    #expect(naming.names == ["Ripley", "Vasquez"])
    #expect(AgentNamingPolicy.load(from: defaults).mode == .custom)

    let defaultView = try await AgentSetDefaultViewTool(suiteName: suite).call(
      SetAgentDefaultViewInput(view: .terminal), context: context)
    #expect(defaultView.view == .terminal)
    #expect(AgentDefaultView.load(from: defaults) == .terminal)
  }

  @Test("Empty custom naming is rejected")
  func rejectsEmptyCustomNaming() async {
    let suite = "otto.tests.preferences.\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    await #expect(throws: ToolRegistryError.self) {
      try await AgentSetNamingTool(suiteName: suite).call(
        SetAgentNamingInput(mode: .custom, names: ["  "]), context: context)
    }
  }

  private var context: ToolContext {
    ToolContext(actorID: "test", scopes: Set(ToolScope.allCases), source: .userInterface)
  }
}

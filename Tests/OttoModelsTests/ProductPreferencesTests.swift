import Foundation
import OttoModels
import Testing

@Suite("Product preferences")
struct ProductPreferencesTests {
  @Test("Otto naming is original, stable, and collision safe")
  func ottoNaming() {
    let policy = AgentNamingPolicy()
    #expect(!policy.roster.contains("Chase"))
    #expect(policy.nextName(existingNames: []) == "Aria")
    #expect(
      policy.nextName(existingNames: ["aria", "Beck", "CODA", "Echo", "Fable", "Lyric"])
        == "Aria 2")
  }

  @Test("Custom names normalize whitespace and case-insensitive duplicates")
  func customNaming() {
    let policy = AgentNamingPolicy(
      mode: .custom,
      customNames: ["  Ripley ", "ripley", "  ", "Vasquez"]
    )
    #expect(policy.roster == ["Ripley", "Vasquez"])
    #expect(policy.nextName(existingNames: ["RIPLEY", "vasquez"]) == "Ripley 2")
  }

  @Test("Five font steps have increasing multipliers")
  func fontSteps() {
    #expect(OttoFontScale.allCases.count == 5)
    let values = OttoFontScale.allCases.map(\.multiplier)
    #expect(values == values.sorted())
    #expect(OttoFontScale.standard.multiplier == 1)
  }

  @Test("Agent view defaults to chat and persists terminal")
  func agentDefaultViewPersistence() throws {
    let suite = "otto-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AgentDefaultView.load(from: defaults) == .chat)
    #expect(AgentDefaultView.chat.presentationMode == .conversation)
    AgentDefaultView.terminal.save(to: defaults)
    #expect(AgentDefaultView.load(from: defaults) == .terminal)
    #expect(AgentDefaultView.terminal.presentationMode == .terminal)
  }

  @Test("Missing auto-fit field migrates to the compatibility default")
  func autoFitMigration() throws {
    let json = """
      {"id":"00000000-0000-0000-0000-000000000001","name":"Old","viewport":{"centerX":0,"centerY":0,"scale":1},"nodes":[],"updatedAt":0}
      """
    let canvas = try JSONDecoder().decode(OttoCanvas.self, from: Data(json.utf8))
    #expect(canvas.autoFitEnabled == nil)
    #expect(canvas.autoFitEnabled ?? true)
  }

  @Test("Recipe tidy preferences persist independently and migrate off")
  func recipeTidyPersistence() throws {
    let suite = "otto-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(RecipeTidyPreferences.load(from: defaults) == RecipeTidyPreferences())
    RecipeTidyPreferences(onOpen: true, onClose: false).save(to: defaults)
    #expect(RecipeTidyPreferences.load(from: defaults).onOpen)
    #expect(!RecipeTidyPreferences.load(from: defaults).onClose)
    RecipeTidyPreferences(onOpen: false, onClose: true).save(to: defaults)
    #expect(!RecipeTidyPreferences.load(from: defaults).onOpen)
    #expect(RecipeTidyPreferences.load(from: defaults).onClose)
  }

  @Test("Hermes defaults local and persists a validated remote backend")
  func hermesConnectionPersistence() throws {
    let suite = "otto-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(HermesConnectionConfiguration.load(from: defaults).mode == .local)
    let configuration = HermesConnectionConfiguration(
      mode: .remote,
      remoteURL: " https://hermes.example.test/tunnel ",
      remoteProfile: " silco ",
      remoteWorkingDirectory: " /srv/projects/otto "
    )
    configuration.save(to: defaults)
    let loaded = HermesConnectionConfiguration.load(from: defaults)
    #expect(loaded.mode == .remote)
    #expect(loaded.remoteURL == "https://hermes.example.test/tunnel")
    #expect(loaded.remoteProfile == "silco")
    #expect(loaded.remoteWorkingDirectory == "/srv/projects/otto")
    #expect(loaded.normalizedRemoteURL?.host == "hermes.example.test")
    #expect(
      HermesConnectionConfiguration(mode: .remote, remoteURL: "file:///tmp/hermes")
        .normalizedRemoteURL == nil)
    #expect(
      HermesConnectionConfiguration(
        mode: .remote, remoteURL: "https://token@hermes.example.test"
      )
      .normalizedRemoteURL == nil)
  }
}

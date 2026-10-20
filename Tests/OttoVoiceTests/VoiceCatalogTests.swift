import OttoVoice
import Testing

@Suite("Voice catalogue")
struct VoiceCatalogTests {
  @Test("Provider defaults are valid and stable")
  func defaults() {
    for provider in VoiceProviderKind.allCases {
      let options = VoiceCatalog.options(for: provider)
      let defaultID = VoiceCatalog.defaultVoiceID(for: provider)
      #expect(options.contains { $0.id == defaultID })
      #expect(Set(options.map(\.id)).count == options.count)
    }
    #expect(VoiceCatalog.defaultVoiceID(for: .xai) == "eve")
    #expect(VoiceCatalog.defaultVoiceID(for: .openai) == "marin")
  }

  @Test("Unknown persisted voices fall back to the provider default")
  func validatesPersistedSelection() {
    #expect(VoiceCatalog.validatedVoiceID("sal", for: .xai) == "sal")
    #expect(VoiceCatalog.validatedVoiceID("cedar", for: .openai) == "cedar")
    #expect(VoiceCatalog.validatedVoiceID("retired", for: .xai) == "eve")
    #expect(VoiceCatalog.validatedVoiceID(nil, for: .openai) == "marin")
  }
}

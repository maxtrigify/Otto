import OttoModels
import Testing

@Suite("Bot family")
struct BotFamilyTests {
  @Test func explicitChoiceWins() {
    #expect(BotFamily.accessory(reference: "otto.beret", name: "Coder") == .beret)
    #expect(BotFamily.accessory(reference: "otto.none", name: "Researcher") == .none)
  }

  @Test func roleAndNameSuggestAnAccessory() {
    #expect(BotFamily.accessory(reference: nil, name: "Researcher") == .glasses)
    #expect(BotFamily.accessory(reference: "face.nox", name: "Coder") == .antenna)
    #expect(BotFamily.accessory(reference: nil, name: "Social Guru") == .headset)
    #expect(BotFamily.accessory(reference: nil, name: "Pat", role: "Ops lead") == .hardHat)
    #expect(BotFamily.accessory(reference: nil, name: "Quill", role: "Content writer") == .beret)
  }

  @Test func otherwiseAStablePickFromTheName() {
    let first = BotFamily.accessory(reference: nil, name: "Woody")
    #expect(BotFamily.accessory(reference: "face.echo", name: "Woody") == first)
    #expect(BotFamily.accessory(reference: nil, name: "Woody") == first)
  }

  @Test func referencesRoundTrip() {
    for accessory in BotFamily.Accessory.allCases {
      #expect(BotFamily.isFamilyReference(accessory.reference))
      #expect(BotFamily.accessory(reference: accessory.reference, name: "x") == accessory)
    }
    #expect(!BotFamily.isFamilyReference("🦉"))
    #expect(!BotFamily.isFamilyReference("face.pip"))
  }
}

import Foundation
import OttoModels
import Testing

@Suite("Bot product contract")
struct BotProductContractTests {
  @Test("Only persistent bots are durable roster identities")
  func persistentBotVersusTurnHelper() {
    let persistent = BotActorIdentity.persistentBot(profileID: UUID())
    let helper = BotActorIdentity.turnHelper(runID: UUID())
    #expect(persistent.isDurable)
    #expect(persistent.appearsInRoster)
    #expect(!helper.isDurable)
    #expect(!helper.appearsInRoster)
  }

  @Test("Sharing allows portable configuration and prohibits private or machine data")
  func sharingBoundary() {
    let allowed: Set<BotShareField> = [
      .role, .instructions, .executionDefaults, .appearance, .suggestedSkills,
      .suggestedConnections,
    ]
    #expect(BotShareContract.allowedFields == allowed)

    let prohibited = Set(BotShareField.allCases).subtracting(allowed)
    #expect(!prohibited.isEmpty)
    for field in prohibited {
      #expect(BotShareContract.disposition(for: field) == .prohibited)
    }
    #expect(BotShareContract.disposition(for: .credentials) == .prohibited)
    #expect(BotShareContract.disposition(for: .memory) == .prohibited)
    #expect(BotShareContract.disposition(for: .providerSessions) == .prohibited)
  }

  @Test("A connection grants neither bot access nor write permission by default")
  func connectionSafetyDefaults() {
    #expect(!BotSafetyDefaults.connectionImpliesBotAccess)
    #expect(!BotSafetyDefaults.connectionImpliesWritePermission)
  }
}

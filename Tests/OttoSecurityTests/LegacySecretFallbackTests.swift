import Foundation
import OttoSecurity
import Testing

@Suite("Legacy keychain fallback")
struct LegacySecretFallbackTests {
  @Test("A secret only in the legacy service is returned and copied forward")
  func lazyMigration() async throws {
    let primary = InMemorySecretStore()
    let legacy = InMemorySecretStore()
    try await legacy.set("sk-old", for: "provider.openai")
    let store = LegacyFallbackSecretStore(primary: primary, legacy: legacy)

    #expect(try await store.value(for: "provider.openai") == "sk-old")
    #expect(try await primary.value(for: "provider.openai") == "sk-old")
    // Migration never removes the legacy copy.
    #expect(try await legacy.value(for: "provider.openai") == "sk-old")
  }

  @Test("The new service wins when both hold a value")
  func primaryWins() async throws {
    let primary = InMemorySecretStore()
    let legacy = InMemorySecretStore()
    try await primary.set("new", for: "k")
    try await legacy.set("old", for: "k")
    let store = LegacyFallbackSecretStore(primary: primary, legacy: legacy)
    #expect(try await store.value(for: "k") == "new")
  }

  @Test("Writes go to the new service only")
  func writesPrimary() async throws {
    let primary = InMemorySecretStore()
    let legacy = InMemorySecretStore()
    let store = LegacyFallbackSecretStore(primary: primary, legacy: legacy)
    try await store.set("v", for: "k")
    #expect(try await primary.value(for: "k") == "v")
    #expect(try await legacy.value(for: "k") == nil)
  }

  @Test("An explicit delete cannot be undone by the legacy copy")
  func deleteDoesNotResurrect() async throws {
    let primary = InMemorySecretStore()
    let legacy = InMemorySecretStore()
    try await legacy.set("old", for: "k")
    let store = LegacyFallbackSecretStore(primary: primary, legacy: legacy)
    #expect(try await store.value(for: "k") == "old")
    try await store.delete("k")
    #expect(try await store.value(for: "k") == nil)
  }

  @Test("Missing everywhere is nil")
  func missing() async throws {
    let store = LegacyFallbackSecretStore(
      primary: InMemorySecretStore(), legacy: InMemorySecretStore())
    #expect(try await store.value(for: "absent") == nil)
  }

  @Test("Every Otto keychain service maps to its app.muse twin")
  func serviceNames() {
    #expect(OttoSecretService.credentials == "io.openotto.credentials")
    #expect(
      OttoSecretService.legacyService(for: OttoSecretService.credentials) == "app.muse.credentials")
    #expect(
      OttoSecretService.legacyService(for: OttoSecretService.privatePhone)
        == "app.muse.private-phone")
    #expect(OttoSecretService.legacyService(for: "io.openotto.custom") == "app.muse.custom")
    #expect(OttoSecretService.legacyService(for: "com.example") == nil)
    for (service, legacy) in OttoSecretService.legacyServices {
      #expect(service.hasPrefix("io.openotto."))
      #expect(legacy.hasPrefix("app.muse."))
    }
  }
}

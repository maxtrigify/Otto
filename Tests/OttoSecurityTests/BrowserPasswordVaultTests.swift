import Foundation
import Testing

@testable import OttoSecurity

@Suite("Browser password vault")
struct BrowserPasswordVaultTests {
  @Test func matchesExactHTTPSOrigin() async throws {
    #expect(
      BrowserPasswordVault.origin(for: URL(string: "https://EXAMPLE.test:443/login?q=1"))
        == "https://example.test")
    for url in ["http://example.test", "file:///login", "https://user:pass@example.test"] {
      #expect(BrowserPasswordVault.origin(for: URL(string: url)) == nil)
    }
    #expect(
      BrowserPasswordVault.origin(for: URL(string: "https://example.test:8443/login"))
        == "https://example.test:8443")
    let vault = BrowserPasswordVault(storage: InMemorySecretStore())
    let secret = UUID().uuidString
    let login = BrowserPasswordVault.Login(
      origin: "https://example.test", username: "one", password: secret)
    try await vault.save(login)
    #expect(try await vault.login(origin: "https://sub.example.test", username: "one") == nil)
    #expect(try await vault.login(origin: "https://example.test:8443", username: "one") == nil)
    #expect(try await vault.login(origin: "https://example.test", username: "one") == login)
    #expect(!String(reflecting: login).contains(secret))
    #expect(!String(describing: login).contains(secret))
  }

  @Test func updatesMultipleAccountsAndDeletesPersistently() async throws {
    let storage = InMemorySecretStore()
    let vault = BrowserPasswordVault(storage: storage)
    let origin = "https://example.test"
    try await vault.save(.init(origin: origin, username: "one", password: UUID().uuidString))
    try await vault.save(.init(origin: origin, username: "two", password: UUID().uuidString))
    let updated = BrowserPasswordVault.Login(
      origin: origin, username: "one", password: UUID().uuidString)
    try await vault.save(updated)
    let restored = BrowserPasswordVault(storage: storage)
    #expect(try await restored.summaries().count == 2)
    #expect(try await restored.login(origin: origin, username: "one") == updated)
    try await vault.delete(origin: origin, username: "one")
    #expect(try await restored.login(origin: origin, username: "one") == nil)
    #expect(try await restored.summaries().count == 1)
    try await vault.delete(origin: origin, username: "two")
    #expect(try await restored.summaries().isEmpty)
  }

  @Test func rejectsInsecureOrMalformedRecords() async throws {
    let vault = BrowserPasswordVault(storage: InMemorySecretStore())
    for origin in [
      "http://example.test", "https://example.test/login", "https://example.test:443",
      "https://other.test@evil.test",
    ] {
      await #expect(throws: BrowserPasswordVault.Failure.invalid) {
        try await vault.save(.init(origin: origin, username: "one", password: UUID().uuidString))
      }
    }
    await #expect(throws: BrowserPasswordVault.Failure.invalid) {
      try await vault.save(.init(origin: "https://example.test", username: "one", password: ""))
    }
  }
}

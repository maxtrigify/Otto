import Foundation
import Testing

@testable import OttoSecurity

struct WebsiteCredentialVaultTests {
  @Test func credentialsAreScopedAndDeleted() async throws {
    let vault = WebsiteCredentialVault(storage: InMemorySecretStore())
    let owner = UUID()
    let workspace = UUID()
    let account = UUID()
    let value = WebsiteCredentialVault.Credential(
      signature: "fixture", username: UUID().uuidString, password: UUID().uuidString)
    try await vault.save(
      value, owner: owner, workspace: workspace, account: account, origin: "https://example.test")
    #expect(
      try await vault.load(
        owner: owner, workspace: workspace, account: account, origin: "https://example.test")?
        .password == value.password)
    #expect(
      try await vault.load(
        owner: UUID(), workspace: workspace, account: account, origin: "https://example.test")
        == nil)
    #expect(
      try await vault.load(
        owner: owner, workspace: UUID(), account: account, origin: "https://example.test") == nil)
    #expect(
      try await vault.load(
        owner: owner, workspace: workspace, account: UUID(), origin: "https://example.test") == nil)
    #expect(
      try await vault.load(
        owner: owner, workspace: workspace, account: account, origin: "https://other.test") == nil)
    #expect(!String(reflecting: value).contains(value.password))
    try await vault.delete(
      owner: owner, workspace: workspace, account: account, origin: "https://example.test")
    #expect(
      try await vault.load(
        owner: owner, workspace: workspace, account: account, origin: "https://example.test") == nil
    )
  }
}

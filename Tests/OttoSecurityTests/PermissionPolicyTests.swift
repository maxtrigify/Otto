import OttoSecurity
import OttoTools
import Testing

@Suite("Permission and recursion policy")
struct PermissionPolicyTests {
  @Test("Profiles distinguish read, consequential, and destructive tools")
  func profiles() {
    let read = definition(risk: .read)
    let write = definition(risk: .consequential)
    let destroy = definition(risk: .destructive, confirmation: true)

    #expect(
      PermissionPolicy.decide(profile: .reviewOnly, definition: read, hasRequiredScopes: true)
        == .allow)
    #expect(
      PermissionPolicy.decide(profile: .reviewOnly, definition: write, hasRequiredScopes: true)
        == .deny(reason: "Review-only sessions cannot mutate workspace or canvas state"))
    #expect(
      PermissionPolicy.decide(profile: .workspaceSafe, definition: write, hasRequiredScopes: true)
        == .requireConfirmation(reason: "This action may change workspace files or processes"))
    #expect(
      PermissionPolicy.decide(profile: .workspaceSafe, definition: destroy, hasRequiredScopes: true)
        == .deny(reason: "Destructive global actions require unrestricted mode"))
    #expect(
      PermissionPolicy.decide(profile: .unrestricted, definition: destroy, hasRequiredScopes: true)
        == .requireConfirmation(reason: "Confirm the destructive action"))
  }

  @Test("Missing scopes always deny regardless of profile")
  func missingScope() {
    #expect(
      PermissionPolicy.decide(
        profile: .unrestricted,
        definition: definition(risk: .read),
        hasRequiredScopes: false
      ) == .deny(reason: "The caller lacks a required scope"))
  }

  @Test("Recursive agent spawning is bounded per actor")
  func recursionLimit() async {
    let limiter = RecursiveSpawnLimiter(maximum: 2, window: .seconds(60))
    #expect(await limiter.consume(actorID: "agent-a"))
    #expect(await limiter.consume(actorID: "agent-a"))
    #expect(await !limiter.consume(actorID: "agent-a"))
    #expect(await limiter.consume(actorID: "agent-b"))
  }

  private func definition(risk: ToolRiskLevel, confirmation: Bool = false) -> ToolDefinition {
    ToolDefinition(
      name: "test.tool",
      description: "Test",
      inputSchema: .object([:]),
      outputSchema: .object([:]),
      requiredScopes: [.canvasRead],
      riskLevel: risk,
      requiresConfirmation: confirmation
    )
  }
}

@Suite("Secret storage contract")
struct SecretStoreTests {
  @Test("Secrets can be replaced and deleted")
  func lifecycle() async throws {
    let store = InMemorySecretStore()
    try await store.set("first", for: "xai.api-key")
    #expect(try await store.value(for: "xai.api-key") == "first")
    try await store.set("replacement", for: "xai.api-key")
    #expect(try await store.value(for: "xai.api-key") == "replacement")
    try await store.delete("xai.api-key")
    #expect(try await store.value(for: "xai.api-key") == nil)
  }
}

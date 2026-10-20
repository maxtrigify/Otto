import Foundation
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("External effect ledger")
struct ExternalEffectStoreTests {
  @Test("Consequential effects require approval while reversible local work proceeds")
  func riskPolicy() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEffectStore(workspacePath: root.path)
    let send = try store.intend(effect(key: "send:1", risk: .sendOrPublish))
    #expect(send.state == .intended)
    #expect(send.approvalDecision == .pending)
    #expect(throws: ExternalEffectError.self) { try store.beginExecution(id: send.id) }

    let local = try store.intend(effect(key: "local:1", risk: .reversibleLocal))
    #expect(local.state == .approved)
    _ = try store.beginExecution(id: local.id)
    let completed = try store.complete(id: local.id, resultReference: "artifact:123")
    #expect(completed.state == .completed)
  }

  @Test("Standing rules are narrowly matched by actor, action, and risk")
  func standingRules() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEffectStore(workspacePath: root.path)
    try store.addStandingRule(
      ExternalEffectStandingRule(
        actorID: "bot:scout", action: "slack.send", riskClass: .sendOrPublish))
    let allowed = try store.intend(
      effect(key: "send:allowed", actor: "bot:scout", action: "slack.send", risk: .sendOrPublish))
    let blocked = try store.intend(
      effect(key: "send:blocked", actor: "bot:other", action: "slack.send", risk: .sendOrPublish))
    #expect(allowed.state == .approved)
    #expect(blocked.state == .intended)
  }

  @Test("Restart converts in-flight execution to uncertain and never replays it")
  func crashRecovery() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = ExternalEffectStore(workspacePath: root.path)
    let intended = try store.intend(
      effect(key: "invoice:42", action: "invoice.send", risk: .sendOrPublish),
      userConfirmed: true)
    _ = try store.beginExecution(id: intended.id)

    store = ExternalEffectStore(workspacePath: root.path)
    let recovered = try #require(store.effect(idempotencyKey: "invoice:42"))
    #expect(recovered.state == .uncertain)
    #expect(recovered.verificationGuidance != nil)
    #expect(throws: ExternalEffectError.self) {
      try store.intend(
        effect(key: "invoice:42", action: "invoice.send", risk: .sendOrPublish),
        userConfirmed: true)
    }
  }

  @Test("Idempotency keys deduplicate exact requests and reject collisions")
  func idempotency() throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ExternalEffectStore(workspacePath: root.path)
    let first = try store.intend(effect(key: "publish:1", risk: .sendOrPublish))
    let duplicate = try store.intend(effect(key: "publish:1", risk: .sendOrPublish))
    #expect(first.id == duplicate.id)
    #expect(throws: ExternalEffectError.self) {
      try store.intend(
        ExternalEffect(
          idempotencyKey: "publish:1", action: "example.action", actorID: "bot:scout",
          canonicalRequestHash: "different", riskClass: .sendOrPublish))
    }
  }

  @Test("Tool boundary records confirmed writes and replays a receipt without execution")
  func toolBoundary() async throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let effects = ExternalEffectStore(workspacePath: root.path)
    let counter = EffectInvocationCounter()
    let registry = ToolRegistry(effectCoordinator: effects)
    try await registry.register(EffectFixtureTool(counter: counter))
    let context = ToolContext(
      actorID: "otto-app", scopes: [.canvasWrite], confirmed: true, source: .userInterface)
    let input: JSONValue = .object(["nodeID": .string(UUID().uuidString)])

    _ = try await registry.call(
      name: "browser.click", input: input, context: context, requestID: "confirmed-click-1")
    #expect(await counter.value == 1)
    #expect(effects.effect(idempotencyKey: "tool:confirmed-click-1")?.state == .completed)

    let receipt = try await registry.call(
      name: "browser.click", input: input, context: context, requestID: "confirmed-click-1")
    #expect(receipt["replayed"] == .bool(true))
    #expect(effects.effects.first?.canonicalRequestHash.count == 64)
    #expect(effects.effects.first?.resultReference?.hasPrefix("sha256:") == true)
    #expect(await counter.value == 1)
  }

  @Test("Declared effects are recorded without tool-name guessing, and failed saves roll back")
  func declaredEffectsAndSaveFailure() async throws {
    let root = temporaryWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let effects = ExternalEffectStore(workspacePath: root.path)
    let definition = ToolDefinition(
      name: "vendor.perform", description: "Declared effect",
      inputSchema: .objectSchema(), outputSchema: .objectSchema(), requiredScopes: [.canvasWrite],
      riskLevel: .consequential, externalEffect: .sendOrPublish)
    let context = ToolContext(actorID: "test", scopes: [.canvasWrite], confirmed: true)
    let admission = try await effects.prepareEffect(
      definition: definition, input: .object([:]),
      context: context, requestID: "declared")
    guard case .execute(let id) = admission else {
      Issue.record("Expected effect admission")
      return
    }
    #expect(effects.effects.first?.state == .executing)
    let directory = root.appending(path: ".otto")
    try FileManager.default.removeItem(at: directory)
    try Data("block directory".utf8).write(to: directory)
    await #expect(throws: (any Error).self) {
      try await effects.completeEffect(id: id, output: .object(["ok": .bool(true)]))
    }
    #expect(effects.effects.first?.state == .executing)
    #expect(effects.persistenceError != nil)
  }

  private func effect(
    key: String, actor: String = "bot:scout", action: String = "example.action",
    risk: ExternalEffectRiskClass
  ) -> ExternalEffect {
    ExternalEffect(
      idempotencyKey: key, action: action, actorID: actor,
      canonicalRequestHash: "hash:\(action)", redactedArguments: ["target": "public-id"],
      riskClass: risk)
  }

  private func temporaryWorkspace() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-effects-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

private actor EffectInvocationCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private struct EffectFixtureTool: OttoTool {
  static let definition = ToolDefinition(
    name: "browser.click",
    description: "Fixture external click",
    inputSchema: .objectSchema(
      properties: ["nodeID": .stringSchema()], required: ["nodeID"]),
    outputSchema: .objectSchema(),
    requiredScopes: [.canvasWrite],
    riskLevel: .consequential)

  let counter: EffectInvocationCounter

  func call(_ input: EffectFixtureInput, context: ToolContext) async throws -> EffectFixtureOutput {
    await counter.increment()
    return EffectFixtureOutput(ok: true)
  }
}

private struct EffectFixtureInput: Codable, Sendable { var nodeID: String }
private struct EffectFixtureOutput: Codable, Sendable { var ok: Bool }

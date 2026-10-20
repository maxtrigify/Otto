import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

@Suite("Saved bot subagents")
@MainActor
struct BotSubagentTests {
  @Test(
    "Saved helper controls provider, account and model independently",
    arguments: [AgentProvider.codex, .claudeCode])
  func routing(provider: AgentProvider) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root.appending(path: "accounts"),
      userHome: root.appending(path: "home"), secrets: InMemorySecretStore())
    let personal = try accounts.create(name: "Personal")
    let work = try accounts.create(name: "Work")
    try accounts.setDefault(personal.id)
    let store = CanvasStore()
    let services = ApplicationServices(
      store: store, providerAccounts: accounts, workspacePath: root.path)
    let helper = BotSubagentConfiguration(
      name: "Coder", role: "Write code", provider: provider,
      accountID: work.id, model: "chosen-model")
    let bot = try services.createBot(
      BotCreationRequest(
        name: "Lead", responsibility: "Help",
        provider: provider == .codex ? .claudeCode : .codex, accountID: personal.id,
        subagents: [helper]))
    #expect(AgentProfileStore(workspacePath: root.path).profile(id: bot.id)?.subagents == [helper])
    let source = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: source,
        definition: AgentDefinition(
          provider: bot.provider,
          workingDirectory: root.path, launchCommand: "unused", permissionMode: "readOnly",
          profileID: bot.id, accountID: personal.id)))
    let context = ToolContext(
      actorID: "agent", scopes: Set(ToolScope.allCases), source: .agent, sourceNodeID: source)
    var input = AgentSpawnProviderInput(
      provider: .shell, prompt: "Review this function", x: 0, y: 0,
      model: "wrong-model", permissionMode: .unrestricted, accountID: personal.id)
    input.subagentID = helper.id
    let result = try services.resolveBotSubagent(input, helperID: helper.id, context: context)
    #expect(result.provider == provider)
    #expect(result.accountID == work.id)
    #expect(result.model == "chosen-model")
    #expect(result.permissionMode == .readOnly)
    #expect(result.allowCrossAccount == true)
    #expect(result.profileID == nil)
    #expect(services.botSubagentInstructions(profileID: bot.id).contains(helper.id.uuidString))
    let share = try services.exportBotShareManifest(profileID: bot.id)
    #expect(
      !String(decoding: try JSONEncoder().encode(share), as: UTF8.self).contains(work.id.uuidString)
    )
    #expect(throws: (any Error).self) {
      try services.resolveBotSubagent(input, helperID: UUID(), context: context)
    }
    let otherContext = ToolContext(
      actorID: "other", scopes: Set(ToolScope.allCases), source: .agent, sourceNodeID: UUID())
    #expect(throws: (any Error).self) {
      try services.resolveBotSubagent(input, helperID: helper.id, context: otherContext)
    }
    var removed = bot
    removed.subagents = []
    _ = try services.saveAgentProfile(removed)
    #expect(throws: (any Error).self) {
      try services.resolveBotSubagent(input, helperID: helper.id, context: context)
    }
    _ = try services.saveAgentProfile(bot)
    let child = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: child,
        definition: AgentDefinition(
          provider: provider,
          workingDirectory: root.path, launchCommand: "unused", permissionMode: "readOnly",
          accountID: work.id, requiresExplicitAccount: true)))
    #expect(try services.launchAccountID(nodeID: child) == work.id)
    try await accounts.delete(work.id)
    #expect(throws: (any Error).self) { try services.launchAccountID(nodeID: child) }
    #expect(try services.launchAccountID(nodeID: source) == personal.id)
    #expect(throws: (any Error).self) {
      try services.resolveBotSubagent(input, helperID: helper.id, context: context)
    }
  }

  @Test("Older bot profiles decode without helpers")
  func legacyProfile() throws {
    let profile = AgentProfile(name: "Old", instructions: "Help", provider: .codex)
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    object.removeValue(forKey: "subagents")
    let restored = try JSONDecoder().decode(
      AgentProfile.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.subagents == nil)
  }
}

extension BotSubagentTests {
  @Test(
    "Mac-login helpers bypass named defaults on initial launch and resume",
    arguments: [AgentProvider.codex, .claudeCode])
  func macLogin(provider: AgentProvider) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = ProviderAccountStore(
      rootDirectory: root.appending(path: "accounts"),
      userHome: root.appending(path: "home"), secrets: InMemorySecretStore())
    let store = CanvasStore()
    let services = ApplicationServices(
      store: store, providerAccounts: accounts, workspacePath: root.path)
    let helper = BotSubagentConfiguration(name: "Local helper", provider: provider)
    // A Mac-login helper must work even before the user creates any named account.
    let bot = try services.createBot(
      BotCreationRequest(name: "Lead", responsibility: "Help", subagents: [helper]))
    #expect(AgentProfileStore(workspacePath: root.path).profile(id: bot.id)?.subagents == [helper])
    let work = try accounts.create(name: "Work")
    try accounts.setDefault(work.id)
    let source = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    store.dispatch(
      .setAgentDefinition(
        id: source,
        definition: AgentDefinition(
          provider: .codex,
          workingDirectory: root.path, launchCommand: "unused", permissionMode: "readOnly",
          profileID: bot.id, accountID: work.id)))
    let context = ToolContext(
      actorID: "agent", scopes: Set(ToolScope.allCases), source: .agent, sourceNodeID: source)
    var input = AgentSpawnProviderInput(
      provider: provider, prompt: "Help", x: 0, y: 0, accountID: work.id)
    input.subagentID = helper.id
    let resolved = try services.resolveBotSubagent(input, helperID: helper.id, context: context)
    #expect(resolved.accountID == nil)
    #expect(resolved.allowCrossAccount == true)
    #expect(services.botSubagentInstructions(profileID: bot.id).contains("This Mac’s login"))
    let child = try #require(
      store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0))).affectedNodeIDs.first)
    let definition = AgentDefinition(
      provider: provider, workingDirectory: root.path, launchCommand: "unused",
      permissionMode: "readOnly", accountID: resolved.accountID, requiresExplicitAccount: true)
    // Exercise persisted session metadata, not just the initial resolver result.
    let restored = try JSONDecoder().decode(
      AgentDefinition.self, from: JSONEncoder().encode(definition))
    store.dispatch(.setAgentDefinition(id: child, definition: restored))
    #expect(try services.launchAccountID(nodeID: child) == nil)
    #expect(services.effectiveAccountID(nodeID: child) == nil)
    #expect(services.effectiveAccountID(nodeID: child, ignoringAgentChoice: true) == work.id)
    #expect(try services.launchAccountID(nodeID: source) == work.id)
  }
}

import Combine
import CryptoKit
import Foundation
import OttoModels
import OttoTools

private struct PersistedExternalEffects: Codable {
  var schemaVersion: Int
  var effects: [ExternalEffect]
  var standingRules: [ExternalEffectStandingRule]
}

extension ExternalEffectStore: ExternalEffectCoordinating {
  public func prepareEffect(
    definition: ToolDefinition, input: JSONValue, context: ToolContext, requestID: String
  ) async throws -> ToolEffectAdmission? {
    let declared = definition.externalEffect.flatMap {
      ExternalEffectRiskClass(rawValue: $0.rawValue)
    }
    let legacy =
      context.confirmed
      ? Self.effectRiskClass(toolName: definition.name, risk: definition.riskLevel) : nil
    guard let riskClass = declared ?? legacy else { return nil }
    let encoded = try Self.canonicalData(input)
    let hash = Self.stableHash(encoded)
    let intended = try intend(
      ExternalEffect(
        idempotencyKey: "tool:\(requestID)",
        action: definition.name,
        actorID: context.actorID,
        canonicalRequestHash: hash,
        redactedArguments: Self.redactedArguments(input),
        riskClass: riskClass
      ),
      userConfirmed: context.confirmed
    )
    if intended.state == .completed {
      // Receipts contain no original tool output, which may include private content or credentials.
      return .receipt(
        .object([
          "effectID": .string(intended.id.uuidString),
          "status": .string("completed"), "replayed": .bool(true),
          "resultReference": intended.resultReference.map(JSONValue.string) ?? .null,
        ]))
    }
    return .execute(try beginExecution(id: intended.id).id)
  }

  public func completeEffect(id: UUID, output: JSONValue) async throws {
    let reference = Self.stableHash((try? Self.canonicalData(output)) ?? Data())
    _ = try complete(id: id, resultReference: "sha256:\(reference)")
  }

  public func markEffectUncertain(id: UUID, errorDescription: String) async {
    _ = try? markUncertain(
      id: id,
      guidance: "Verify the external target before retrying. Tool reported: \(errorDescription)")
  }

  private static func effectRiskClass(
    toolName: String, risk: ToolRiskLevel
  ) -> ExternalEffectRiskClass? {
    let name = toolName.lowercased()
    if risk == .destructive { return .delete }
    if name.contains("spend") || name.contains("purchase") || name.contains("buy") {
      return .spend
    }
    if name.contains("account") || name.contains("connection") || name.contains("permission") {
      return .accountChange
    }
    if name == "browser.click" || name.contains("publish")
      || (name.contains("send")
        && !name.hasPrefix("agent.") && !name.hasPrefix("terminal.") && !name.hasPrefix("bot."))
    {
      return .sendOrPublish
    }
    return nil
  }

  private static func canonicalData(_ value: JSONValue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private static func stableHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func redactedArguments(_ input: JSONValue) -> [String: String] {
    guard case .object(let object) = input else { return [:] }
    let sensitive = ["text", "body", "content", "token", "secret", "password", "cookie", "value"]
    return object.reduce(into: [:]) { result, pair in
      let key = pair.key
      if sensitive.contains(where: { key.lowercased().contains($0) }) {
        result[key] = "<redacted>"
        return
      }
      switch pair.value {
      case .string(let value): result[key] = String(value.prefix(240))
      case .number(let value): result[key] = String(value)
      case .bool(let value): result[key] = String(value)
      case .null: result[key] = "null"
      case .array, .object: result[key] = "<structured>"
      }
    }
  }
}

public enum ExternalEffectError: Error, LocalizedError, Equatable, Sendable {
  case invalidKey
  case keyCollision
  case approvalRequired(UUID)
  case invalidTransition
  case uncertain(UUID)

  public var errorDescription: String? {
    switch self {
    case .invalidKey: "External effects require a bounded idempotency key."
    case .keyCollision: "That effect idempotency key belongs to a different request."
    case .approvalRequired: "This external effect requires user approval."
    case .invalidTransition: "That external effect transition is not valid."
    case .uncertain: "The previous attempt may have happened; verify it before retrying."
    }
  }
}

@MainActor
public final class ExternalEffectStore: ObservableObject {
  public static let currentSchemaVersion = 1
  @Published public private(set) var effects: [ExternalEffect] = []
  @Published public private(set) var standingRules: [ExternalEffectStandingRule] = []
  @Published public private(set) var persistenceError: String?

  private var savedEffects: [ExternalEffect] = []
  private var savedRules: [ExternalEffectStandingRule] = []
  private var loadFailed = false
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = URL(fileURLWithPath: workspacePath).appending(
      path: ".otto/external-effects.json")
    load()
    recoverInterruptedEffects()
  }

  public func effect(idempotencyKey: String) -> ExternalEffect? {
    effects.first { $0.idempotencyKey == idempotencyKey }
  }

  @discardableResult
  public func intend(_ candidate: ExternalEffect, userConfirmed: Bool = false) throws
    -> ExternalEffect
  {
    let key = candidate.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= 240 else { throw ExternalEffectError.invalidKey }
    if let existing = effect(idempotencyKey: key) {
      guard existing.canonicalRequestHash == candidate.canonicalRequestHash,
        existing.action == candidate.action, existing.actorID == candidate.actorID
      else { throw ExternalEffectError.keyCollision }
      if existing.state == .uncertain { throw ExternalEffectError.uncertain(existing.id) }
      return existing
    }
    var effect = candidate
    effect.idempotencyKey = key
    let permitted =
      userConfirmed || effect.riskClass == .reversibleLocal
      || standingRules.contains { rule in
        rule.riskClass == effect.riskClass
          && (rule.actorID == nil || rule.actorID == effect.actorID)
          && (rule.action == nil || rule.action == effect.action)
      }
    effect.approvalDecision = permitted ? .approved : .pending
    effect.state = permitted ? .approved : .intended
    effects.append(effect)
    try persist()
    return effect
  }

  @discardableResult
  public func decide(id: UUID, approved: Bool) throws -> ExternalEffect {
    guard let index = effects.firstIndex(where: { $0.id == id }),
      [.intended, .approved].contains(effects[index].state)
    else { throw ExternalEffectError.invalidTransition }
    effects[index].approvalDecision = approved ? .approved : .denied
    effects[index].state = approved ? .approved : .denied
    effects[index].updatedAt = .now
    try persist()
    return effects[index]
  }

  @discardableResult
  public func beginExecution(id: UUID) throws -> ExternalEffect {
    guard let index = effects.firstIndex(where: { $0.id == id }) else {
      throw ExternalEffectError.invalidTransition
    }
    guard effects[index].approvalDecision == .approved else {
      throw ExternalEffectError.approvalRequired(id)
    }
    guard effects[index].state == .approved else {
      if effects[index].state == .uncertain { throw ExternalEffectError.uncertain(id) }
      throw ExternalEffectError.invalidTransition
    }
    effects[index].state = .executing
    effects[index].updatedAt = .now
    try persist()
    return effects[index]
  }

  @discardableResult
  public func complete(id: UUID, resultReference: String? = nil) throws -> ExternalEffect {
    guard let index = effects.firstIndex(where: { $0.id == id }),
      effects[index].state == .executing
    else { throw ExternalEffectError.invalidTransition }
    effects[index].state = .completed
    effects[index].resultReference = resultReference
    effects[index].updatedAt = .now
    try persist()
    return effects[index]
  }

  @discardableResult
  public func markUncertain(id: UUID, guidance: String) throws -> ExternalEffect {
    guard let index = effects.firstIndex(where: { $0.id == id }),
      effects[index].state == .executing
    else { throw ExternalEffectError.invalidTransition }
    effects[index].state = .uncertain
    effects[index].verificationGuidance = guidance
    effects[index].updatedAt = .now
    try persist()
    return effects[index]
  }

  public func addStandingRule(_ rule: ExternalEffectStandingRule) throws {
    standingRules.append(rule)
    try persist()
  }

  private func recoverInterruptedEffects() {
    var changed = false
    for index in effects.indices where effects[index].state == .executing {
      effects[index].state = .uncertain
      effects[index].verificationGuidance =
        "Otto stopped during execution. Verify the external system before deciding what to do."
      effects[index].updatedAt = .now
      changed = true
    }
    if changed { try? persist() }
  }

  private func load() {
    do {
      if let persisted = try WorkspaceJSONFile.load(
        PersistedExternalEffects.self, from: fileURL, fileManager: fileManager)
      {
        effects = persisted.effects
        standingRules = persisted.standingRules
        savedEffects = effects
        savedRules = standingRules
      }
      persistenceError = nil
    } catch {
      loadFailed = true
      persistenceError = "Could not load external effects: \(error.localizedDescription)"
    }
  }

  private func persist() throws {
    do {
      guard !loadFailed else { throw ExternalEffectError.invalidTransition }
      try WorkspaceJSONFile.save(
        PersistedExternalEffects(
          schemaVersion: Self.currentSchemaVersion, effects: effects, standingRules: standingRules),
        to: fileURL, fileManager: fileManager)
      savedEffects = effects
      savedRules = standingRules
      persistenceError = nil
    } catch {
      effects = savedEffects
      standingRules = savedRules
      persistenceError = "Could not save external effects: \(error.localizedDescription)"
      throw error
    }
  }
}

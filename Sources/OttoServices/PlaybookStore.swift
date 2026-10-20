import Foundation
import OttoModels

private struct PersistedPlaybooks: Codable {
  var schemaVersion: Int
  var playbooks: [Playbook]
}
private struct PersistedVoices: Codable {
  var schemaVersion: Int
  var preferences: [BotVoicePreference]
}

public enum PlaybookError: Error, LocalizedError, Equatable, Sendable {
  case invalid(String)
  case testRequired, credentialDetected
  public var errorDescription: String? {
    switch self {
    case .invalid(let reason): "Invalid playbook: \(reason)"
    case .testRequired: "Validate the current playbook before saving or scheduling it."
    case .credentialDetected: "Secret values cannot be recorded in a playbook."
    }
  }
}

public struct PlaybookRoutinePreview: Equatable, Sendable {
  public var routine: Routine
  public var inputs: [String]
  public var permissions: [String]
  public var nextRunAt: Date
}

public actor PlaybookStore {
  private let fileURL: URL
  private var records: [Playbook]

  public init(workspacePath: String) {
    let root = URL(fileURLWithPath: workspacePath).appending(path: ".otto")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    fileURL = root.appending(path: "playbooks.json")
    if let data = try? Data(contentsOf: fileURL),
      let value = try? Self.decoder.decode(PersistedPlaybooks.self, from: data)
    {
      records = value.playbooks
    } else {
      records = []
    }
  }

  public func all() -> [Playbook] { records }

  @discardableResult
  public func capture(name: String, profileID: UUID, demonstratedSteps: [PlaybookStep]) throws
    -> Playbook
  {
    let steps = try demonstratedSteps.map(Self.sanitize)
    let value = Playbook(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines), profileID: profileID, steps: steps
    )
    try Self.validate(value)
    records.append(value)
    try persist()
    return value
  }

  @discardableResult
  public func update(id: UUID, name: String? = nil, steps: [PlaybookStep]) throws -> Playbook {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw PlaybookError.invalid("Not found")
    }
    var updated = records[index]
    if let name { updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
    updated.steps = try steps.map(Self.sanitize)
    updated.state = .draft
    updated.testedAt = nil
    updated.lastTestEvidence = nil
    updated.updatedAt = .now
    try Self.validate(updated)
    records[index] = updated
    try persist()
    return records[index]
  }

  @discardableResult
  public func runSafeTest(id: UUID, now: Date = .now) throws -> Playbook {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw PlaybookError.invalid("Not found")
    }
    try Self.validate(records[index])
    guard
      records[index].steps.allSatisfy({
        !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.anchor.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !$0.anchor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw PlaybookError.invalid("Every dry-run step must resolve a semantic anchor") }
    let evidence = PlaybookTestEvidence(
      validatedStepCount: records[index].steps.count,
      externalEffectsBlocked: true, completedAt: now)
    records[index].state = .tested
    records[index].testedAt = now
    records[index].lastTestEvidence = evidence
    records[index].updatedAt = now
    try persist()
    return records[index]
  }

  @discardableResult
  public func save(id: UUID) throws -> Playbook {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw PlaybookError.invalid("Not found")
    }
    guard records[index].state == .tested,
      records[index].lastTestEvidence?.externalEffectsBlocked == true,
      records[index].lastTestEvidence?.validatedStepCount == records[index].steps.count
    else { throw PlaybookError.testRequired }
    records[index].state = .saved
    records[index].updatedAt = .now
    try persist()
    return records[index]
  }

  public func routinePreview(
    id: UUID, intervalSeconds: Int, permissions: [String], overlap: ConcurrencyPolicy,
    now: Date = .now
  ) throws -> PlaybookRoutinePreview {
    guard let value = records.first(where: { $0.id == id }), value.state == .saved
    else { throw PlaybookError.testRequired }
    guard intervalSeconds >= 60 else {
      throw PlaybookError.invalid("Schedule must be at least 60 seconds")
    }
    let inputs = Array(Set(value.steps.flatMap { $0.inputs.keys })).sorted()
    let instruction = value.steps.enumerated().map { "\($0.offset + 1). \($0.element.instruction)" }
      .joined(separator: "\n")
    let routine = Routine(
      name: value.name, instruction: instruction,
      trigger: .schedule(cron: nil, intervalSeconds: intervalSeconds),
      target: .spawnProfile(profileID: value.profileID), enabled: false,
      concurrency: overlap, toolAllowlist: permissions,
      delivery: .botChannel(profileID: value.profileID))
    return PlaybookRoutinePreview(
      routine: routine, inputs: inputs, permissions: permissions,
      nextRunAt: now.addingTimeInterval(TimeInterval(intervalSeconds)))
  }

  private static func sanitize(_ step: PlaybookStep) throws -> PlaybookStep {
    guard !step.anchor.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !step.anchor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw PlaybookError.invalid("Each step needs a semantic role and name") }
    var value = step
    value.inputs = Dictionary(
      uniqueKeysWithValues: step.inputs.map { key, input in
        (
          key,
          sensitiveInputKey(key) || looksSecret(input) ? "<redacted>" : String(input.prefix(2_000))
        )
      })
    return value
  }

  private static func validate(_ value: Playbook) throws {
    guard !value.name.isEmpty, !value.steps.isEmpty else {
      throw PlaybookError.invalid("Name and steps are required")
    }
    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    guard !looksSecret(encoded) else { throw PlaybookError.credentialDetected }
  }

  private static func looksSecret(_ value: String) -> Bool {
    let lower = value.lowercased()
    return ["sk-proj-", "sk-ant-", "ghp_", "github_pat_", "xoxb-", "bearer ", "password="].contains
    { lower.contains($0) }
  }

  private static func sensitiveInputKey(_ value: String) -> Bool {
    let normalized = value.lowercased().filter(\.isLetter)
    return [
      "password", "passphrase", "secret", "apikey", "accesstoken", "refreshtoken", "privatekey",
    ].contains(normalized)
  }

  private func persist() throws {
    try Self.encoder.encode(PersistedPlaybooks(schemaVersion: 1, playbooks: records)).write(
      to: fileURL, options: [.atomic])
  }
  private static let encoder: JSONEncoder = {
    let v = JSONEncoder()
    v.dateEncodingStrategy = .iso8601
    v.outputFormatting = [.prettyPrinted, .sortedKeys]
    return v
  }()
  private static let decoder: JSONDecoder = {
    let v = JSONDecoder()
    v.dateDecodingStrategy = .iso8601
    return v
  }()
}

public actor BotVoicePreferenceStore {
  private let fileURL: URL
  private var values: [UUID: BotVoicePreference]
  public init(workspacePath: String) {
    let root = URL(fileURLWithPath: workspacePath).appending(path: ".otto")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    fileURL = root.appending(path: "bot-voices.json")
    if let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder().decode(PersistedVoices.self, from: data)
    {
      values = Dictionary(uniqueKeysWithValues: persisted.preferences.map { ($0.profileID, $0) })
    } else {
      values = [:]
    }
  }
  public func preference(profileID: UUID) -> BotVoicePreference {
    values[profileID] ?? BotVoicePreference(profileID: profileID)
  }
  public func set(_ preference: BotVoicePreference) throws {
    values[preference.profileID] = preference
    try JSONEncoder().encode(PersistedVoices(schemaVersion: 1, preferences: Array(values.values)))
      .write(to: fileURL, options: [.atomic])
  }
}

public enum ConnectorBackendRouter {
  public enum AuthorizationError: Error, Equatable, Sendable { case connectionNotAllowed }

  public static func plan(
    integrationID: String, backend: ConnectorBackendKind, effectiveAccess: Set<String>
  ) throws -> ConnectorDispatchPlan {
    guard effectiveAccess.contains(integrationID) else {
      throw AuthorizationError.connectionNotAllowed
    }
    return ConnectorDispatchPlan(integrationID: integrationID, backend: backend)
  }
}

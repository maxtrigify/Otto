import Foundation

public enum PlaybookState: String, Codable, Sendable { case draft, tested, saved }

public enum PlaybookTestMode: String, Codable, Sendable { case semanticDryRun }

public struct PlaybookTestEvidence: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var mode: PlaybookTestMode
  public var validatedStepCount: Int
  public var externalEffectsBlocked: Bool
  public var completedAt: Date

  public init(
    id: UUID = UUID(), mode: PlaybookTestMode = .semanticDryRun,
    validatedStepCount: Int, externalEffectsBlocked: Bool, completedAt: Date = .now
  ) {
    self.id = id
    self.mode = mode
    self.validatedStepCount = validatedStepCount
    self.externalEffectsBlocked = externalEffectsBlocked
    self.completedAt = completedAt
  }
}

public struct SemanticAnchor: Codable, Equatable, Sendable {
  public var role: String
  public var name: String
  public var nearbyText: String?

  public init(role: String, name: String, nearbyText: String? = nil) {
    self.role = role
    self.name = name
    self.nearbyText = nearbyText
  }
}

public struct PlaybookStep: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var instruction: String
  public var anchor: SemanticAnchor
  public var inputs: [String: String]

  public init(
    id: UUID = UUID(), instruction: String, anchor: SemanticAnchor,
    inputs: [String: String] = [:]
  ) {
    self.id = id
    self.instruction = instruction
    self.anchor = anchor
    self.inputs = inputs
  }
}

public struct Playbook: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var profileID: UUID
  public var steps: [PlaybookStep]
  public var state: PlaybookState
  public var testedAt: Date?
  public var lastTestEvidence: PlaybookTestEvidence?
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), name: String, profileID: UUID, steps: [PlaybookStep] = [],
    state: PlaybookState = .draft, testedAt: Date? = nil,
    lastTestEvidence: PlaybookTestEvidence? = nil, updatedAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.profileID = profileID
    self.steps = steps
    self.state = state
    self.testedAt = testedAt
    self.lastTestEvidence = lastTestEvidence
    self.updatedAt = updatedAt
  }
}

public enum BotAutoSpeakPolicy: String, Codable, CaseIterable, Sendable {
  case off, needsYou, completions, all
}

public struct BotVoicePreference: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { profileID }
  public var profileID: UUID
  public var voiceID: String?
  public var autoSpeak: BotAutoSpeakPolicy

  public init(profileID: UUID, voiceID: String? = nil, autoSpeak: BotAutoSpeakPolicy = .off) {
    self.profileID = profileID
    self.voiceID = voiceID
    self.autoSpeak = autoSpeak
  }
}

public enum ConnectorBackendKind: String, Codable, CaseIterable, Sendable { case local, managed }

public struct ConnectorDispatchPlan: Codable, Equatable, Sendable {
  public var integrationID: String
  public var backend: ConnectorBackendKind
  public init(integrationID: String, backend: ConnectorBackendKind) {
    self.integrationID = integrationID
    self.backend = backend
  }
}

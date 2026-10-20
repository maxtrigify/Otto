import Foundation
import OttoModels
import OttoRuntime

public enum ObservabilityEventKind: String, Codable, CaseIterable, Sendable {
  case sessionStarted = "session.started"
  case sessionEnded = "session.ended"
  case previousSessionAbnormal = "session.previous_abnormal"
  case toolCall = "tool.call"
  case agentStateChanged = "agent.state_changed"
  case providerFailure = "provider.failure"
  case resultExtracted = "agent.result_extracted"
  case voiceStateChanged = "voice.state_changed"
  case notification = "notification.sent"
}

public struct ObservabilityEvent: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var timestamp: Date
  public var kind: ObservabilityEventKind
  public var toolName: String?
  public var provider: AgentProvider?
  public var agentState: AgentLifecycleState?
  public var voiceState: String?
  public var targetOrdinal: Int?
  public var durationMilliseconds: Double?
  public var confidence: Double?
  public var succeeded: Bool?
  public var exitCode: Int32?

  public init(
    id: UUID = UUID(),
    timestamp: Date = .now,
    kind: ObservabilityEventKind,
    toolName: String? = nil,
    provider: AgentProvider? = nil,
    agentState: AgentLifecycleState? = nil,
    voiceState: String? = nil,
    targetOrdinal: Int? = nil,
    durationMilliseconds: Double? = nil,
    confidence: Double? = nil,
    succeeded: Bool? = nil,
    exitCode: Int32? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.toolName = toolName
    self.provider = provider
    self.agentState = agentState
    self.voiceState = voiceState
    self.targetOrdinal = targetOrdinal
    self.durationMilliseconds = durationMilliseconds
    self.confidence = confidence
    self.succeeded = succeeded
    self.exitCode = exitCode
  }
}

public struct ObservabilitySnapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var generatedAt: Date
  public var appVersion: String
  public var operatingSystemVersion: String
  public var previousSessionAbnormal: Bool
  public var eventCounts: [String: Int]
  public var toolSuccessCount: Int
  public var toolFailureCount: Int
  public var toolLatencyMedianMilliseconds: Double?
  public var providerFailureCount: Int

  public init(
    schemaVersion: Int = 1,
    generatedAt: Date = .now,
    appVersion: String,
    operatingSystemVersion: String,
    previousSessionAbnormal: Bool,
    eventCounts: [String: Int],
    toolSuccessCount: Int,
    toolFailureCount: Int,
    toolLatencyMedianMilliseconds: Double?,
    providerFailureCount: Int
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.appVersion = appVersion
    self.operatingSystemVersion = operatingSystemVersion
    self.previousSessionAbnormal = previousSessionAbnormal
    self.eventCounts = eventCounts
    self.toolSuccessCount = toolSuccessCount
    self.toolFailureCount = toolFailureCount
    self.toolLatencyMedianMilliseconds = toolLatencyMedianMilliseconds
    self.providerFailureCount = providerFailureCount
  }
}

public enum ObservabilityError: Error, Equatable, LocalizedError {
  case consentRequired
  case invalidEvent

  public var errorDescription: String? {
    switch self {
    case .consentRequired: "Diagnostic export requires explicit consent."
    case .invalidEvent: "The diagnostic event contains a value outside the privacy allowlist."
    }
  }
}

public protocol ObservabilityExporter: Sendable {
  func export(_ snapshot: ObservabilitySnapshot) async throws
}

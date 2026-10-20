import Foundation
import OttoModels
import OttoTools

public enum VoiceState: String, Codable, CaseIterable, Sendable {
  case disconnected
  case connecting
  case sleeping
  case listening
  case userSpeaking
  case endOfTurn
  case thinking
  case callingTool
  case speaking
  case interrupted
  case error
}

/// Resolves what the command bar's primary microphone control should do.
///
/// An active interaction always wins over credential availability so the same
/// control that starts a mode also stops that mode. Credentials only choose the
/// default mode when the microphone is idle.
public enum VoicePrimaryAction: String, CaseIterable, Sendable {
  case talk
  case command
  case dictate
}

public enum VoicePrimaryActionRouter {
  public static func resolve(
    activeAction: VoicePrimaryAction?,
    hasCloudCredential: Bool
  ) -> VoicePrimaryAction {
    activeAction ?? (hasCloudCredential ? .talk : .command)
  }
}

public enum VoiceProviderEvent: Sendable, Equatable {
  case connected
  case reconnecting
  case speechStarted
  case speechStopped
  case partialTranscript(String)
  case finalTranscript(String)
  case thinking
  case toolCall(id: String, name: String, arguments: JSONValue)
  case speaking(String)
  case speechFinished
  case interrupted
  case failed(String)
  case disconnected
}

/// Describes the interaction semantics a provider can actually sustain.
///
/// Current Realtime WebSocket providers are turn based even though microphone audio streams
/// continuously. GPT-Live-style providers can opt into full duplex and asynchronous delegation
/// without making the session infer those guarantees from a model name.
public struct VoiceProviderCapabilities: Sendable, Equatable {
  public var fullDuplexAudio: Bool
  public var requiresTurnDetection: Bool
  public var supportsAsynchronousDelegation: Bool

  public init(
    fullDuplexAudio: Bool = false,
    requiresTurnDetection: Bool = true,
    supportsAsynchronousDelegation: Bool = false
  ) {
    self.fullDuplexAudio = fullDuplexAudio
    self.requiresTurnDetection = requiresTurnDetection
    self.supportsAsynchronousDelegation = supportsAsynchronousDelegation
  }

  public static let turnBased = VoiceProviderCapabilities()
  public static let continuousFullDuplex = VoiceProviderCapabilities(
    fullDuplexAudio: true,
    requiresTurnDetection: false,
    supportsAsynchronousDelegation: true
  )
}

public enum VoicePlaybackPolicy {
  public static func shouldPlayProviderAudio(
    suppressProviderTurn: Bool,
    userInputActive: Bool,
    state: VoiceState,
    capabilities: VoiceProviderCapabilities
  ) -> Bool {
    guard !suppressProviderTurn,
      ![.sleeping, .error, .disconnected].contains(state)
    else { return false }
    if userInputActive {
      return capabilities.fullDuplexAudio && state != .endOfTurn
    }
    return ![.userSpeaking, .endOfTurn].contains(state)
  }
}

public enum VoiceConversationRole: String, Codable, CaseIterable, Sendable {
  case user
  case assistant
}

public enum VoiceConversationAuthority: String, Codable, CaseIterable, Sendable {
  case speculative
  case authoritative
}

/// A provider-neutral conversation record. Partial transcripts remain explicitly speculative
/// until the provider commits them, which lets a future continuous provider revise overlapping
/// speech without contaminating the authoritative history.
public struct VoiceConversationRecord: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var turnID: UUID
  public var role: VoiceConversationRole
  public var text: String
  public var authority: VoiceConversationAuthority
  public var timestamp: Date

  public init(
    id: UUID = UUID(),
    turnID: UUID,
    role: VoiceConversationRole,
    text: String,
    authority: VoiceConversationAuthority,
    timestamp: Date = .now
  ) {
    self.id = id
    self.turnID = turnID
    self.role = role
    self.text = text
    self.authority = authority
    self.timestamp = timestamp
  }
}

public struct VoiceToolResult: Sendable, Equatable {
  public var callID: String
  public var result: JSONValue
  public var isError: Bool
  public var responseInstruction: String?

  public init(
    callID: String,
    result: JSONValue,
    isError: Bool,
    responseInstruction: String? = nil
  ) {
    self.callID = callID
    self.result = result
    self.isError = isError
    self.responseInstruction = responseInstruction
  }
}

public struct VoiceActionEvent: Sendable, Equatable {
  public var callID: String
  public var toolName: String
  public var output: JSONValue

  public init(callID: String, toolName: String, output: JSONValue) {
    self.callID = callID
    self.toolName = toolName
    self.output = output
  }
}

public enum VoiceTraceKind: String, Codable, CaseIterable, Sendable {
  case session
  case user
  case assistant
  case toolRequest = "tool.request"
  case toolResult = "tool.result"
  case interruption
  case error
}

public struct VoiceTraceEntry: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var turnID: UUID?
  public var timestamp: Date
  public var kind: VoiceTraceKind
  public var title: String
  public var detail: String
  public var succeeded: Bool?

  public init(
    id: UUID = UUID(),
    turnID: UUID? = nil,
    timestamp: Date = .now,
    kind: VoiceTraceKind,
    title: String,
    detail: String = "",
    succeeded: Bool? = nil
  ) {
    self.id = id
    self.turnID = turnID
    self.timestamp = timestamp
    self.kind = kind
    self.title = title
    self.detail = detail
    self.succeeded = succeeded
  }
}

public struct CompletionNotificationPolicy: Codable, Equatable, Sendable {
  public var announceCompletions: Bool
  public var announceFailures: Bool
  public var announceWaiting: Bool
  public var queueWhileSleeping: Bool

  public init(
    announceCompletions: Bool = true,
    announceFailures: Bool = true,
    announceWaiting: Bool = true,
    queueWhileSleeping: Bool = false
  ) {
    self.announceCompletions = announceCompletions
    self.announceFailures = announceFailures
    self.announceWaiting = announceWaiting
    self.queueWhileSleeping = queueWhileSleeping
  }
}

public struct AgentVoiceNotice: Codable, Equatable, Sendable {
  public var agentID: UUID
  public var name: String
  public var status: NodeStatus
  public var summary: String

  public init(agentID: UUID, name: String, status: NodeStatus, summary: String) {
    self.agentID = agentID
    self.name = name
    self.status = status
    self.summary = summary
  }
}

public protocol VoiceProvider: Sendable {
  var events: AsyncStream<VoiceProviderEvent> { get }
  var capabilities: VoiceProviderCapabilities { get }
  func connect(tools: [ToolDefinition]) async throws
  func updateContext(_ context: VoiceContext) async
  func sendNotification(_ text: String) async
  func sendToolResult(_ result: VoiceToolResult) async
  func interrupt() async
  func disconnect() async
}

extension VoiceProvider {
  public var capabilities: VoiceProviderCapabilities { .turnBased }
  public func updateContext(_ context: VoiceContext) async {}
  public func sendNotification(_ text: String) async {}
}

public struct VoiceSessionSnapshot: Sendable, Equatable {
  public var state: VoiceState
  public var partialTranscript: String
  public var lastTranscript: String
  public var lastConfirmation: String
  public var lastError: String?
  public var inputDiagnostic: LocalSpeechInputDiagnostic?

  public init(
    state: VoiceState = .disconnected,
    partialTranscript: String = "",
    lastTranscript: String = "",
    lastConfirmation: String = "",
    lastError: String? = nil,
    inputDiagnostic: LocalSpeechInputDiagnostic? = nil
  ) {
    self.state = state
    self.partialTranscript = partialTranscript
    self.lastTranscript = lastTranscript
    self.lastConfirmation = lastConfirmation
    self.lastError = lastError
    self.inputDiagnostic = inputDiagnostic
  }
}

import Foundation
import OttoTools

public actor ScriptedVoiceProvider: VoiceProvider {
  public nonisolated let events: AsyncStream<VoiceProviderEvent>
  public nonisolated let results: AsyncStream<VoiceToolResult>

  private let eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation
  private let resultContinuation: AsyncStream<VoiceToolResult>.Continuation
  public private(set) var projectedTools: [ToolDefinition] = []
  public private(set) var contexts: [VoiceContext] = []
  public private(set) var notifications: [String] = []

  public init() {
    var eventContinuation: AsyncStream<VoiceProviderEvent>.Continuation!
    events = AsyncStream { eventContinuation = $0 }
    self.eventContinuation = eventContinuation
    var resultContinuation: AsyncStream<VoiceToolResult>.Continuation!
    results = AsyncStream { resultContinuation = $0 }
    self.resultContinuation = resultContinuation
  }

  public func connect(tools: [ToolDefinition]) async throws {
    projectedTools = tools
    eventContinuation.yield(.connected)
  }

  public func sendToolResult(_ result: VoiceToolResult) async {
    resultContinuation.yield(result)
  }

  public func updateContext(_ context: VoiceContext) async {
    contexts.append(context)
  }

  public func sendNotification(_ text: String) async {
    notifications.append(text)
  }

  public func interrupt() async {
    eventContinuation.yield(.interrupted)
  }

  public func disconnect() async {
    eventContinuation.yield(.disconnected)
  }

  public func emit(_ event: VoiceProviderEvent) {
    eventContinuation.yield(event)
  }
}

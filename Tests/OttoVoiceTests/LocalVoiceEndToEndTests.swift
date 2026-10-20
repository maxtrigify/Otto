import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import Testing

@Suite("Keyless local voice end to end")
struct LocalVoiceEndToEndTests {
  @Test("An on-device transcript executes a typed tool with no provider or API key")
  @MainActor
  func executesWithoutProvider() async throws {
    let canvas = OttoCanvas(
      name: "Offline",
      nodes: [
        OttoNode(
          kind: .markdown,
          displayName: "One",
          subtitle: "MARKDOWN",
          frame: WorldRect(x: 800, y: 500, width: 320, height: 240),
          zIndex: 0,
          content: .markdown(relativePath: nil, text: "One")
        ),
        OttoNode(
          kind: .markdown,
          displayName: "Two",
          subtitle: "MARKDOWN",
          frame: WorldRect(x: 20, y: 20, width: 320, height: 240),
          zIndex: 1,
          content: .markdown(relativePath: nil, text: "Two")
        ),
      ]
    )
    let store = CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor()
    )
    let router = LocalVoiceCommandRouter(
      registry: registry,
      context: ToolContext(
        actorID: "offline-local-voice",
        scopes: Set(ToolScope.allCases),
        source: .voice
      )
    )
    await router.updateContext(
      VoiceContext(canvas: store.activeCanvas, workspace: "/tmp/offline-local-voice"))
    let transcriber = OfflineTranscriptProbe(transcript: "Focus Two")
    let session = LocalCommandSession(transcriber: transcriber, router: router)
    let collector = LocalUpdateCollector()
    let task = Task {
      for await update in session.updates { await collector.record(update) }
    }

    await session.start()
    try await waitUntil {
      await collector.values.contains { $0.transcript == "Focus Two" }
    }
    await session.stopAndExecute()
    try await waitUntil {
      await collector.values.contains {
        $0.outcome
          == .completed(
            toolName: "node.focus",
            confirmation: "Focused Two"
          )
      }
    }

    let audit = await registry.auditLog()
    #expect(audit.map(\.toolName) == ["node.focus"])
    #expect(audit.first?.actorID == "offline-local-voice")
    #expect(store.activeCanvas.selectedNodeID == store.activeCanvas.nodes[1].id)
    task.cancel()
  }
}

private final class OfflineTranscriptProbe: SpeechTranscriber, @unchecked Sendable {
  let inputDiagnostics: AsyncStream<LocalSpeechInputDiagnostic>
  private let transcript: String
  private let diagnosticsContinuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation
  private let lock = NSLock()
  private var continuation: AsyncThrowingStream<String, Error>.Continuation?

  init(transcript: String) {
    self.transcript = transcript
    var continuation: AsyncStream<LocalSpeechInputDiagnostic>.Continuation!
    inputDiagnostics = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    diagnosticsContinuation = continuation
  }

  func requestAuthorization() async -> Bool { true }

  func startTranscribing() async throws -> AsyncThrowingStream<String, Error> {
    diagnosticsContinuation.yield(
      LocalSpeechInputDiagnostic(
        inputName: "Offline Fixture",
        sampleRate: 48_000,
        channelCount: 1,
        rootMeanSquare: 0.1
      ))
    return AsyncThrowingStream { continuation in
      lock.withLock { self.continuation = continuation }
      continuation.yield(transcript)
    }
  }

  func stopTranscribing() async {
    lock.withLock {
      continuation?.finish()
      continuation = nil
    }
  }
}

private actor LocalUpdateCollector {
  private(set) var values: [LocalCommandUpdate] = []
  func record(_ update: LocalCommandUpdate) { values.append(update) }
}

private func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for offline local voice")
}

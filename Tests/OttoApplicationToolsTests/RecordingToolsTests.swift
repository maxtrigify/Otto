import Foundation
import OttoApplicationTools
import OttoCore
import OttoMedia
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@Suite("Recording tools")
struct RecordingToolsTests {
  private var context: ToolContext {
    ToolContext(actorID: "test", scopes: Set(ToolScope.allCases), source: .userInterface)
  }

  @Test("Status reports no active recording and stop refuses without one")
  func idleRecorder() async throws {
    let recorder = CanvasRecorder()
    let status = try await RecordingStatusTool(recorder: recorder).call(
      RecordingStatusInput(), context: context)
    #expect(status.isRecording == false)
    #expect(status.path == nil)

    let store = await MainActor.run { CanvasStore() }
    await #expect(throws: CanvasRecorderError.self) {
      try await RecordingStopTool(recorder: recorder, store: store, mediaRuntime: MediaRuntime())
        .call(RecordingStopInput(), context: context)
    }
  }

  @Test("Bootstrap registers the recording tools when a recorder is supplied")
  func bootstrapRegistration() async throws {
    let registry = ToolRegistry()
    let store = await MainActor.run { CanvasStore() }
    try await ApplicationToolBootstrap.register(
      in: registry,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: FileManager.default.temporaryDirectory.path,
      canvasRecorder: CanvasRecorder()
    )
    let names = await registry.definitions().map(\.name)
    #expect(names.contains("recording.start"))
    #expect(names.contains("recording.stop"))
    #expect(names.contains("recording.status"))

    // Without a recorder the tools stay unregistered, keeping headless registrations honest.
    let bare = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: bare,
      store: store,
      supervisor: AgentSupervisor(),
      workspacePath: FileManager.default.temporaryDirectory.path
    )
    let bareNames = await bare.definitions().map(\.name)
    #expect(!bareNames.contains("recording.start"))
  }
}

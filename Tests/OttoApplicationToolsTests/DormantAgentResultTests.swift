import Foundation
import OttoModels
import OttoRuntime
import OttoTools
import Testing

@testable import OttoApplicationTools

@Test func aSessionThatIsNotRunningCanStillBeRead() async throws {
  let id = UUID()
  let saved = AgentRuntimeSnapshot(
    id: id,
    provider: .codex,
    executionMode: .oneShotProvider,
    state: .done,
    confidence: 1,
    result: "The homepage now loads in under a second.",
    lastPrompt: "Speed up the homepage",
    transcript: [
      AgentTranscriptEntry(role: .user, text: "Speed up the homepage", createdAt: .now),
      AgentTranscriptEntry(
        role: .assistant, text: "The homepage now loads in under a second.", createdAt: .now),
    ],
    startedAt: .now)
  let context = ToolContext(actorID: "voice", scopes: Set(ToolScope.allCases), source: .voice)

  // The supervisor has never heard of it: it was last used before Otto was opened.
  let tool = AgentGetResultTool(
    supervisor: AgentSupervisor(), dormant: { $0 == id ? saved : nil })
  let output = try await tool.call(AgentStatusInput(agentID: id), context: context)
  #expect(output.result == "The homepage now loads in under a second.")
  #expect(output.state == .done)

  // With nothing saved either, it is still an error rather than an empty answer.
  await #expect(throws: (any Error).self) {
    try await tool.call(AgentStatusInput(agentID: UUID()), context: context)
  }
  await #expect(throws: (any Error).self) {
    try await AgentGetResultTool(supervisor: AgentSupervisor())
      .call(AgentStatusInput(agentID: id), context: context)
  }
}

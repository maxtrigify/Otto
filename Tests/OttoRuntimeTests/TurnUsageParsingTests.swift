import Foundation
import OttoRuntime
import Testing

@Suite("Turn token usage from provider output")
struct TurnUsageParsingTests {
  private func result(_ events: [ParsedAgentEvent]) -> AgentResult? {
    for case .result(let result) in events { return result }
    return nil
  }

  @Test("Claude Code's result carries its tokens, cache reads counted as input")
  func claude() {
    var parser = ClaudeOutputParser()
    let line = """
      {"type":"result","subtype":"success","result":"Done","duration_ms":4200,
       "usage":{"input_tokens":12,"cache_read_input_tokens":3000,"cache_creation_input_tokens":200,
       "output_tokens":85}}
      """.replacingOccurrences(of: "\n", with: "")
    let parsed = result(parser.ingest(line: line))
    #expect(parsed?.inputTokens == 3_212)
    #expect(parsed?.outputTokens == 85)
    #expect(parsed?.durationMilliseconds == 4_200)
  }

  @Test("Codex and Otto Harness report usage on turn.completed")
  func codex() {
    var parser = CodexOutputParser()
    _ = parser.ingest(
      line: #"{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}"#)
    let parsed = result(
      parser.ingest(
        line:
          #"{"type":"turn.completed","usage":{"input_tokens":1500,"cached_input_tokens":1200,"output_tokens":40}}"#
      ))
    #expect(parsed?.inputTokens == 1_500)
    #expect(parsed?.outputTokens == 40)

    var quiet = CodexOutputParser()
    _ = quiet.ingest(
      line: #"{"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}"#)
    let noUsage = result(quiet.ingest(line: #"{"type":"turn.completed"}"#))
    #expect(noUsage?.inputTokens == nil)
    #expect(noUsage?.summaryCandidate == "Hello")
  }
}

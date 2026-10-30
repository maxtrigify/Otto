import OttoRuntime
import Testing

@testable import OttoApp

@Suite("Reply time and token line")
struct TurnStatsTextTests {
  @Test("Short and long turns, small and large token counts read compactly")
  func summaries() {
    #expect(
      TurnStatsText.summary(
        AgentTurnStats(durationSeconds: 3.24, inputTokens: 812, outputTokens: 40))
        == "3.2s · 812 in · 40 out")
    #expect(
      TurnStatsText.summary(
        AgentTurnStats(durationSeconds: 75, inputTokens: 12_460, outputTokens: 1_000))
        == "1m 15s · 12.5k in · 1k out")
    #expect(TurnStatsText.summary(AgentTurnStats(durationSeconds: 42)) == "42s")
    #expect(TurnStatsText.compact(2_400_000) == "2.4M")
    #expect(TurnStatsText.compact(250_000) == "250k")
    #expect(TurnStatsText.duration(3_725) == "1h 02m")
  }

  @Test("The tooltip spells out the counts and says when a provider reports none")
  func details() {
    #expect(
      TurnStatsText.detail(
        AgentTurnStats(durationSeconds: 12, inputTokens: 1_200, outputTokens: 300))
        == "Took 12s, 1,200 input and 300 output tokens (1,500 total).")
    #expect(
      TurnStatsText.detail(AgentTurnStats(durationSeconds: 12))
        == "Took 12s. This provider does not report tokens.")
  }
}

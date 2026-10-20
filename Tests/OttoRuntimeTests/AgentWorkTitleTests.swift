import OttoRuntime
import Testing

@Suite("Agent work titles")
struct AgentWorkTitleTests {
  @Test("Harness titles win and are bounded to seven words")
  func harnessPrecedence() async {
    let title = await AgentWorkTitleGenerator(useOnDeviceModel: false).title(
      for: "Fix the microphone routing regression",
      harnessTitle: "Repair external microphone routing regression"
    )
    #expect(title == "Repair external microphone routing regression")
  }

  @Test("Deterministic fallback describes the requested outcome")
  func deterministicFallback() async {
    let title = await AgentWorkTitleGenerator(useOnDeviceModel: false).title(
      for: "Can you please fix the microphone routing regression?"
    )
    #expect(title == "Fix microphone routing regression")
  }

  @Test("A follow-up keeps the existing task summary")
  func followUpKeepsSummary() async {
    let title = await AgentWorkTitleGenerator(useOnDeviceModel: false).title(
      for: "Also add a regression test for the empty state",
      currentTitle: "Summarize staged agent tasks"
    )
    #expect(title == "Summarize staged agent tasks")
  }

  @Test("A materially different request replaces the task summary")
  func materialChangeReplacesSummary() async {
    let title = await AgentWorkTitleGenerator(useOnDeviceModel: false).title(
      for: "Investigate the microphone routing regression",
      currentTitle: "Summarize staged agent tasks"
    )
    #expect(title == "Investigate microphone routing regression")
  }
}

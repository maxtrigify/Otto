import Foundation
import OttoModels
import OttoTools
import OttoVoice
import Testing

@testable import OttoApp

/// Runs a real harness on this Mac's own sign-in, through the same path voice uses. Off by
/// default: it needs the harness installed and signed in, and spends a little of its allowance.
///
///     OTTO_LIVE_VOICE_HARNESS=Codex OTTO_LIVE_VOICE_BRIDGE=/path/to/otto-mcp \
///       scripts/otto-swift test --filter HarnessVoiceBrainLive
@Suite("Voice thinking with any harness, live")
struct HarnessVoiceBrainLiveTests {
  private static let environment = ProcessInfo.processInfo.environment
  private static let provider = environment["OTTO_LIVE_VOICE_HARNESS"]
    .flatMap(AgentProvider.init(rawValue:))

  private actor Calls {
    private(set) var names: [String] = []
    func record(_ name: String) { names.append(name) }
  }

  private static let tool = ToolDefinition(
    name: "bot.list",
    description: "Lists the bots saved in this Otto space.",
    inputSchema: .objectSchema(properties: [:], required: []),
    outputSchema: .object([:]),
    requiredScopes: [],
    riskLevel: .read
  )

  private func reply(from brain: HarnessVoiceBrain) async -> String {
    var text = ""
    for await event in brain.events {
      switch event {
      case .text(let delta): text += delta
      case .pause: continue
      case .finished: return text
      case .failed(let message): return "FAILED: \(message)"
      }
    }
    return text
  }

  @Test(
    "The chosen harness uses an Otto tool through voice's bridge, then remembers the conversation",
    .enabled(if: provider != nil), .timeLimit(.minutes(4)))
  func toolRoundTripAndMemory() async throws {
    let provider = try #require(Self.provider)
    let calls = Calls()
    let brain = HarnessVoiceBrain(
      provider: provider,
      model: Self.environment["OTTO_LIVE_VOICE_MODEL"],
      instructions:
        "You are a voice assistant. Use the Otto tools when asked. Reply in one short sentence.",
      workspace: FileManager.default.temporaryDirectory
        .appending(path: "otto-voice-thinking-\(UUID().uuidString)"),
      toolBridgeExecutable: Self.environment["OTTO_LIVE_VOICE_BRIDGE"]
    )
    try await brain.start(tools: [Self.tool]) { name, _ in
      await calls.record(name)
      return (#"{"bots":["Coder","Woody"]}"#, false)
    }
    let clock = ContinuousClock()
    var started = clock.now
    await brain.ask("Which bots do I have? Use the bot list tool, then name them.")
    let first = await reply(from: brain)
    print("first reply after \(clock.now - started): \(first)")
    #expect(await calls.names.contains("bot.list"))
    #expect(first.contains("Coder") && first.contains("Woody"))

    started = clock.now
    await brain.ask("How many bots was that? Answer with just the number as a word.")
    let second = await reply(from: brain)
    print("second reply after \(clock.now - started): \(second)")
    #expect(second.lowercased().contains("two"))
    await brain.stop()
  }
}

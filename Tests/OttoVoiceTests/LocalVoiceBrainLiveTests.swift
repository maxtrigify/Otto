import Foundation
import OttoTools
import Testing

@testable import OttoVoice

/// Runs the real Claude Code command-line tool on this Mac's own sign-in. Off by default: it
/// needs a signed-in subscription and spends a little of it.
///
///     OTTO_LIVE_LOCAL_VOICE=/path/to/claude scripts/otto-swift test --filter LocalVoiceBrainLive
@Suite("Local voice assistant, live")
struct LocalVoiceBrainLiveTests {
  private static let executable = ProcessInfo.processInfo.environment["OTTO_LIVE_LOCAL_VOICE"]

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

  /// Collects what the assistant says until its reply ends.
  private func reply(from brain: ClaudeCodeVoiceBrain) async -> String {
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
    "The signed-in assistant uses an Otto tool through the bridge and reports the result",
    .enabled(if: executable != nil), .timeLimit(.minutes(2)))
  func toolRoundTrip() async throws {
    let calls = Calls()
    let brain = ClaudeCodeVoiceBrain(
      configuration: .init(
        executable: URL(fileURLWithPath: try #require(Self.executable)),
        instructions:
          "You are a voice assistant. Use tools when asked. Reply in one short sentence."
      ))
    try await brain.start(tools: [Self.tool]) { name, _ in
      await calls.record(name)
      return (#"{"bots":["Coder","Woody"]}"#, false)
    }
    await brain.ask("Which bots do I have? Use the tool.")
    let first = await reply(from: brain)
    #expect(await calls.names == ["bot.list"])
    #expect(first.contains("Coder") && first.contains("Woody"))

    // Cutting in must not leave the next request unanswered or mixed with the old reply.
    await brain.ask("Count slowly from one to forty, one number per sentence.")
    for await event in brain.events {
      if case .text = event { break }
    }
    await brain.interrupt()
    await brain.ask("Now reply with exactly the single word: pineapple")
    let second = await reply(from: brain)
    #expect(second.lowercased().contains("pineapple"))
    #expect(!second.contains("seventeen"))
    await brain.stop()
  }
}

import Foundation
import OttoTools

/// Bounds how fast agents can drive other agents. Agent-to-agent chaining is a supported
/// pattern (spawn a worker, hand a plan over, await the result), but a mis-prompted conductor
/// can loop `agent.send_prompt` or fan out spawns and burn provider spend in seconds. Human and
/// system callers are never throttled — only calls whose source is an agent or automation.
public actor AgentControlThrottle {
  public struct Limit: Sendable {
    public let maxCalls: Int
    public let window: Duration

    public init(maxCalls: Int, window: Duration) {
      self.maxCalls = max(1, maxCalls)
      self.window = window
    }
  }

  private let spawnLimit: Limit
  private let promptLimit: Limit
  private var history: [String: [ContinuousClock.Instant]] = [:]
  private let clock = ContinuousClock()

  public init(
    spawnLimit: Limit = Limit(maxCalls: 5, window: .seconds(300)),
    promptLimit: Limit = Limit(maxCalls: 20, window: .seconds(300))
  ) {
    self.spawnLimit = spawnLimit
    self.promptLimit = promptLimit
  }

  public func authorizeSpawn(_ context: ToolContext) throws {
    try authorize(kind: "spawn", limit: spawnLimit, context: context)
  }

  public func authorizePrompt(_ context: ToolContext) throws {
    try authorize(kind: "prompt", limit: promptLimit, context: context)
  }

  private func authorize(kind: String, limit: Limit, context: ToolContext) throws {
    guard context.source == .agent || context.source == .automation else { return }
    let key = "\(kind)|\(context.actorID)"
    let now = clock.now
    var recent = (history[key] ?? []).filter { now - $0 < limit.window }
    guard recent.count < limit.maxCalls else {
      history[key] = recent
      throw ToolRegistryError.invalidInput(
        "Agent-initiated \(kind) limit reached (\(limit.maxCalls) per \(Int(limit.window.components.seconds / 60)) minutes). "
          + "Stop and report progress to the user instead of retrying; they can continue the chain themselves."
      )
    }
    recent.append(now)
    history[key] = recent
  }
}

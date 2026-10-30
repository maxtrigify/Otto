#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels
import OttoRuntime

/// A run that stopped on an account usage limit and is waiting for the user's choice.
public struct ProviderUsageLimitNotice: Equatable, Identifiable, Sendable {
  public var id: UUID { nodeID }
  public var nodeID: UUID
  public var limit: ProviderUsageLimit
  public var accountID: UUID?
  public var accountName: String
  /// The prompt that was stopped; continuing re-sends exactly this.
  public var prompt: String
  /// Accounts the run could continue on, suggested one first.
  public var alternatives: [ProviderAccount]
  /// Set while Otto is waiting to re-run on the same account after the reset.
  public var scheduledResumeAt: Date?
  public var projectName: String?
}

/// Live usage-limit state for agent cards. Owned by `ApplicationServices`.
@MainActor
public final class ProviderUsageLimitCenter: ObservableObject {
  @Published public private(set) var notices: [UUID: ProviderUsageLimitNotice] = [:]
  private var handledRuns: Set<UUID> = []
  private var resumeTasks: [UUID: Task<Void, Never>] = [:]
  /// One-shot conversation summary delivered to the first run after an account change, since
  /// the new account's provider cannot resume the old account's session.
  private var handovers: [UUID: String] = [:]

  public init() {}

  func markHandled(runID: UUID) -> Bool { handledRuns.insert(runID).inserted }
  func set(_ notice: ProviderUsageLimitNotice) { notices[notice.nodeID] = notice }

  func clear(_ nodeID: UUID) {
    notices[nodeID] = nil
    resumeTasks.removeValue(forKey: nodeID)?.cancel()
  }

  func schedule(_ nodeID: UUID, task: Task<Void, Never>) {
    resumeTasks.removeValue(forKey: nodeID)?.cancel()
    resumeTasks[nodeID] = task
  }

  func setHandover(_ text: String?, for nodeID: UUID) { handovers[nodeID] = text }
  func takeHandover(for nodeID: UUID) -> String? { handovers.removeValue(forKey: nodeID) }
}

extension ApplicationServices {
  /// Called for every lifecycle change. Detects runs stopped by an account usage limit and
  /// applies the project's policy: ask (default), wait for the reset, or switch accounts.
  func handleUsageLimit(_ snapshot: AgentRuntimeSnapshot) async {
    guard let text = Self.usageLimitEvidence(snapshot),
      let limit = ProviderUsageLimit.detect(in: text, provider: snapshot.provider),
      usageLimits.markHandled(runID: snapshot.runID ?? snapshot.id),
      store.snapshot.canvases.lazy.flatMap(\.nodes).contains(where: { $0.id == snapshot.id })
    else { return }
    let nodeID = snapshot.id
    let prompt = snapshot.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let project = projectChannel(nodeID: nodeID).flatMap {
      conversationProjects.project(channelID: $0)
    }
    let currentID = effectiveAccountID(nodeID: nodeID)
    let current = providerAccounts.account(id: currentID)
    let fallback = project?.usageLimitFallbackAccountID.flatMap {
      $0 == currentID ? nil : providerAccounts.account(id: $0)
    }
    let alternatives =
      (fallback.map { [$0] } ?? [])
      + providerAccounts.accounts.filter { $0.id != currentID && $0.id != fallback?.id }
    var notice = ProviderUsageLimitNotice(
      nodeID: nodeID, limit: limit, accountID: currentID,
      accountName: current?.name ?? "This Mac's login", prompt: prompt,
      alternatives: alternatives, projectName: project?.name)

    switch project?.usageLimitPolicy ?? .ask {
    case .switchAccount where fallback != nil && !prompt.isEmpty:
      await appendActivity(
        "\(notice.accountName) hit its usage limit. Continuing on \(fallback!.name).", to: nodeID)
      await continueAfterUsageLimit(nodeID: nodeID, accountID: fallback!.id, notice: notice)
    case .waitForReset where limit.resetsAt != nil && !prompt.isEmpty:
      usageLimits.set(notice)
      await waitForUsageLimitReset(nodeID: nodeID)
    default:
      if prompt.isEmpty { notice.alternatives = [] }
      usageLimits.set(notice)
    }
  }

  /// Re-runs the stopped prompt on another account (the agent's account changes permanently).
  public func continueAfterUsageLimit(nodeID: UUID, accountID: UUID) async {
    guard let notice = usageLimits.notices[nodeID] else { return }
    await continueAfterUsageLimit(nodeID: nodeID, accountID: accountID, notice: notice)
  }

  private func continueAfterUsageLimit(
    nodeID: UUID, accountID: UUID, notice: ProviderUsageLimitNotice
  ) async {
    usageLimits.clear(nodeID)
    do {
      try await setAccount(accountID, forAgent: nodeID)
      try await sendPrompt(agentID: nodeID, prompt: notice.prompt)
    } catch {
      await recordConversationSendFailure(agentID: nodeID, prompt: notice.prompt, error: error)
    }
  }

  /// Keeps the account and re-runs the stopped prompt once the provider's limit resets.
  public func waitForUsageLimitReset(nodeID: UUID) async {
    guard var notice = usageLimits.notices[nodeID], let resetsAt = notice.limit.resetsAt else {
      return
    }
    // A minute of slack: providers report the reset to the minute and reject early retries.
    let runAt = resetsAt.addingTimeInterval(60)
    notice.scheduledResumeAt = runAt
    usageLimits.set(notice)
    let prompt = notice.prompt
    usageLimits.schedule(
      nodeID,
      task: Task { [weak self] in
        let delay = max(0, runAt.timeIntervalSinceNow)
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled, let self else { return }
        self.usageLimits.clear(nodeID)
        do {
          try await self.sendPrompt(agentID: nodeID, prompt: prompt)
        } catch {
          await self.recordConversationSendFailure(agentID: nodeID, prompt: prompt, error: error)
        }
      })
    await appendActivity(
      "Waiting for \(notice.accountName)'s limit to reset. Otto will continue at \(runAt.formatted(date: .omitted, time: .shortened)).",
      to: nodeID)
  }

  public func dismissUsageLimit(nodeID: UUID) {
    usageLimits.clear(nodeID)
  }

  /// A compact recap of the conversation for the first run on a new account.
  func prepareAccountHandover(nodeID: UUID, from previous: String, to next: String) async {
    guard let snapshot = try? await supervisor.snapshot(agentID: nodeID) else { return }
    let turns = snapshot.transcript
      .filter { $0.kind == .text && ($0.role == .user || $0.role == .assistant) }
      .suffix(8)
    guard !turns.isEmpty else {
      usageLimits.setHandover(nil, for: nodeID)
      return
    }
    var budget = 6_000
    var lines: [String] = []
    for turn in turns.reversed() {
      let speaker = turn.role == .user ? "User" : "Assistant"
      let text = PromptSubmission.originalUserText(turn.text)
      let clipped = String(text.prefix(min(1_500, budget)))
      budget -= clipped.count
      lines.insert("\(speaker): \(clipped)", at: 0)
      if budget <= 0 { break }
    }
    usageLimits.setHandover(
      """
      This conversation moved from the \(previous) provider account to \(next), so earlier \
      provider-side history is unavailable. Recent conversation, oldest first:
      \(lines.joined(separator: "\n"))
      """, for: nodeID)
  }

  /// Delivered once, through the hidden per-turn context, on the first run after a switch.
  func takeAccountHandover(nodeID: UUID) -> String? {
    usageLimits.takeHandover(for: nodeID)
  }

  private func appendActivity(_ text: String, to nodeID: UUID) async {
    try? await supervisor.appendLocalTranscript(
      agentID: nodeID, role: .activity, kind: .notice, text: text)
  }

  /// Only the run's own failure text is inspected. Completed runs count only when their whole
  /// result is short, so an ordinary answer about rate limits never triggers a switch.
  nonisolated static func usageLimitEvidence(_ snapshot: AgentRuntimeSnapshot) -> String? {
    switch snapshot.state {
    case .failed:
      return [snapshot.result, snapshot.attentionReason, String(snapshot.output.suffix(2_000))]
        .compactMap { $0 }.joined(separator: "\n")
    case .done:
      guard let result = snapshot.result, result.count <= 400 else { return nil }
      return result
    default:
      return nil
    }
  }
}

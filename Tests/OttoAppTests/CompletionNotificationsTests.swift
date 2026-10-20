import Foundation
import OttoRuntime
import Testing

@testable import OttoApp

struct CompletionNotificationsTests {
  @Test func terminalEventsOnlyAndOneAlertPerTurn() {
    var filter = CompletionEventFilter()
    let node = UUID()
    let run = UUID()
    let accepted1 = !filter.accept(
      OttoEvent(type: .agentStatusChanged, nodeID: node, state: .done, runID: run))
    #expect(accepted1)
    let accepted2 = !filter.accept(OttoEvent(type: .agentOutputAppended, nodeID: node, runID: run))
    #expect(accepted2)
    let accepted3 = filter.accept(OttoEvent(type: .agentRunCompleted, nodeID: node, runID: run))
    #expect(accepted3)
    let accepted4 = !filter.accept(OttoEvent(type: .agentRunCompleted, nodeID: node, runID: run))
    #expect(accepted4)
    let accepted5 = !filter.accept(OttoEvent(type: .agentRunFailed, nodeID: node, runID: run))
    #expect(accepted5)
    let accepted6 = filter.accept(OttoEvent(type: .agentRunFailed, nodeID: node, runID: UUID()))
    #expect(accepted6)
    let accepted7 = filter.accept(OttoEvent(type: .agentRunCompleted, nodeID: UUID(), runID: run))
    #expect(accepted7)
    let accepted8 = !filter.accept(OttoEvent(type: .agentRunCompleted))
    #expect(accepted8)
  }

  @Test @MainActor func defaultOnRespectsExplicitOptOut() throws {
    let suite = "CompletionNotificationsTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for key in [
      CompletionNotifications.enabledKey, CompletionNotifications.botsKey,
      CompletionNotifications.sessionsKey,
    ] {
      #expect(CompletionNotifications.enabled(key, defaults: defaults))
      defaults.set(false, forKey: key)
      #expect(!CompletionNotifications.enabled(key, defaults: defaults))
    }
    #expect(!CompletionNotifications.enabled(CompletionNotifications.soundKey, defaults: defaults))
  }
}

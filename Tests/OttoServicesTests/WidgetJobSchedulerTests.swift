import Foundation
import OttoModels
import OttoServices
import Testing

@Suite("Widget job scheduler")
struct WidgetJobSchedulerTests {
  @Test("Due computation honors cron, intervals, minimums, and first runs")
  func dueTimes() throws {
    let disabled = WidgetSchedule(enabled: false, intervalSeconds: 60)
    #expect(WidgetJobScheduler.nextDue(schedule: disabled, state: WidgetRuntimeState()) == nil)

    let fresh = WidgetSchedule(enabled: true, intervalSeconds: 300)
    #expect(
      WidgetJobScheduler.nextDue(schedule: fresh, state: WidgetRuntimeState()) == .distantPast)

    let last = Date(timeIntervalSince1970: 1_754_900_000)
    var state = WidgetRuntimeState()
    state.lastRunAt = last
    let interval = WidgetSchedule(enabled: true, intervalSeconds: 300)
    #expect(
      WidgetJobScheduler.nextDue(schedule: interval, state: state)
        == last.addingTimeInterval(300))

    let tooFast = WidgetSchedule(enabled: true, intervalSeconds: 5)
    #expect(
      WidgetJobScheduler.nextDue(schedule: tooFast, state: state)
        == last.addingTimeInterval(60))

    let cron = WidgetSchedule(enabled: true, intervalSeconds: 300, cron: "0 */6 * * *")
    let due = try #require(WidgetJobScheduler.nextDue(schedule: cron, state: state))
    #expect(due > last)
    #expect(due.timeIntervalSince(last) <= 6 * 3_600)

    let badCron = WidgetSchedule(enabled: true, intervalSeconds: 300, cron: "not cron")
    #expect(
      WidgetJobScheduler.nextDue(schedule: badCron, state: state)
        == last.addingTimeInterval(300))
  }
}

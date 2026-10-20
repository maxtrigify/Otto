import AppKit
import Combine
import Foundation

/// The first time someone comes back to their Mac each day, Otto opens on Home. "Each day"
/// starts at 6am in the Mac's time zone, so working past midnight doesn't count as a new day.
enum MorningHome {
  static let hour = 6

  /// Whether the day rolled over while the person was away.
  static func shouldOpenHome(
    awaySince: Date, now: Date = .now, calendar: Calendar = .current
  ) -> Bool {
    guard let today = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) else {
      return false
    }
    let boundary =
      today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    return awaySince < boundary && boundary <= now
  }

  /// Leaving: Otto goes to the background, the Mac sleeps, or the screen locks or sleeps.
  static var leaving: AnyPublisher<Notification, Never> {
    merged(
      app: NSApplication.didResignActiveNotification,
      workspace: [
        NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
        NSWorkspace.sessionDidResignActiveNotification,
      ])
  }

  /// Coming back: the reverse of each of those.
  static var returning: AnyPublisher<Notification, Never> {
    merged(
      app: NSApplication.didBecomeActiveNotification,
      workspace: [
        NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
      ])
  }

  private static func merged(app: Notification.Name, workspace: [Notification.Name])
    -> AnyPublisher<Notification, Never>
  {
    Publishers.MergeMany(
      [NotificationCenter.default.publisher(for: app)]
        + workspace.map { NSWorkspace.shared.notificationCenter.publisher(for: $0) }
    )
    .eraseToAnyPublisher()
  }
}

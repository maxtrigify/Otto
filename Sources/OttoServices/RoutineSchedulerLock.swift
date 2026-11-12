import Foundation

/// Lets one Otto app at a time fire a workspace's scheduled automations.
///
/// Otto and Otto Dev (or two copies of Otto) can have the same workspace open, and each runs its
/// own scheduler over the same automations, so every schedule would fire once per app. The app
/// that takes this lock first fires them; the others keep asking, and one takes over when the
/// holder quits. The lock is an advisory `flock` on a file in the workspace, which the system
/// drops when the holding app exits, however it exits.
@MainActor
public final class RoutineSchedulerLock {
  private let lockURL: URL
  private var descriptor: Int32 = -1

  public init(workspacePath: String) {
    lockURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/routines/scheduler.lock")
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }

  /// True when this app holds the lock, taking it if nobody does.
  public func holds() -> Bool {
    if descriptor >= 0 { return true }
    try? FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let candidate = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    // A workspace that cannot hold a lock file must not lose its schedules.
    guard candidate >= 0 else { return true }
    guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
      close(candidate)
      return false
    }
    descriptor = candidate
    return true
  }

  /// Gives the lock up so another app can fire schedules.
  public func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }

  public var gate: RoutineEngine.ScheduleGate {
    { [self] in holds() }
  }
}

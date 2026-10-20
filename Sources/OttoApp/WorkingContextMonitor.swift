import Combine
import Foundation
import OttoRuntime

private struct WorkingContextKey: Hashable {
  let processID: Int32?
  let fallbackDirectory: String?
}

/// A shared, visibility-leased resolver. The footer and composer for one process reuse one lookup
/// instead of each walking the filesystem every five seconds.
@MainActor
final class WorkingContextMonitor: ObservableObject {
  @Published private(set) var state: WorkingContext.State?

  private let processID: Int32?
  private let fallbackDirectory: String?
  private var consumers = 0
  private var refreshTask: Task<Void, Never>?

  init(processID: Int32?, fallbackDirectory: String?) {
    self.processID = processID
    self.fallbackDirectory = fallbackDirectory
  }

  func acquire() {
    consumers += 1
    guard refreshTask == nil else { return }
    let processID = processID
    let fallbackDirectory = fallbackDirectory
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        let resolved = await Task.detached(priority: .utility) {
          WorkingContext.resolve(pid: processID, fallbackDirectory: fallbackDirectory)
        }.value
        guard !Task.isCancelled, let self else { return }
        if resolved != state { state = resolved }
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  func release() {
    consumers = max(0, consumers - 1)
    guard consumers == 0 else { return }
    refreshTask?.cancel()
    refreshTask = nil
  }
}

@MainActor
enum WorkingContextMonitors {
  private static var entries: [WorkingContextKey: WorkingContextMonitor] = [:]

  static func monitor(
    processID: Int32?,
    fallbackDirectory: String?
  ) -> WorkingContextMonitor {
    let key = WorkingContextKey(
      processID: processID,
      fallbackDirectory: fallbackDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    )
    if let existing = entries[key] { return existing }
    let monitor = WorkingContextMonitor(
      processID: processID,
      fallbackDirectory: key.fallbackDirectory
    )
    entries[key] = monitor
    return monitor
  }
}

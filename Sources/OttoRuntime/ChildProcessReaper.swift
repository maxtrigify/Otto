import Foundation

#if os(Linux)
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#else
  import Darwin
#endif

final class ChildProcessReaper: @unchecked Sendable {
  static let shared = ChildProcessReaper()

  private let condition = NSCondition()
  private var observers: [pid_t: @Sendable (Int32) -> Void] = [:]
  private var threadStarted = false

  private init() {}

  func observe(pid: pid_t, handler: @escaping @Sendable (Int32) -> Void) {
    condition.lock()
    observers[pid] = handler
    if !threadStarted {
      threadStarted = true
      Thread.detachNewThread { [weak self] in self?.reapChildren() }
    }
    condition.signal()
    condition.unlock()
  }

  private func reapChildren() {
    while true {
      condition.lock()
      while observers.isEmpty { condition.wait() }
      let processIdentifiers = Array(observers.keys)
      condition.unlock()

      for processIdentifier in processIdentifiers {
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        if result == processIdentifier {
          deliver(status: status, for: processIdentifier)
        } else if result == -1, errno == ECHILD {
          deliver(status: 127 << 8, for: processIdentifier)
        }
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private func deliver(status: Int32, for processIdentifier: pid_t) {
    condition.lock()
    let handler = observers.removeValue(forKey: processIdentifier)
    condition.unlock()
    handler?(status)
  }
}

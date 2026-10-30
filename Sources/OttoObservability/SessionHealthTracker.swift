import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

/// Records whether the previous session ended cleanly.
///
/// The marker file holds the process ID of the session that owns it. A marker on its own cannot
/// tell a crash from an instance that is still running (a second launch, or a helper that starts
/// a session while the app is up), so `beginSession` only reports an abnormal exit once the
/// process named in the marker is gone. A marker from before process IDs were written counts as
/// abnormal, as it always did.
public final class SessionHealthTracker: @unchecked Sendable {
  private enum Marker: Equatable {
    case absent
    case legacy
    case owned(Int32)
  }

  private let markerURL: URL
  private let lock = NSLock()
  private var sessionActive = false
  private let processIdentifier = ProcessInfo.processInfo.processIdentifier

  public init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.markerURL = directory.appending(path: "active-session.marker")
  }

  /// Claims the marker for this process. Returns `true` when the marker belonged to a session
  /// whose process is no longer running, which means it never reached `endSession`.
  @discardableResult
  public func beginSession() throws -> Bool {
    try lock.withLock {
      let previousSessionAbnormal: Bool
      switch readMarker() {
      case .absent:
        previousSessionAbnormal = false
      case .legacy:
        previousSessionAbnormal = true
      case .owned(let owner):
        previousSessionAbnormal = !Self.isProcessRunning(owner)
      }
      try Data(String(processIdentifier).utf8).write(to: markerURL, options: [.atomic])
      sessionActive = true
      return previousSessionAbnormal
    }
  }

  /// Releases the marker. A marker written by another process is left for that process, so a
  /// clean exit here never hides the other instance's crash.
  public func endSession() throws {
    try lock.withLock {
      defer { sessionActive = false }
      switch readMarker() {
      case .absent:
        return
      case .legacy, .owned(processIdentifier):
        try FileManager.default.removeItem(at: markerURL)
      case .owned:
        return
      }
    }
  }

  private func readMarker() -> Marker {
    guard let data = try? Data(contentsOf: markerURL) else { return .absent }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(text), pid > 0 else { return .legacy }
    return .owned(pid)
  }

  /// `kill` with signal 0 delivers nothing and only checks that the process exists. `EPERM`
  /// means it exists but belongs to someone else, which still counts as running.
  private static func isProcessRunning(_ pid: Int32) -> Bool {
    #if os(Windows)
      // A process we may not query still exists; only a missing one fails with invalid parameter.
      guard let handle = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, DWORD(pid))
      else { return GetLastError() == DWORD(ERROR_ACCESS_DENIED) }
      defer { CloseHandle(handle) }
      var code: DWORD = 0
      return GetExitCodeProcess(handle, &code) && code == DWORD(STILL_ACTIVE)
    #else
      return kill(pid, 0) == 0 || errno == EPERM
    #endif
  }
}

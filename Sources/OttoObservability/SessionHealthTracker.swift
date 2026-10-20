import Foundation

public final class SessionHealthTracker: @unchecked Sendable {
  private let markerURL: URL
  private let lock = NSLock()
  private var sessionActive = false

  public init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.markerURL = directory.appending(path: "active-session.marker")
  }

  @discardableResult
  public func beginSession() throws -> Bool {
    try lock.withLock {
      let previousSessionAbnormal = FileManager.default.fileExists(atPath: markerURL.path)
      try Data("active".utf8).write(to: markerURL, options: [.atomic])
      sessionActive = true
      return previousSessionAbnormal
    }
  }

  public func endSession() throws {
    try lock.withLock {
      guard sessionActive || FileManager.default.fileExists(atPath: markerURL.path) else { return }
      if FileManager.default.fileExists(atPath: markerURL.path) {
        try FileManager.default.removeItem(at: markerURL)
      }
      sessionActive = false
    }
  }
}

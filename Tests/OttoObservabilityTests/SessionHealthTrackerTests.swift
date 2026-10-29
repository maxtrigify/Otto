import Foundation
import OttoObservability
import Testing

@Suite("Session health marker")
struct SessionHealthTrackerTests {
  @Test("A marker owned by a running process means another instance, not a crash")
  func liveOwnerIsNotACrash() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try SessionHealthTracker(directory: directory)
    #expect(try first.beginSession() == false)

    // A second launch, or a helper starting a session while the app is up: the marker's
    // process (this one) is still alive.
    let second = try SessionHealthTracker(directory: directory)
    #expect(try second.beginSession() == false)
  }

  @Test("A marker whose process has exited records an abnormal exit")
  func deadOwnerIsACrash() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exit 0"]
    try process.run()
    process.waitUntilExit()
    let marker = directory.appending(path: "active-session.marker")
    try Data(String(process.processIdentifier).utf8).write(to: marker)

    let tracker = try SessionHealthTracker(directory: directory)
    #expect(try tracker.beginSession() == true)
    #expect(String(decoding: try Data(contentsOf: marker), as: UTF8.self) == String(getpid()))
    try tracker.endSession()
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("A marker from before process IDs were written still counts as abnormal")
  func legacyMarkerIsACrash() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appending(path: "active-session.marker")
    try Data("active".utf8).write(to: marker)
    let tracker = try SessionHealthTracker(directory: directory)
    #expect(try tracker.beginSession() == true)
  }

  @Test("Ending a session leaves a marker that another running process owns")
  func cleanExitKeepsAnotherInstanceMarker() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tracker = try SessionHealthTracker(directory: directory)
    try tracker.beginSession()
    let marker = directory.appending(path: "active-session.marker")
    // Another live instance took over the marker. Its exit, not ours, should clear it.
    let other = ProcessInfo.processInfo.processIdentifier == 1 ? 2 : 1
    try Data(String(other).utf8).write(to: marker)
    try tracker.endSession()
    #expect(String(decoding: try Data(contentsOf: marker), as: UTF8.self) == String(other))
  }

  private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-session-health-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

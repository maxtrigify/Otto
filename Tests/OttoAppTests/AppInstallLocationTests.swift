import Foundation
import Testing

@testable import OttoApp

@Suite("Muse.app → Otto.app install location")
struct AppInstallLocationTests {
  private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "otto-install-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeApp(_ url: URL, marker: String) throws {
    try FileManager.default.createDirectory(
      at: url.appending(path: "Contents"), withIntermediateDirectories: true)
    try Data(marker.utf8).write(to: url.appending(path: "Contents/marker"))
  }

  private func marker(_ app: URL) -> String? {
    (try? Data(contentsOf: app.appending(path: "Contents/marker")))
      .map { String(decoding: $0, as: UTF8.self) }
  }

  /// Runs a helper script with `open` replaced by `echo`, so nothing is launched, and HOME
  /// pointed at a temporary folder so the Trash is a test folder too.
  private func run(_ script: String, home: URL, arguments: [String]) throws -> Int32 {
    let file = home.appending(path: "helper-\(UUID().uuidString).sh")
    try script.replacingOccurrences(of: "/usr/bin/open", with: "/bin/echo")
      .write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    // A PID that has already exited, so the wait loop ends immediately.
    let finished = Process()
    finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try finished.run()
    finished.waitUntilExit()
    process.arguments = [file.path, String(finished.processIdentifier)] + arguments
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  @Test("An app already named Otto.app updates in place")
  func inPlace() {
    let current = URL(fileURLWithPath: "/Applications/Otto.app")
    let plan = AppInstallLocation.plan(currentBundle: current, bundleIdentifier: { _ in nil })
    #expect(plan.target.path == current.path)
    #expect(plan.retired == nil)
  }

  @Test("Otto running as Muse.app targets Otto.app and retires Muse.app")
  func renamesLegacyBundle() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let muse = folder.appending(path: "Muse.app")
    try makeApp(muse, marker: "old")
    let plan = AppInstallLocation.plan(currentBundle: muse, bundleIdentifier: { _ in nil })
    #expect(plan.target.lastPathComponent == "Otto.app")
    #expect(plan.retired?.lastPathComponent == "Muse.app")
  }

  @Test("An existing Otto.app is replaced only when it is ours")
  func respectsUnrelatedOttoApp() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let muse = folder.appending(path: "Muse.app")
    try makeApp(muse, marker: "old")
    try makeApp(folder.appending(path: "Otto.app"), marker: "someone else")

    let unrelated = AppInstallLocation.plan(
      currentBundle: muse, bundleIdentifier: { _ in "com.example.otto" })
    #expect(unrelated.target.lastPathComponent == "Muse.app")
    #expect(unrelated.retired == nil)

    let ours = AppInstallLocation.plan(
      currentBundle: muse, bundleIdentifier: { _ in "io.openotto.desktop" })
    #expect(ours.target.lastPathComponent == "Otto.app")
    #expect(ours.retired?.lastPathComponent == "Muse.app")
  }

  @Test("The launch rename runs once, only for the release bundle at Muse.app")
  func launchRelocationGuards() throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let muse = folder.appending(path: "Muse.app")
    try makeApp(muse, marker: "v")
    let suite = "otto-install-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
      AppInstallLocation.launchRelocation(
        currentBundle: muse, bundleIdentifier: "io.openotto.desktop.dev", defaults: defaults)
        == nil)
    let plan = AppInstallLocation.launchRelocation(
      currentBundle: muse, bundleIdentifier: "io.openotto.desktop", defaults: defaults)
    #expect(plan?.target.lastPathComponent == "Otto.app")

    defaults.set(true, forKey: AppInstallLocation.relocationAttemptedKey)
    #expect(
      AppInstallLocation.launchRelocation(
        currentBundle: muse, bundleIdentifier: "io.openotto.desktop", defaults: defaults)
        == nil)
  }

  @Test("Update helper installs Otto.app, then moves Muse.app to the Trash")
  func helperSwapsAndRetires() throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    let applications = home.appending(path: "Applications")
    let muse = applications.appending(path: "Muse.app")
    let otto = applications.appending(path: "Otto.app")
    let staged = home.appending(path: "staged/Otto.app")
    try makeApp(muse, marker: "0.1.59")
    try makeApp(staged, marker: "0.2.0")

    let status = try run(
      AppUpdateController.relaunchHelperScript, home: home,
      arguments: [staged.path, otto.path, muse.path])

    #expect(status == 0)
    #expect(marker(otto) == "0.2.0")
    #expect(!FileManager.default.fileExists(atPath: muse.path))
    let trashed = try FileManager.default.contentsOfDirectory(
      atPath: home.appending(path: ".Trash").path)
    #expect(trashed.count == 1)
    #expect(trashed.first?.hasPrefix("Muse ") == true)
  }

  @Test("Update helper replaces Otto.app in place")
  func helperReplacesInPlace() throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    let otto = home.appending(path: "Applications/Otto.app")
    let staged = home.appending(path: "staged/Otto.app")
    try makeApp(otto, marker: "0.2.0")
    try makeApp(staged, marker: "0.2.1")

    let status = try run(
      AppUpdateController.relaunchHelperScript, home: home,
      arguments: [staged.path, otto.path, ""])

    #expect(status == 0)
    #expect(marker(otto) == "0.2.1")
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: home.appending(path: "Applications").path)
    #expect(leftovers == ["Otto.app"])
  }

  @Test("A failed copy leaves the installed app untouched")
  func helperFailureKeepsApp() throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    let applications = home.appending(path: "Applications")
    let muse = applications.appending(path: "Muse.app")
    try makeApp(muse, marker: "0.1.59")

    let status = try run(
      AppUpdateController.relaunchHelperScript, home: home,
      arguments: [
        home.appending(path: "missing/Otto.app").path,
        applications.appending(path: "Otto.app").path, muse.path,
      ])

    #expect(status != 0)
    #expect(marker(muse) == "0.1.59")
    #expect(!FileManager.default.fileExists(atPath: applications.appending(path: "Otto.app").path))
  }

  @Test("Launch rename helper renames Muse.app to Otto.app")
  func relocationHelper() throws {
    let home = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: home) }
    let muse = home.appending(path: "Applications/Muse.app")
    let otto = home.appending(path: "Applications/Otto.app")
    try makeApp(muse, marker: "0.2.0")

    let status = try run(
      AppInstallLocation.relocationHelperScript, home: home, arguments: [muse.path, otto.path])

    #expect(status == 0)
    #expect(marker(otto) == "0.2.0")
    #expect(!FileManager.default.fileExists(atPath: muse.path))
  }
}

import Foundation
import Testing

@testable import OttoServices

@Suite("Backup and restore")
struct OttoBackupTests {
  /// A throwaway workspace, support folder and preferences suite for one test.
  private struct Fixture {
    let root: URL
    let workspace: URL
    let locations: OttoBackup.Locations
    let defaults: UserDefaults
    let suiteName: String

    init() throws {
      root = FileManager.default.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
      workspace = root.appending(path: "Workspace")
      locations = OttoBackup.Locations(supportDirectory: root.appending(path: "Support"))
      suiteName = "otto.backup.tests.\(UUID().uuidString)"
      defaults = try #require(UserDefaults(suiteName: suiteName))
      try FileManager.default.createDirectory(
        at: state.appending(path: OttoBackup.avatarFolder), withIntermediateDirectories: true)
    }

    var state: URL { workspace.appending(path: ".otto") }

    func write(_ text: String, to name: String) throws {
      try Data(text.utf8).write(to: state.appending(path: name))
    }

    func read(_ name: String) -> String? {
      (try? Data(contentsOf: state.appending(path: name))).map {
        String(decoding: $0, as: UTF8.self)
      }
    }

    func cleanUp() {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }
  }

  @Test("A backup restores bots, connector choices and settings after the next launch")
  func roundTrip() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(#"{"profiles":[{"name":"Ada"}]}"#, to: "agent-profiles.json")
    try fixture.write(#"{"grants":{"email":["a"]}}"#, to: "connector-access.json")
    try fixture.write("About me", to: "user.md")
    try fixture.write(#"{"sessions":1}"#, to: "bot-activity.json")
    try Data([0x89, 0x50]).write(
      to: fixture.state.appending(path: "\(OttoBackup.avatarFolder)/ada.png"))
    fixture.defaults.set("daylight", forKey: "otto.appearance.latestSelectedTheme")
    fixture.defaults.set("whistle", forKey: "otto.voice.localSpeechEngine")

    let archive = fixture.root.appending(path: "Saved.ottobackup")
    let exported = try OttoBackup.export(
      workspacePath: fixture.workspace.path, defaults: fixture.defaults, to: archive,
      appVersion: "1.2.3")
    #expect(
      Set(exported.files)
        == ["agent-profiles.json", "connector-access.json", "user.md", "bot-avatars/ada.png"])
    #expect(exported.settingsCount == 2)
    #expect(try OttoBackup.inspect(archive) == exported)

    // The person changes things, then restores.
    try fixture.write(#"{"profiles":[]}"#, to: "agent-profiles.json")
    try fixture.write(#"{"steps":[]}"#, to: "routines.json")
    fixture.defaults.set("night", forKey: "otto.appearance.latestSelectedTheme")
    try OttoBackup.stageRestore(
      from: archive, workspacePath: fixture.workspace.path, locations: fixture.locations)
    #expect(fixture.read("agent-profiles.json") == #"{"profiles":[]}"#)

    let message = try #require(
      OttoBackup.applyPendingRestore(
        defaults: fixture.defaults, locations: fixture.locations, appVersion: "1.2.3"))
    #expect(message.hasPrefix("Restored 4 files and 2 settings"))
    #expect(fixture.read("agent-profiles.json") == #"{"profiles":[{"name":"Ada"}]}"#)
    // Files the backup does not hold are left alone.
    #expect(fixture.read("routines.json") == #"{"steps":[]}"#)
    #expect(fixture.read("bot-activity.json") == #"{"sessions":1}"#)
    #expect(fixture.defaults.string(forKey: "otto.appearance.latestSelectedTheme") == "daylight")
    #expect(fixture.defaults.string(forKey: OttoBackup.lastRestoreKey) == message)
    #expect(!FileManager.default.fileExists(atPath: fixture.locations.pendingRestore.path))
    #expect(
      OttoBackup.applyPendingRestore(
        defaults: fixture.defaults, locations: fixture.locations, appVersion: "1.2.3") == nil)

    // The setup that was replaced was saved first, and holds the pre-restore state.
    let saved = try FileManager.default.contentsOfDirectory(
      at: fixture.locations.backups, includingPropertiesForKeys: nil)
    let safety = try #require(saved.first)
    #expect(saved.count == 1)
    #expect(safety.lastPathComponent.hasPrefix("Before restore "))
    #expect(try OttoBackup.inspect(safety).files.contains("routines.json"))
  }

  @Test("Secret-looking files and settings never go into a backup")
  func secretsExcluded() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(#"{"host":"smtp.example.com"}"#, to: "smtp.json")
    try fixture.write(#"{"note":"Bearer abc123"}"#, to: "bot-notes.json")
    try fixture.write("token sk-ant-abc", to: "charter.md")
    try fixture.write("{}", to: "app-connections.json")
    fixture.defaults.set(true, forKey: "otto.voice.announceFailures")
    fixture.defaults.set("x", forKey: "otto.voice.whistle.acceptedTerms")
    fixture.defaults.set("x", forKey: "otto.slack.apiKey")
    fixture.defaults.set("x", forKey: "otto.composerDrafts")
    fixture.defaults.set("x", forKey: "otto.telegram.abc.offset")
    fixture.defaults.set("x", forKey: "unrelated.setting")

    let archive = fixture.root.appending(path: "Saved.ottobackup")
    let manifest = try OttoBackup.export(
      workspacePath: fixture.workspace.path, defaults: fixture.defaults, to: archive,
      appVersion: "1")
    #expect(manifest.files == ["smtp.json"])
    #expect(manifest.settingsCount == 1)
    #expect(OttoBackup.isPortableSetting("otto.voice.announceFailures"))
    #expect(!OttoBackup.isPortableSetting("otto.github.accessToken"))
    #expect(!OttoBackup.isPortableSetting("otto.migration.legacyDefaultsImported"))
  }

  @Test("Archives with links, unsafe paths, bad JSON or a foreign manifest are refused")
  func hostileArchives() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let manifest = """
      {"format":"otto-backup","version":1,"createdAt":"2026-10-29T12:00:00Z",
       "appVersion":"1","files":[],"settingsCount":0}
      """

    func archive(_ name: String, build: (URL) throws -> Void) throws -> URL {
      let folder = fixture.root.appending(path: "build-\(name)")
      try FileManager.default.createDirectory(
        at: folder.appending(path: "workspace"), withIntermediateDirectories: true)
      try build(folder)
      let output = fixture.root.appending(path: "\(name).ottobackup")
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-c", "-k", folder.path, output.path]
      try process.run()
      process.waitUntilExit()
      return output
    }

    let ignored = try archive("ignored") { folder in
      try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
      try Data("{}".utf8).write(to: folder.appending(path: "workspace/agent-profiles.json"))
      try Data("{}".utf8).write(to: folder.appending(path: "workspace/app-connections.json"))
      try Data("x".utf8).write(to: folder.appending(path: "workspace/notes.txt"))
    }
    try OttoBackup.stageRestore(
      from: ignored, workspacePath: fixture.workspace.path, locations: fixture.locations)
    let staged = try FileManager.default.contentsOfDirectory(
      atPath: fixture.locations.pendingRestore.appending(path: "workspace").path)
    #expect(Set(staged) == ["agent-profiles.json", OttoBackup.avatarFolder])

    let linked = try archive("linked") { folder in
      try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
      try FileManager.default.createSymbolicLink(
        atPath: folder.appending(path: "workspace/agent-profiles.json").path,
        withDestinationPath: "/etc/hosts")
    }
    #expect(throws: OttoBackup.BackupError.invalidArchive("it contains a link")) {
      try OttoBackup.inspect(linked)
    }

    let badJSON = try archive("bad-json") { folder in
      try Data(manifest.utf8).write(to: folder.appending(path: "manifest.json"))
      try Data("not json".utf8).write(to: folder.appending(path: "workspace/routines.json"))
    }
    #expect(throws: OttoBackup.BackupError.invalidArchive("routines.json is not valid JSON")) {
      try OttoBackup.inspect(badJSON)
    }

    let foreign = try archive("foreign") { folder in
      try Data(manifest.replacingOccurrences(of: "otto-backup", with: "other").utf8)
        .write(to: folder.appending(path: "manifest.json"))
    }
    #expect(throws: OttoBackup.BackupError.invalidArchive("it was not made by Otto")) {
      try OttoBackup.inspect(foreign)
    }

    // An entry that climbs out of the extraction folder is refused before anything is written.
    let escape = fixture.root.appending(path: "escape.ottobackup")
    let script = """
      import sys, zipfile
      with zipfile.ZipFile(sys.argv[1], "w") as z:
          z.writestr("manifest.json", sys.argv[2])
          z.writestr("../escaped.txt", "x")
      """
    let python = Process()
    python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    python.arguments = ["-I", "-c", script, escape.path, manifest]
    try python.run()
    python.waitUntilExit()
    #expect(throws: OttoBackup.BackupError.invalidArchive("it contains an unsafe path")) {
      try OttoBackup.inspect(escape)
    }
  }

  @Test("A restore whose current setup cannot be saved changes nothing")
  func safetyBackupRequired() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    try fixture.write(#"{"profiles":[{"name":"Ada"}]}"#, to: "agent-profiles.json")
    let archive = fixture.root.appending(path: "Saved.ottobackup")
    try OttoBackup.export(
      workspacePath: fixture.workspace.path, defaults: fixture.defaults, to: archive,
      appVersion: "1")
    try fixture.write(#"{"profiles":[]}"#, to: "agent-profiles.json")
    try OttoBackup.stageRestore(
      from: archive, workspacePath: fixture.workspace.path, locations: fixture.locations)
    // A file where the Backups folder should be makes the safety backup fail.
    try Data().write(to: fixture.locations.backups)

    let message = OttoBackup.applyPendingRestore(
      defaults: fixture.defaults, locations: fixture.locations, appVersion: "1")
    #expect(message?.hasPrefix("The backup was not restored") == true)
    #expect(fixture.read("agent-profiles.json") == #"{"profiles":[]}"#)
    #expect(!FileManager.default.fileExists(atPath: fixture.locations.pendingRestore.path))
  }
}

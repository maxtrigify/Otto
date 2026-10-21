import Foundation
import OttoModels
import Testing

@Suite("Muse → Otto rename migration")
struct OttoRenameMigrationTests {
  private func temporaryHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "otto-rename-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func read(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
  }

  // MARK: Directories

  @Test("Muse only: the folder moves to Otto and Muse becomes a symlink to it")
  func moveLegacyOnly() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appending(path: "Library/Application Support")
    let legacy = support.appending(path: "Muse")
    let current = support.appending(path: "Otto")
    try write("sessions", to: legacy.appending(path: "workspace.sqlite"))

    let outcome = OttoDirectoryMigration.migrate(legacy: legacy, current: current)

    #expect(outcome == .moved)
    #expect(read(current.appending(path: "workspace.sqlite")) == "sessions")
    #expect(isSymlink(legacy))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: legacy.path) == "Otto")
    // An older build that opens the old path still reaches the same file.
    #expect(read(legacy.appending(path: "workspace.sqlite")) == "sessions")
  }

  @Test("A partially created Otto workspace recovers bindings and keeps new files")
  func partiallyCreatedWorkspace() throws {
    let root = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("bindings", to: root.appending(path: ".muse/office.json"))
    try write("old image", to: root.appending(path: ".muse/captures/old.png"))
    try write("old log", to: root.appending(path: ".muse/brain/log/old.md"))
    try write("legacy", to: root.appending(path: ".muse/brain/log/shared.md"))
    try write("new", to: root.appending(path: ".otto/brain/log/shared.md"))
    try write("image", to: root.appending(path: ".otto/chat-attachments/image.png"))
    #expect(OttoWorkspaceMigration.migrateStateFolder(workspacePath: root.path) == .mergedMissing)
    #expect(read(root.appending(path: ".otto/office.json")) == "bindings")
    #expect(read(root.appending(path: ".otto/brain/log/old.md")) == "old log")
    #expect(read(root.appending(path: ".otto/brain/log/shared.md")) == "new")
    #expect(read(root.appending(path: ".otto/chat-attachments/image.png")) == "image")
    #expect(read(root.appending(path: ".muse/office.json")) == "bindings")
    #expect(read(root.appending(path: ".muse/captures/old.png")) == "old image")
    #expect(read(root.appending(path: ".otto/captures/old.png")) == nil)
    try FileManager.default.removeItem(at: root.appending(path: ".otto/office.json"))
    #expect(OttoWorkspaceMigration.migrateStateFolder(workspacePath: root.path) == .alreadyMigrated)
    #expect(read(root.appending(path: ".otto/office.json")) == nil)
  }

  @Test("Workspace import does not traverse legacy or current symlinks")
  func workspaceImportSymlinks() throws {
    let root = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("outside", to: root.appending(path: "outside/keep"))
    try write("legacy", to: root.appending(path: ".muse/nested/old"))
    try FileManager.default.createDirectory(
      at: root.appending(path: ".otto"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: ".otto/nested"), withDestinationURL: root.appending(path: "outside"))
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: ".muse/link"), withDestinationURL: root.appending(path: "outside"))
    #expect(OttoWorkspaceMigration.migrateStateFolder(workspacePath: root.path) == .mergedMissing)
    #expect(read(root.appending(path: "outside/old")) == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".otto/link").path))
  }

  @Test("Both exist: nothing is touched")
  func bothExist() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    try write("old", to: legacy.appending(path: "a.txt"))
    try write("new", to: current.appending(path: "a.txt"))

    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .bothExist)
    #expect(read(legacy.appending(path: "a.txt")) == "old")
    #expect(read(current.appending(path: "a.txt")) == "new")
    #expect(!isSymlink(legacy))
  }

  @Test("Already migrated: a second run is a no-op")
  func idempotent() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    try write("data", to: legacy.appending(path: "a.txt"))

    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .moved)
    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .alreadyMigrated)
    #expect(read(current.appending(path: "a.txt")) == "data")
  }

  @Test("A symlink at the legacy name is left alone")
  func legacySymlinkIsNoOp() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let elsewhere = home.appending(path: "Elsewhere")
    try write("data", to: elsewhere.appending(path: "a.txt"))
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: elsewhere)

    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .alreadyMigrated)
    #expect(!FileManager.default.fileExists(atPath: current.path))
    #expect(read(elsewhere.appending(path: "a.txt")) == "data")
  }

  @Test("Fresh install: no symlink is invented and nothing is created")
  func freshInstall() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    #expect(
      OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .nothingToMigrate)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .alreadyMigrated)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
  }

  @Test("An interrupted move (renamed, no symlink yet) is completed on the next run")
  func resumesAfterCrash() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    try write("data", to: current.appending(path: "a.txt"))
    try write("marker", to: current.appending(path: OttoDirectoryMigration.markerFileName))

    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .repairedSymlink)
    #expect(isSymlink(legacy))
    #expect(read(legacy.appending(path: "a.txt")) == "data")
  }

  @Test("A plain file at the legacy name is not treated as a folder")
  func legacyFile() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    try write("not a folder", to: legacy)
    #expect(
      OttoDirectoryMigration.migrate(legacy: legacy, current: home.appending(path: "Otto"))
        == .legacyNotDirectory)
    #expect(read(legacy) == "not a folder")
  }

  @Test("Launch migration moves Application Support, Logs and Caches under an injected home")
  func launchMigrationLibraryFolders() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let library = home.appending(path: "Library")
    try write("db", to: library.appending(path: "Application Support/Muse/workspace.sqlite"))
    try write("log", to: library.appending(path: "Logs/Muse/dev.log"))
    try write("cache", to: library.appending(path: "Caches/Muse/SwiftPM/x"))
    let suite = "otto-rename-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let migration = OttoLaunchMigration(
      home: home, defaults: defaults, bundleIdentifier: OttoNames.releaseBundleIdentifier,
      legacyDefaults: { _ in [:] })
    let report = migration.run()

    #expect(report.migratedFromMuse)
    #expect(read(library.appending(path: "Application Support/Otto/workspace.sqlite")) == "db")
    #expect(read(library.appending(path: "Logs/Otto/dev.log")) == "log")
    #expect(read(library.appending(path: "Caches/Otto/SwiftPM/x")) == "cache")
    for parent in ["Application Support", "Logs", "Caches"] {
      #expect(isSymlink(library.appending(path: "\(parent)/Muse")))
    }
    #expect(OttoRenameNotice.isPending(in: defaults))

    let second = migration.run()
    #expect(second.lines.isEmpty)
  }

  /// Found rehearsing the 0.1.59 → Otto update on a developer Mac: test runs had created
  /// `Application Support/Otto` holding only `dev-secrets.json` and `Messaging/state.json`.
  @Test("A stray Otto folder without a workspace database is set aside and Muse data moves in")
  func strayOttoFolderIsSetAside() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let support = home.appending(path: "Library/Application Support")
    try write("sessions", to: support.appending(path: "Muse/workspace.sqlite"))
    try write("{}", to: support.appending(path: "Otto/dev-secrets.json"))
    try write("{}", to: support.appending(path: "Otto/Messaging/state.json"))
    let suite = "otto-rename-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let report = OttoLaunchMigration(
      home: home, defaults: defaults, bundleIdentifier: OttoNames.releaseBundleIdentifier,
      legacyDefaults: { _ in [:] }
    ).run()

    #expect(report.migratedFromMuse)
    #expect(read(support.appending(path: "Otto/workspace.sqlite")) == "sessions")
    #expect(isSymlink(support.appending(path: "Muse")))
    let aside = try FileManager.default.contentsOfDirectory(atPath: support.path)
      .filter { $0.hasPrefix("Otto set aside ") }
    #expect(aside.count == 1)
    #expect(
      read(support.appending(path: "\(try #require(aside.first))/dev-secrets.json")) == "{}")
    #expect(report.lines.contains { $0.contains("had no workspace database") })
  }

  @Test("An Otto folder that has its own workspace database is never set aside")
  func realOttoFolderIsKept() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let legacy = home.appending(path: "Muse")
    let current = home.appending(path: "Otto")
    try write("old", to: legacy.appending(path: "workspace.sqlite"))
    try write("new", to: current.appending(path: "workspace.sqlite"))

    #expect(
      OttoDirectoryMigration.setAsideIfStray(
        legacy: legacy, current: current, requiredFile: "workspace.sqlite") == nil)
    #expect(OttoDirectoryMigration.migrate(legacy: legacy, current: current) == .bothExist)
    #expect(read(current.appending(path: "workspace.sqlite")) == "new")
    #expect(read(legacy.appending(path: "workspace.sqlite")) == "old")
  }

  @Test("A fresh Otto install never shows the rename notice")
  func freshInstallHasNoNotice() throws {
    let home = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let suite = "otto-rename-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let report = OttoLaunchMigration(
      home: home, defaults: defaults, bundleIdentifier: OttoNames.releaseBundleIdentifier,
      legacyDefaults: { _ in [:] }
    ).run()
    #expect(!report.migratedFromMuse)
    #expect(!OttoRenameNotice.isPending(in: defaults))
  }

  // MARK: Workspace

  @Test("Workspace .muse moves to .otto with a .muse symlink; .muse-worktrees likewise")
  func workspaceFolders() throws {
    let workspace = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try write("{}", to: workspace.appending(path: ".muse/home-cards.json"))
    try write("wt", to: workspace.appending(path: ".muse-worktrees/agent/README"))

    #expect(OttoWorkspaceMigration.migrateStateFolder(workspacePath: workspace.path) == .moved)
    #expect(
      OttoWorkspaceMigration.migrateWorktreesFolder(repositoryPath: workspace.path) == .moved)
    #expect(read(workspace.appending(path: ".otto/home-cards.json")) == "{}")
    #expect(read(workspace.appending(path: ".muse/home-cards.json")) == "{}")
    #expect(isSymlink(workspace.appending(path: ".muse")))
    #expect(read(workspace.appending(path: ".otto-worktrees/agent/README")) == "wt")
    #expect(isSymlink(workspace.appending(path: ".muse-worktrees")))
    #expect(
      OttoWorkspaceMigration.migrateStateFolder(workspacePath: workspace.path)
        == .alreadyMigrated)
  }

  @Test("Workspace with both .muse and .otto keeps both untouched")
  func workspaceBothExist() throws {
    let workspace = try temporaryHome()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try write("old", to: workspace.appending(path: ".muse/a"))
    try write("new", to: workspace.appending(path: ".otto/a"))
    #expect(
      OttoWorkspaceMigration.migrateStateFolder(workspacePath: workspace.path) == .mergedMissing)
    #expect(read(workspace.appending(path: ".muse/a")) == "old")
    #expect(read(workspace.appending(path: ".otto/a")) == "new")
  }

  // MARK: Defaults

  @Test("Legacy keys map muse. → otto. and Muse… → Otto…, other keys unchanged")
  func keyMapping() {
    #expect(LegacyDefaultsImporter.mappedKey("muse.voice.engine") == "otto.voice.engine")
    #expect(
      LegacyDefaultsImporter.mappedKey("MuseUpdateSkippedVersion") == "OttoUpdateSkippedVersion")
    #expect(LegacyDefaultsImporter.mappedKey("Museum") == "Museum")
    #expect(LegacyDefaultsImporter.mappedKey("NSWindow Frame main") == "NSWindow Frame main")
    #expect(LegacyDefaultsImporter.mappedKey("amuse.x") == "amuse.x")
  }

  @Test("Import copies legacy values, never overwrites, and runs once")
  func defaultsImport() throws {
    let suite = "otto-rename-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("dark", forKey: "otto.appearance.latestSelectedTheme")

    let legacy: [String: Any] = [
      "muse.appearance.latestSelectedTheme": "light",
      "muse.voice.wakeWordEnabled": true,
      "MuseUpdateRolloutBucket": 42,
      "NSWindow Frame main": "0 0 100 100",
    ]
    let report = LegacyDefaultsImporter.importValues(legacy, into: defaults)

    #expect(report.skippedKeys == ["muse.appearance.latestSelectedTheme"])
    #expect(report.importedKeys.count == 3)
    #expect(defaults.string(forKey: "otto.appearance.latestSelectedTheme") == "dark")
    #expect(defaults.bool(forKey: "otto.voice.wakeWordEnabled"))
    #expect(defaults.integer(forKey: "OttoUpdateRolloutBucket") == 42)
    #expect(defaults.string(forKey: "NSWindow Frame main") == "0 0 100 100")
    #expect(defaults.bool(forKey: LegacyDefaultsImporter.markerKey))

    // A second import (even with different legacy values) changes nothing.
    let again = LegacyDefaultsImporter.importValues(
      ["muse.voice.wakeWordEnabled": false, "muse.new": 1], into: defaults)
    #expect(again.alreadyImported)
    #expect(defaults.bool(forKey: "otto.voice.wakeWordEnabled"))
    #expect(defaults.object(forKey: "otto.new") == nil)
  }

  @Test("The launch migration reads the matching legacy domain for release and dev builds")
  func legacyDomainSelection() throws {
    for (bundle, expected) in [
      (OttoNames.releaseBundleIdentifier, "app.muse.desktop"),
      (OttoNames.developmentBundleIdentifier, "app.muse.desktop.dev"),
    ] {
      let home = try temporaryHome()
      defer { try? FileManager.default.removeItem(at: home) }
      let suite = "otto-rename-tests-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      var requested: [String] = []
      let report = OttoLaunchMigration(
        home: home, defaults: defaults, bundleIdentifier: bundle,
        legacyDefaults: { domain in
          requested.append(domain)
          return ["muse.voice.engine": "local"]
        }
      ).run()
      #expect(requested == [expected])
      #expect(report.migratedFromMuse)
      #expect(defaults.string(forKey: "otto.voice.engine") == "local")
    }
  }

  // MARK: Environment and names

  @Test("OTTO_ variables win; MUSE_ variables are read as a fallback")
  func environmentFallback() {
    let both = ["OTTO_CONTROL_TOKEN": "new", "MUSE_CONTROL_TOKEN": "old"]
    #expect(OttoEnvironment.value("CONTROL_TOKEN", in: both) == "new")
    #expect(OttoEnvironment.value("CONTROL_TOKEN", in: ["MUSE_CONTROL_TOKEN": "old"]) == "old")
    #expect(OttoEnvironment.value("CONTROL_TOKEN", in: [:]) == nil)
    #expect(
      OttoEnvironment.nonEmptyValue(
        "UPDATE_FEED_URL", in: ["OTTO_UPDATE_FEED_URL": "", "MUSE_UPDATE_FEED_URL": "https://x"])
        == "https://x")
    #expect(OttoEnvironment.key("NODE_ID") == "OTTO_NODE_ID")
    #expect(OttoEnvironment.isOttoVariable("MUSE_NODE_ID"))
    #expect(OttoEnvironment.isOttoVariable("OTTO_NODE_ID"))
    #expect(!OttoEnvironment.isOttoVariable("PATH"))
  }

  @Test("otto:// is primary and muse:// is still an app URL")
  func urlSchemes() {
    #expect(OttoNames.urlScheme == "otto")
    #expect(OttoNames.isAppURLScheme("otto"))
    #expect(OttoNames.isAppURLScheme("MUSE"))
    #expect(!OttoNames.isAppURLScheme("https"))
    #expect(!OttoNames.isAppURLScheme(nil))
  }
}

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Names that changed when Muse became Otto, kept in one place so every legacy fallback reads
/// from the same table. New code writes the Otto names; the legacy names are only ever read.
public enum OttoNames {
  public static let applicationSupportFolder = "Otto"
  public static let legacyApplicationSupportFolder = "Muse"
  /// Per-workspace state folder (`<workspace>/.otto`).
  public static let workspaceStateFolder = ".otto"
  public static let legacyWorkspaceStateFolder = ".muse"
  /// Agent worktrees inside a repository (`<repo>/.otto-worktrees`).
  public static let agentWorktreesFolder = ".otto-worktrees"
  public static let legacyAgentWorktreesFolder = ".muse-worktrees"

  public static let releaseBundleIdentifier = "io.openotto.desktop"
  public static let developmentBundleIdentifier = "io.openotto.desktop.dev"
  public static let legacyReleaseBundleIdentifier = "app.muse.desktop"
  public static let legacyDevelopmentBundleIdentifier = "app.muse.desktop.dev"

  /// `otto://` is primary; `muse://` stays registered because pairing links and QR codes
  /// produced before the rename are still in circulation.
  public static let urlScheme = "otto"
  public static let legacyURLScheme = "muse"
  public static let urlSchemes: Set<String> = [urlScheme, legacyURLScheme]

  /// True for `otto` and the legacy `muse` scheme, case-insensitively.
  public static func isAppURLScheme(_ scheme: String?) -> Bool {
    guard let scheme else { return false }
    return urlSchemes.contains(scheme.lowercased())
  }

  /// The pre-rename defaults domain that matches a current bundle identifier.
  public static func legacyBundleIdentifier(for bundleIdentifier: String?) -> String? {
    switch bundleIdentifier {
    case releaseBundleIdentifier: legacyReleaseBundleIdentifier
    case developmentBundleIdentifier: legacyDevelopmentBundleIdentifier
    default: nil
    }
  }
}

/// Process environment lookups for Otto's own variables. `OTTO_<NAME>` is primary; the
/// pre-rename `MUSE_<NAME>` is read as a fallback so existing shells, launch agents and remote
/// hosts keep working.
public enum OttoEnvironment {
  public static let prefix = "OTTO_"
  public static let legacyPrefix = "MUSE_"

  /// The primary variable name, e.g. `key("CONTROL_TOKEN") == "OTTO_CONTROL_TOKEN"`.
  public static func key(_ name: String) -> String { prefix + name }

  /// Reads `OTTO_<name>`, falling back to `MUSE_<name>`.
  public static func value(
    _ name: String,
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    environment[prefix + name] ?? environment[legacyPrefix + name]
  }

  /// Like `value(_:in:)` but treats an empty string as unset.
  public static func nonEmptyValue(
    _ name: String,
    in environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    if let value = environment[prefix + name], !value.isEmpty { return value }
    if let value = environment[legacyPrefix + name], !value.isEmpty { return value }
    return nil
  }

  /// True for variables that belong to Otto under either prefix.
  public static func isOttoVariable(_ key: String) -> Bool {
    key.hasPrefix(prefix) || key.hasPrefix(legacyPrefix)
  }
}

/// Where Otto keeps app-level state on disk.
public enum OttoPaths {
  /// `~/Library/Application Support/Otto` (or the platform equivalent).
  public static func applicationSupport(fileManager: FileManager = .default) -> URL {
    applicationSupportBase(fileManager: fileManager)
      .appending(path: OttoNames.applicationSupportFolder, directoryHint: .isDirectory)
  }

  public static func applicationSupportBase(fileManager: FileManager = .default) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appending(
        path: "Library/Application Support", directoryHint: .isDirectory)
  }

  public static let defaultWorkspaceFolder = "Otto Workspace"
  public static let legacyDefaultWorkspaceFolder = "Muse Workspace"
  public static let defaultProfilesFolder = "Otto Profiles"
  public static let legacyDefaultProfilesFolder = "Muse Profiles"

  /// A default folder under `parent` (usually ~/Documents). User folders are never moved: when
  /// only the pre-rename folder exists it is returned as-is; otherwise the Otto name is used.
  public static func preferredUserFolder(
    in parent: URL, name: String, legacyName: String, fileManager: FileManager = .default
  ) -> URL {
    let current = parent.appending(path: name, directoryHint: .isDirectory)
    let legacy = parent.appending(path: legacyName, directoryHint: .isDirectory)
    if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
      return legacy
    }
    return current
  }

  /// `<workspace>/.otto`.
  public static func workspaceState(_ workspacePath: String) -> URL {
    URL(fileURLWithPath: workspacePath)
      .appending(path: OttoNames.workspaceStateFolder, directoryHint: .isDirectory)
  }

  /// `<workspace>/.otto/<relativePath>` as a path string.
  public static func workspaceStatePath(_ workspacePath: String, _ relativePath: String) -> String {
    (workspacePath as NSString)
      .appendingPathComponent(OttoNames.workspaceStateFolder + "/" + relativePath)
  }
}

/// Moves one pre-rename directory to its Otto name without ever deleting or overwriting data.
///
/// The move is a single same-volume `rename(2)` that refuses to replace an existing destination,
/// followed by a symlink at the old name so an older Muse build that is still running (or is
/// launched later) keeps finding the same files. A marker file written before the rename makes
/// the step resumable: if the process dies between the rename and the symlink, the next run sees
/// the marker in the new directory and finishes the symlink.
public enum OttoDirectoryMigration {
  public static let markerFileName = ".otto-migrated-from-muse"

  public enum Outcome: Equatable, Sendable {
    /// The legacy directory was renamed and a symlink left in its place.
    case moved
    /// An interrupted earlier move was completed by creating the missing symlink.
    case repairedSymlink
    /// Nothing to do: the legacy name is already a symlink, or there was never legacy data.
    case alreadyMigrated
    case nothingToMigrate
    /// Both names hold real directories. Nothing is touched; Otto uses the new one.
    case bothExist
    /// Missing workspace files were copied from the legacy folder without replacing current data.
    case mergedMissing
    /// The legacy path is not a directory (a plain file, for instance). Left alone.
    case legacyNotDirectory
    case failed(String)

    /// Whether this run actually brought pre-rename data across.
    public var migratedData: Bool {
      self == .moved || self == .repairedSymlink || self == .mergedMissing
    }
  }

  @discardableResult
  public static func migrate(
    legacy: URL, current: URL, fileManager: FileManager = .default
  ) -> Outcome {
    let legacyPath = legacy.path
    let currentPath = current.path
    switch (entryKind(legacyPath), entryKind(currentPath)) {
    case (.symlink, _):
      return .alreadyMigrated
    case (.missing, .missing):
      return .nothingToMigrate
    case (.missing, .directory):
      // A crash after the rename but before the symlink leaves only the new directory, with
      // the marker inside it. Finish the job; never invent a symlink for a fresh install.
      guard fileManager.fileExists(atPath: current.appending(path: markerFileName).path) else {
        return .alreadyMigrated
      }
      return linkLegacy(legacy, to: current, fileManager: fileManager)
        ? .repairedSymlink : .failed("could not create symlink at \(legacyPath)")
    case (.missing, _):
      return .alreadyMigrated
    case (.directory, .missing):
      break
    case (.directory, _):
      return .bothExist
    case (.other, _):
      return .legacyNotDirectory
    }

    let marker = legacy.appending(path: markerFileName)
    let note = "Moved from \(legacyPath) to \(currentPath) at \(Date())\n"
    do {
      try Data(note.utf8).write(to: marker, options: .atomic)
    } catch {
      return .failed("could not write migration marker: \(error.localizedDescription)")
    }
    if let error = renameExclusive(from: legacyPath, to: currentPath) {
      try? fileManager.removeItem(at: marker)
      return .failed("could not rename \(legacyPath): \(error)")
    }
    // The data now lives at the new name. If the symlink cannot be created, keep it there:
    // moving it back would leave this build starting from an empty directory.
    return linkLegacy(legacy, to: current, fileManager: fileManager)
      ? .moved : .failed("moved, but could not create symlink at \(legacyPath)")
  }

  /// Moves `current` aside when it is a stray folder rather than migrated data: both names are
  /// real directories, `legacy` holds `requiredFile` and `current` does not. Test runs and debug
  /// builds leave exactly that behind (`Application Support/Otto` with only `dev-secrets.json`),
  /// and treating it as "both exist" would open Otto with none of the person's Muse sessions.
  /// The folder is renamed, never deleted. Returns where it went, or nil when nothing moved.
  @discardableResult
  public static func setAsideIfStray(
    legacy: URL, current: URL, requiredFile: String, fileManager: FileManager = .default,
    now: Date = .now
  ) -> URL? {
    guard entryKind(legacy.path) == .directory, entryKind(current.path) == .directory,
      fileManager.fileExists(atPath: legacy.appending(path: requiredFile).path),
      !fileManager.fileExists(atPath: current.appending(path: requiredFile).path)
    else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let aside = current.deletingLastPathComponent().appending(
      path: "\(current.lastPathComponent) set aside \(formatter.string(from: now))",
      directoryHint: .isDirectory)
    return renameExclusive(from: current.path, to: aside.path) == nil ? aside : nil
  }

  private enum EntryKind { case missing, directory, symlink, other }

  private static func entryKind(_ path: String) -> EntryKind {
    var info = stat()
    guard lstat(path, &info) == 0 else { return .missing }
    switch info.st_mode & S_IFMT {
    case S_IFLNK: return .symlink
    case S_IFDIR: return .directory
    default: return .other
    }
  }

  /// Uses a relative target when both live in the same folder so the link survives the parent
  /// folder being moved or viewed through another mount.
  private static func linkLegacy(_ legacy: URL, to current: URL, fileManager: FileManager) -> Bool {
    let sameParent =
      legacy.deletingLastPathComponent().standardizedFileURL.path
      == current.deletingLastPathComponent().standardizedFileURL.path
    let destination = sameParent ? current.lastPathComponent : current.path
    do {
      try fileManager.createSymbolicLink(atPath: legacy.path, withDestinationPath: destination)
      return true
    } catch {
      return false
    }
  }

  /// Atomic rename that fails instead of replacing an existing destination.
  private static func renameExclusive(from source: String, to destination: String) -> String? {
    #if canImport(Darwin)
      if renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 { return nil }
      return String(cString: strerror(errno))
    #else
      // Linux: link-free fallback. The destination was checked missing just before; rename(2)
      // would only replace an *empty* directory created in the meantime, never user data.
      if access(destination, F_OK) == 0 { return "destination appeared during migration" }
      if rename(source, destination) == 0 { return nil }
      return String(cString: strerror(errno))
    #endif
  }
}

/// The app-level folders that moved from `Muse` to `Otto`, resolved against an injectable home
/// so tests run in a temporary directory.
public struct OttoLegacyDirectories: Sendable {
  public struct Pair: Equatable, Sendable {
    public var name: String
    public var legacy: URL
    public var current: URL
  }

  public var pairs: [Pair]

  public init(pairs: [Pair]) { self.pairs = pairs }

  /// `Library/Application Support`, `Library/Logs` and `Library/Caches` under `home`.
  public static func library(home: URL) -> OttoLegacyDirectories {
    let library = home.appending(path: "Library", directoryHint: .isDirectory)
    let pairs = ["Application Support", "Logs", "Caches"].map { parent in
      let folder = library.appending(path: parent, directoryHint: .isDirectory)
      return Pair(
        name: parent,
        legacy: folder.appending(
          path: OttoNames.legacyApplicationSupportFolder, directoryHint: .isDirectory),
        current: folder.appending(
          path: OttoNames.applicationSupportFolder, directoryHint: .isDirectory))
    }
    return OttoLegacyDirectories(pairs: pairs)
  }

  public func migrate(fileManager: FileManager = .default) -> [(
    Pair, OttoDirectoryMigration.Outcome
  )] {
    pairs.map {
      (
        $0,
        OttoDirectoryMigration.migrate(
          legacy: $0.legacy, current: $0.current, fileManager: fileManager)
      )
    }
  }
}

/// Workspace-internal folders: `<workspace>/.muse` → `.otto` and `<repo>/.muse-worktrees` →
/// `.otto-worktrees`. Cheap enough (a few `lstat` calls) to run every time a workspace opens.
public enum OttoWorkspaceMigration {
  @discardableResult
  public static func migrateStateFolder(
    workspacePath: String, fileManager: FileManager = .default
  ) -> OttoDirectoryMigration.Outcome {
    let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
    let legacy = root.appending(path: OttoNames.legacyWorkspaceStateFolder)
    let current = root.appending(path: OttoNames.workspaceStateFolder)
    let outcome = OttoDirectoryMigration.migrate(
      legacy: legacy, current: current, fileManager: fileManager)
    guard outcome == .bothExist else { return outcome }
    guard
      (try? fileManager.attributesOfItem(atPath: legacy.path)[.type]) as? FileAttributeType
        == .typeDirectory,
      (try? fileManager.attributesOfItem(atPath: current.path)[.type]) as? FileAttributeType
        == .typeDirectory
    else { return outcome }
    // Chat attachments or a first new run can create .otto before migration. Recover missing
    // state (including office's hidden-session bindings) without replacing newer Otto data.
    // Run only once: later deletions must not resurrect old files from the preserved .muse copy.
    let marker = current.appending(path: ".otto-legacy-files-imported")
    guard !fileManager.fileExists(atPath: marker.path) else { return .alreadyMigrated }
    do {
      // Large generated assets retain their original .muse paths. Do not hydrate old
      // cloud-backed screenshots or copy runtime sockets while recovering workspace state.
      try copyMissingFiles(
        from: legacy, to: current, fileManager: fileManager,
        excluding: [
          "captures", "chat-attachments", "bootstrap", "tmp", "snapshots",
          "mobile-host", "mobile-host-dev",
        ])
      try Data("Imported missing legacy workspace files\n".utf8).write(to: marker, options: .atomic)
      return .mergedMissing
    } catch {
      return .failed("could not import legacy workspace files: \(error.localizedDescription)")
    }
  }

  private static func copyMissingFiles(
    from source: URL, to destination: URL, fileManager: FileManager, excluding: Set<String> = []
  ) throws {
    // Never traverse symlinks: neither folder may redirect migration outside the workspace.
    let sourceType =
      try fileManager.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
    let destinationType =
      try fileManager.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
    guard sourceType == .typeDirectory, destinationType == .typeDirectory else { return }
    for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
      guard !excluding.contains(item.lastPathComponent) else { continue }
      let type = try fileManager.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
      guard type == .typeDirectory || type == .typeRegular else { continue }
      let target = destination.appending(path: item.lastPathComponent)
      if (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
        if type == .typeDirectory {
          try copyMissingFiles(from: item, to: target, fileManager: fileManager)
        }
      } else {
        if type == .typeDirectory {
          try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
          try copyMissingFiles(from: item, to: target, fileManager: fileManager)
        } else {
          #if canImport(Darwin)
            // Foundation attempts APFS cloning, which can stall on file-provider captures.
            // Copy bytes and metadata exclusively, never replacing a concurrently created file.
            guard
              copyfile(item.path, target.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL))
                == 0
            else {
              throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
          #else
            try fileManager.copyItem(at: item, to: target)
          #endif
        }
      }
    }
  }

  @discardableResult
  public static func migrateWorktreesFolder(
    repositoryPath: String, fileManager: FileManager = .default
  ) -> OttoDirectoryMigration.Outcome {
    let root = URL(fileURLWithPath: repositoryPath, isDirectory: true)
    return OttoDirectoryMigration.migrate(
      legacy: root.appending(
        path: OttoNames.legacyAgentWorktreesFolder, directoryHint: .isDirectory),
      current: root.appending(path: OttoNames.agentWorktreesFolder, directoryHint: .isDirectory),
      fileManager: fileManager)
  }
}

/// Copies preferences from the pre-rename defaults domain into Otto's, once.
///
/// Keys are renamed on the way (`muse.` → `otto.`, `Muse…` → `Otto…`). A key that already has a
/// value in the new domain is never overwritten, and the legacy domain is never modified.
public enum LegacyDefaultsImporter {
  public static let markerKey = "otto.migration.legacyDefaultsImported"

  public struct Report: Equatable, Sendable {
    public var importedKeys: [String]
    public var skippedKeys: [String]
    public var alreadyImported: Bool

    public var importedAnything: Bool { !importedKeys.isEmpty }
  }

  /// The Otto name for a pre-rename defaults key.
  public static func mappedKey(_ key: String) -> String {
    if key.hasPrefix("muse.") { return "otto." + key.dropFirst("muse.".count) }
    if key.hasPrefix("Muse"), let next = key.dropFirst(4).first, next.isUppercase {
      return "Otto" + key.dropFirst(4)
    }
    return key
  }

  @discardableResult
  public static func importValues(
    _ legacyValues: [String: Any], into defaults: UserDefaults
  ) -> Report {
    if defaults.bool(forKey: markerKey) {
      return Report(importedKeys: [], skippedKeys: [], alreadyImported: true)
    }
    var imported: [String] = []
    var skipped: [String] = []
    for key in legacyValues.keys.sorted() {
      guard let value = legacyValues[key] else { continue }
      let target = mappedKey(key)
      if defaults.object(forKey: target) != nil {
        skipped.append(key)
        continue
      }
      defaults.set(value, forKey: target)
      imported.append(key)
    }
    defaults.set(true, forKey: markerKey)
    return Report(importedKeys: imported, skippedKeys: skipped, alreadyImported: false)
  }

  /// Reads every value the current user has in `domain` (for example `app.muse.desktop`).
  public static func legacyValues(domain: String) -> [String: Any] {
    #if canImport(Darwin)
      guard
        let keys = CFPreferencesCopyKeyList(
          domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
        !keys.isEmpty,
        let values = CFPreferencesCopyMultiple(
          keys as CFArray, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
          as? [String: Any]
      else { return [:] }
      return values
    #else
      return [:]
    #endif
  }
}

/// A one-time "Otto is the new name for Muse" notice, shown only to people whose data was
/// carried over from a Muse install.
public enum OttoRenameNotice {
  public static let pendingKey = "otto.migration.renameNoticePending"

  public static func markPending(in defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: pendingKey)
  }

  public static func isPending(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: pendingKey)
  }

  public static func dismiss(in defaults: UserDefaults = .standard) {
    defaults.set(false, forKey: pendingKey)
  }
}

/// Runs the launch-time rename migration before any store opens and reports what it did.
public struct OttoLaunchMigration {
  public var home: URL
  public var defaults: UserDefaults
  public var bundleIdentifier: String?
  public var legacyDefaults: (String) -> [String: Any]
  public var fileManager: FileManager

  public init(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    defaults: UserDefaults = .standard,
    bundleIdentifier: String? = Bundle.main.bundleIdentifier,
    legacyDefaults: @escaping (String) -> [String: Any] = LegacyDefaultsImporter.legacyValues,
    fileManager: FileManager = .default
  ) {
    self.home = home
    self.defaults = defaults
    self.bundleIdentifier = bundleIdentifier
    self.legacyDefaults = legacyDefaults
    self.fileManager = fileManager
  }

  public struct Report: Sendable {
    public var lines: [String]
    public var migratedFromMuse: Bool

    public init(lines: [String], migratedFromMuse: Bool) {
      self.lines = lines
      self.migratedFromMuse = migratedFromMuse
    }
  }

  @discardableResult
  public func run() -> Report {
    var lines: [String] = []
    var migrated = false
    let library = OttoLegacyDirectories.library(home: home)
    if let support = library.pairs.first(where: { $0.name == "Application Support" }),
      let aside = OttoDirectoryMigration.setAsideIfStray(
        legacy: support.legacy, current: support.current, requiredFile: "workspace.sqlite",
        fileManager: fileManager)
    {
      lines.append(
        "Application Support: \(support.current.path) had no workspace database; moved it to "
          + "\(aside.path) so the Muse data can move in")
    }
    for (pair, outcome) in library.migrate(fileManager: fileManager) {
      migrated = migrated || outcome.migratedData
      switch outcome {
      case .nothingToMigrate, .alreadyMigrated: continue
      case .bothExist:
        lines.append(
          "\(pair.name): both \(pair.legacy.path) and \(pair.current.path) exist; left both "
            + "untouched and using \(pair.current.lastPathComponent)")
      default:
        lines.append("\(pair.name): \(outcome) (\(pair.legacy.path) → \(pair.current.path))")
      }
    }
    if let legacyDomain = OttoNames.legacyBundleIdentifier(for: bundleIdentifier),
      !defaults.bool(forKey: LegacyDefaultsImporter.markerKey)
    {
      let report = LegacyDefaultsImporter.importValues(
        legacyDefaults(legacyDomain), into: defaults)
      if report.importedAnything {
        migrated = true
        lines.append(
          "Defaults: imported \(report.importedKeys.count) keys from \(legacyDomain)"
            + (report.skippedKeys.isEmpty
              ? "" : ", kept \(report.skippedKeys.count) already set in Otto"))
      }
    }
    if migrated { OttoRenameNotice.markPending(in: defaults) }
    return Report(lines: lines, migratedFromMuse: migrated)
  }

  /// Appends the report to `~/Library/Logs/Otto/migration.log`. Silent when nothing happened.
  public func writeLog(_ report: Report) {
    guard !report.lines.isEmpty else { return }
    let directory = home.appending(path: "Library/Logs/Otto", directoryHint: .isDirectory)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "migration.log")
    let stamp = ISO8601DateFormatter().string(from: .now)
    let text = report.lines.map { "\(stamp) \($0)\n" }.joined()
    if let handle = try? FileHandle(forWritingTo: file) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(text.utf8))
    } else {
      try? Data(text.utf8).write(to: file)
    }
  }
}

/// Protocol, crypto and hosting names that keep their pre-rename spelling on purpose. Deployed
/// phone apps, the PrivateSignIn worker, the relay and every installed Muse/Otto updater depend
/// on these exact bytes.
///
/// Legacy wire name, do not change without a protocol version bump.
public enum OttoLegacyWire {
  // Legacy wire name, do not change without a protocol version bump.
  public static let privateInputLabel = "muse-private-input-v1"
  // Legacy wire name, do not change without a protocol version bump.
  public static let privateInputHPKEInfo = "muse-private-input-hpke-auth-v1"
  // Legacy wire name, do not change without a protocol version bump.
  public static let phoneHostSignatureLabel = "muse-phone-host-v1"

  // Legacy wire name, do not change without a protocol version bump.
  public static let deviceIDHeader = "X-Muse-Device-ID"
  // Legacy wire name, do not change without a protocol version bump.
  public static let timeHeader = "X-Muse-Time"
  // Legacy wire name, do not change without a protocol version bump.
  public static let nonceHeader = "X-Muse-Nonce"
  // Legacy wire name, do not change without a protocol version bump.
  public static let keyHeader = "X-Muse-Key"
  // Legacy wire name, do not change without a protocol version bump.
  public static let signatureHeader = "X-Muse-Signature"
  // Legacy wire name, do not change without a protocol version bump.
  public static let timestampHeader = "X-Muse-Timestamp"

  /// Signed update feed every installed Muse (0.1.59 and earlier) and Otto build polls.
  // Legacy wire name, do not change without a protocol version bump.
  public static let updateFeedURL = "https://maxtrigify.github.io/muse-releases/"
  /// Ed25519 release-signing key identifier embedded in shipped updaters.
  // Legacy wire name, do not change without a protocol version bump.
  public static let releaseSigningKeyID = "muse-2026-1"
  /// Deployed PrivateSignIn worker (`muse-private-sign-in`).
  // Legacy wire name, do not change without a protocol version bump.
  public static let privateSignInURL = "https://muse-private-sign-in.muse-private.workers.dev"
}

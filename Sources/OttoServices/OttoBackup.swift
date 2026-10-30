import Foundation

/// Saves and restores a person's Otto setup: bots, connector choices, routines and settings.
///
/// A `.ottobackup` file is a zip holding `manifest.json`, `workspace/<files>` and
/// `settings.plist`. It never carries secrets: passwords and tokens stay in the Keychain, and
/// any file that looks like it holds one is left out. Restoring is staged, then applied on the
/// next launch before any store opens, so the running app cannot write its old state over the
/// restored files.
public enum OttoBackup {
  public static let format = "otto-backup"
  public static let version = 1
  public static let fileExtension = "ottobackup"

  /// Setup files under `<workspace>/.otto/`. Sessions, memory, activity, audit logs, caches and
  /// app sign-ins are deliberately absent. `user.md` is personal memory (a space's own, or the
  /// fallback), so it stays out too.
  public static let workspaceFiles = [
    "agent-profiles.json", "bot-appearance.json", "bot-notes.json", "bot-connections.json",
    "bot-skill-drafts.json", "bot-voices.json", "connector-access.json", "smtp.json",
    "agent-commands.json", "routines.json", "playbooks.json", "home-cards.json", "charter.md",
  ]
  public static let avatarFolder = "bot-avatars"
  static let avatarExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp"]
  static let maxFileBytes = 20_000_000
  /// Limits checked against the archive's own listing before anything is unpacked.
  static let maxArchiveBytes = 200_000_000
  static let maxArchiveEntries = 2_000
  /// Text that only appears in credentials; a file or setting containing any of it is never
  /// backed up. Key-value forms, JSON keys with a string value, and the prefixes of common API
  /// keys and private keys.
  static let secretPatterns: [NSRegularExpression] = [
    #"(?i)bearer\s"#,
    #"(?i)(password|passwd|api_?key|secret|access_token|refresh_token)\s*="#,
    #"(?i)"[a-z0-9_-]*(password|passwd|secret|token|api_?key)"\s*:\s*"[^"]"#,
    #"(?i)\b(sk-ant-|sk-proj-|sk_live_|rk_live_|xox[bpa]-|ghp_|github_pat_)"#,
    #"\bsk-[A-Za-z0-9_-]{20,}"#,
    #"\bAKIA[0-9A-Z]{16}"#,
    #"\bAIza[0-9A-Za-z_-]{30,}"#,
    #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
  ].map { try! NSRegularExpression(pattern: $0) }
  /// Preferences that describe a moment rather than a setup, identify this install, or decide
  /// what bots may do and where they connect. Permission modes and remote endpoints are never
  /// carried over, so a backup cannot raise what bots may do on another Mac.
  static let excludedSettingPrefixes = [
    "otto.browser.", "otto.chatBrowserNodeID", "otto.composerDraft", "otto.documents.open",
    "otto.feedback.installID", "otto.migration.", "otto.telegram.", "otto.settings.selectedPage",
    "otto.assistant.target", "otto.backup.", "otto.emailDraft.", "otto.agents.permissions.",
    "otto.agents.hermes.", "otto.boat.",
  ]
  /// Words that mark a preference as a credential anywhere in its key.
  static let excludedSettingWords = [
    "acceptedterms", "secret", "password", "apikey", "api_key", "credential",
  ]
  public static let lastRestoreKey = "otto.backup.lastRestore"
  /// Bots and automations restored with any other permission mode get this one.
  static let restoredPermissionMode = "workspaceWrite"
  static let restorablePermissionModes: Set<String> = ["readOnly", "workspaceWrite"]

  public struct Manifest: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var createdAt: Date
    public var appVersion: String
    /// Paths relative to `.otto/`, avatars as `bot-avatars/<name>`.
    public var files: [String]
    public var settingsCount: Int
    /// Setup files left out of the backup because they look like they hold a secret.
    public var skippedFiles: [String]? = nil
  }

  /// What a backup holds and what restoring it changes on the way in, for the confirmation.
  public struct Preview: Equatable, Sendable {
    public var manifest: Manifest
    /// Plain sentences: bots whose permissions are lowered, automations that come back paused,
    /// and which bots each connector allows.
    public var notices: [String]
  }

  /// Changes made to the restored files so a backup cannot raise what bots may do.
  struct RestoreAdjustments: Equatable {
    var loweredBots: [String] = []
    var pausedRoutines = 0
    var connectorAccess: [String] = []

    var notices: [String] {
      var lines: [String] = []
      if !loweredBots.isEmpty {
        lines.append(
          "Bots set to bypass permissions come back with workspace access only: \(loweredBots.joined(separator: ", "))."
        )
      }
      if pausedRoutines > 0 {
        lines.append(
          "\(pausedRoutines) automation\(pausedRoutines == 1 ? " comes" : "s come") back paused; turn \(pausedRoutines == 1 ? "it" : "them") on in Automations."
        )
      }
      if !connectorAccess.isEmpty {
        lines.append(
          "Connector access is restored: \(connectorAccess.joined(separator: "; ")).")
      }
      return lines
    }
  }

  public enum BackupError: Error, LocalizedError, Equatable {
    case invalidArchive(String)
    case toolFailed(String)

    public var errorDescription: String? {
      switch self {
      case .invalidArchive(let detail): "This is not a usable Otto backup: \(detail)"
      case .toolFailed(let detail): "The backup file could not be processed: \(detail)"
      }
    }
  }

  /// Where staged restores and automatic backups live.
  public struct Locations: Sendable {
    public var supportDirectory: URL

    public init(supportDirectory: URL) {
      self.supportDirectory = supportDirectory
    }

    public static var live: Locations {
      Locations(
        supportDirectory: FileManager.default.urls(
          for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appending(path: "Otto", directoryHint: .isDirectory))
    }

    public var pendingRestore: URL { supportDirectory.appending(path: "PendingRestore") }
    public var backups: URL { supportDirectory.appending(path: "Backups") }
  }

  /// The validated contents of a backup laid out on disk: an extracted archive or a staged
  /// restore.
  struct Contents {
    var root: URL
    var manifest: Manifest
    var files: [String]
    var settings: [String: Any]
  }

  // MARK: Export

  @discardableResult
  public static func export(
    workspacePath: String, defaults: UserDefaults, to destination: URL, appVersion: String,
    now: Date = .now
  ) throws -> Manifest {
    let fileManager = FileManager.default
    let staging = try temporaryDirectory("otto-backup-export")
    defer { try? fileManager.removeItem(at: staging) }
    let source = stateFolder(workspacePath)
    let workspace = staging.appending(path: "workspace")
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)

    var files: [String] = []
    var skipped: [String] = []
    for name in workspaceFiles {
      let url = source.appending(path: name)
      guard isRegularFile(url), let data = try? Data(contentsOf: url),
        data.count <= maxFileBytes
      else { continue }
      guard !looksSecret(data) else {
        skipped.append(name)
        continue
      }
      try data.write(to: workspace.appending(path: name))
      files.append(name)
    }
    let avatars = source.appending(path: avatarFolder)
    if !isSymbolicLink(avatars) {
      for url
        in (try? fileManager.contentsOfDirectory(at: avatars, includingPropertiesForKeys: nil))
        ?? []
      where isAvatar(url) {
        let target = workspace.appending(path: avatarFolder)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.copyItem(at: url, to: target.appending(path: url.lastPathComponent))
        files.append("\(avatarFolder)/\(url.lastPathComponent)")
      }
    }

    let settings = settingsSnapshot(defaults)
    try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
      .write(to: staging.appending(path: "settings.plist"))
    // Whole seconds, as ISO 8601 stores them, so a manifest reads back exactly.
    let createdAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    let manifest = Manifest(
      format: format, version: version, createdAt: createdAt, appVersion: appVersion,
      files: files,
      settingsCount: settings.count, skippedFiles: skipped.isEmpty ? nil : skipped)
    try encoder.encode(manifest).write(to: staging.appending(path: "manifest.json"))

    try fileManager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = destination.deletingLastPathComponent()
      .appending(path: ".\(destination.lastPathComponent).partial")
    try? fileManager.removeItem(at: partial)
    try run(
      "/usr/bin/ditto",
      ["-c", "-k", "--norsrc", "--noextattr", "--noacl", staging.path, partial.path])
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: partial)
    } else {
      try fileManager.moveItem(at: partial, to: destination)
    }
    return manifest
  }

  /// Otto preferences worth carrying to another Mac, as plist-safe values.
  static func settingsSnapshot(_ defaults: UserDefaults) -> [String: Any] {
    defaults.dictionaryRepresentation().filter { key, value in
      isPortableSetting(key, value: value)
        && (try? PropertyListSerialization.data(
          fromPropertyList: [key: value], format: .binary, options: 0)) != nil
    }
  }

  static func isPortableSetting(_ key: String, value: Any? = nil) -> Bool {
    guard key.hasPrefix("otto.") else { return false }
    if excludedSettingPrefixes.contains(where: key.hasPrefix) { return false }
    let lowered = key.lowercased()
    if excludedSettingWords.contains(where: lowered.contains) { return false }
    // A segment ending in "token" is a credential; `maxTokens` and the like are not.
    if lowered.split(separator: ".").contains(where: { $0.hasSuffix("token") }) { return false }
    return value.map { !valueLooksSecret($0) } ?? true
  }

  /// True when any text inside a preference value looks like a credential.
  static func valueLooksSecret(_ value: Any) -> Bool {
    switch value {
    case let text as String: looksSecret(text)
    case let data as Data: looksSecret(data)
    case let array as [Any]: array.contains(where: valueLooksSecret)
    case let dictionary as [String: Any]:
      dictionary.contains { looksSecret($0.key) || valueLooksSecret($0.value) }
    default: false
    }
  }

  // MARK: Inspect and stage

  /// Reads and validates a backup without changing anything.
  public static func inspect(_ archive: URL) throws -> Manifest {
    try preview(archive).manifest
  }

  /// Reads and validates a backup, and describes what restoring it would change on the way in.
  public static func preview(_ archive: URL) throws -> Preview {
    let extracted = try extract(archive)
    defer { try? FileManager.default.removeItem(at: extracted) }
    let contents = try validatedContents(at: extracted)
    var adjustments = RestoreAdjustments()
    for file in contents.files {
      _ = adjustedForRestore(
        file, try Data(contentsOf: contents.root.appending(path: "workspace/\(file)")),
        contents: contents, into: &adjustments)
    }
    return Preview(manifest: contents.manifest, notices: adjustments.notices)
  }

  /// Validates a backup and stages it to be applied, to `workspacePath`, on the next launch.
  @discardableResult
  public static func stageRestore(
    from archive: URL, workspacePath: String, locations: Locations
  ) throws -> Manifest {
    let fileManager = FileManager.default
    let extracted = try extract(archive)
    defer { try? fileManager.removeItem(at: extracted) }
    let contents = try validatedContents(at: extracted)

    let staged = try temporaryDirectory("otto-backup-stage")
    defer { try? fileManager.removeItem(at: staged) }
    try write(contents, to: staged)
    try encoder.encode(["workspacePath": workspacePath])
      .write(to: staged.appending(path: "target.json"))

    try fileManager.createDirectory(
      at: locations.supportDirectory, withIntermediateDirectories: true)
    try? fileManager.removeItem(at: locations.pendingRestore)
    try fileManager.moveItem(at: staged, to: locations.pendingRestore)
    return contents.manifest
  }

  /// Writes validated contents in the backup layout: only the files that passed validation.
  private static func write(_ contents: Contents, to directory: URL) throws {
    let fileManager = FileManager.default
    let workspace = directory.appending(path: "workspace")
    try fileManager.createDirectory(
      at: workspace.appending(path: avatarFolder), withIntermediateDirectories: true)
    for file in contents.files {
      try fileManager.copyItem(
        at: contents.root.appending(path: "workspace/\(file)"),
        to: workspace.appending(path: file))
    }
    var manifest = contents.manifest
    manifest.files = contents.files
    manifest.settingsCount = contents.settings.count
    try encoder.encode(manifest).write(to: directory.appending(path: "manifest.json"))
    try PropertyListSerialization.data(
      fromPropertyList: contents.settings, format: .xml, options: 0
    ).write(to: directory.appending(path: "settings.plist"))
  }

  // MARK: Apply

  /// Applies a staged restore, if there is one, and returns what happened. Call before any
  /// store opens. The current setup is saved first; if that fails nothing is changed.
  @discardableResult
  public static func applyPendingRestore(
    defaults: UserDefaults, locations: Locations, appVersion: String, now: Date = .now
  ) -> String? {
    let fileManager = FileManager.default
    let pending = locations.pendingRestore
    guard fileManager.fileExists(atPath: pending.path) else { return nil }
    defer { try? fileManager.removeItem(at: pending) }

    let message: String
    do {
      guard
        let target = try? JSONDecoder().decode(
          [String: String].self, from: Data(contentsOf: pending.appending(path: "target.json"))),
        let workspacePath = target["workspacePath"]
      else { throw BackupError.invalidArchive("the staged restore has no target") }
      let contents = try validatedContents(at: pending)

      let safety = locations.backups.appending(
        path: "Before restore \(fileStamp(now)).\(fileExtension)")
      try export(
        workspacePath: workspacePath, defaults: defaults, to: safety, appVersion: appVersion,
        now: now)

      let state = stateFolder(workspacePath)
      try fileManager.createDirectory(
        at: state.appending(path: avatarFolder), withIntermediateDirectories: true)
      var adjustments = RestoreAdjustments()
      var incoming: [(file: URL, data: Data)] = []
      for file in contents.files {
        let data = try Data(contentsOf: pending.appending(path: "workspace/\(file)"))
        incoming.append(
          (
            state.appending(path: file),
            adjustedForRestore(file, data, contents: contents, into: &adjustments)
          ))
      }
      try replaceAll(incoming)
      for (key, value) in contents.settings { defaults.set(value, forKey: key) }
      message =
        ([
          "Restored \(contents.files.count) files and \(contents.settings.count) settings from the backup made \(contents.manifest.createdAt.formatted(date: .abbreviated, time: .shortened))."
        ]
        + adjustments.notices
        + ["Your previous setup was saved as “\(safety.lastPathComponent)”."])
        .joined(separator: " ")
    } catch {
      message = "The backup was not restored: \(error.localizedDescription)"
    }
    defaults.set(message, forKey: lastRestoreKey)
    return message
  }

  /// Writes every incoming file beside its destination first, then swaps them in. A failure
  /// while writing (a full disk, say) leaves the current setup untouched; only the swaps, which
  /// are renames, run after the first file changes.
  private static func replaceAll(_ files: [(file: URL, data: Data)]) throws {
    let fileManager = FileManager.default
    let staged = files.map { destination, data in
      (
        destination,
        destination.deletingLastPathComponent()
          .appending(path: ".\(destination.lastPathComponent).restoring"), data
      )
    }
    do {
      for (_, incoming, data) in staged {
        try? fileManager.removeItem(at: incoming)
        try data.write(to: incoming)
      }
    } catch {
      for (_, incoming, _) in staged { try? fileManager.removeItem(at: incoming) }
      throw error
    }
    for (destination, incoming, _) in staged {
      if fileManager.fileExists(atPath: destination.path) || isSymbolicLink(destination) {
        _ = try fileManager.replaceItemAt(destination, withItemAt: incoming)
      } else {
        try fileManager.moveItem(at: incoming, to: destination)
      }
    }
  }

  // MARK: Restore policy

  /// Returns a restored file's data with anything that would raise what bots may do taken out:
  /// bot and automation permission modes beyond workspace access are lowered, and automations
  /// come back paused. Connector access is restored as saved and listed, since leaving it out
  /// would open Gmail, Mobile and iMessage to every bot again.
  static func adjustedForRestore(
    _ file: String, _ data: Data, contents: Contents, into adjustments: inout RestoreAdjustments
  ) -> Data {
    guard file.hasSuffix(".json"),
      var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return data }
    var changed = false
    switch file {
    case "agent-profiles.json":
      guard var profiles = root["profiles"] as? [[String: Any]] else { return data }
      for index in profiles.indices where lowerPermissionMode(&profiles[index]) {
        adjustments.loweredBots.append(profiles[index]["name"] as? String ?? "Unnamed bot")
        changed = true
      }
      root["profiles"] = profiles
    case "routines.json":
      guard var routines = root["routines"] as? [[String: Any]] else { return data }
      for index in routines.indices {
        if lowerPermissionMode(&routines[index]) { changed = true }
        if routines[index]["enabled"] as? Bool == true {
          routines[index]["enabled"] = false
          adjustments.pausedRoutines += 1
          changed = true
        }
      }
      root["routines"] = routines
    case "connector-access.json":
      let names = botNames(contents)
      for (raw, ids) in (root["grants"] as? [String: [String]] ?? [:]).sorted(by: {
        $0.key < $1.key
      }) {
        let title = ConnectorKind(rawValue: raw)?.title ?? raw
        let bots = ids.map { names[$0.uppercased()] ?? "a bot not in this backup" }
        adjustments.connectorAccess.append(
          "\(title): \(bots.isEmpty ? "no bots" : bots.joined(separator: ", "))")
      }
    default:
      break
    }
    guard changed else { return data }
    return
      (try? JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
      ?? data
  }

  /// Sets a permission mode beyond workspace access back to workspace access. A missing or null
  /// mode is left alone: it inherits, and what it inherits from is lowered too.
  private static func lowerPermissionMode(_ record: inout [String: Any]) -> Bool {
    guard let mode = record["permissionMode"], !(mode is NSNull) else { return false }
    if let mode = mode as? String, restorablePermissionModes.contains(mode) { return false }
    record["permissionMode"] = restoredPermissionMode
    return true
  }

  /// Bot names by upper-cased id, from the backup's own profiles.
  private static func botNames(_ contents: Contents) -> [String: String] {
    guard contents.files.contains("agent-profiles.json"),
      let data = try? Data(
        contentsOf: contents.root.appending(path: "workspace/agent-profiles.json")),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let profiles = root["profiles"] as? [[String: Any]]
    else { return [:] }
    var names: [String: String] = [:]
    for profile in profiles {
      if let id = profile["id"] as? String, let name = profile["name"] as? String {
        names[id.uppercased()] = name
      }
    }
    return names
  }

  // MARK: Validation

  /// Reads a backup laid out on disk. Only allowlisted paths are read; symbolic links, files
  /// over the size limit and unreadable JSON make the whole backup invalid. Files that look
  /// like they hold secrets, and settings outside the portable set, are dropped.
  static func validatedContents(at root: URL) throws -> Contents {
    let fileManager = FileManager.default
    let manifestURL = root.appending(path: "manifest.json")
    guard isRegularFile(manifestURL), let data = try? Data(contentsOf: manifestURL),
      let manifest = try? decoder.decode(Manifest.self, from: data)
    else { throw BackupError.invalidArchive("it has no readable manifest") }
    guard manifest.format == format else {
      throw BackupError.invalidArchive("it was not made by Otto")
    }
    guard manifest.version <= version else {
      throw BackupError.invalidArchive("it was made by a newer version of Otto")
    }

    let workspace = root.appending(path: "workspace")
    guard !isSymbolicLink(workspace) else {
      throw BackupError.invalidArchive("it contains a link")
    }
    var files: [String] = []
    for name in workspaceFiles {
      let url = workspace.appending(path: name)
      guard try checkedFile(url) else { continue }
      let data = try Data(contentsOf: url)
      if name.hasSuffix(".json"), (try? JSONSerialization.jsonObject(with: data)) == nil {
        throw BackupError.invalidArchive("\(name) is not valid JSON")
      }
      if !looksSecret(data) { files.append(name) }
    }
    let avatars = workspace.appending(path: avatarFolder)
    guard !isSymbolicLink(avatars) else { throw BackupError.invalidArchive("it contains a link") }
    for url in (try? fileManager.contentsOfDirectory(at: avatars, includingPropertiesForKeys: nil))
      ?? []
    {
      guard !isSymbolicLink(url) else { throw BackupError.invalidArchive("it contains a link") }
      guard isAvatar(url) else { continue }
      files.append("\(avatarFolder)/\(url.lastPathComponent)")
    }

    var settings: [String: Any] = [:]
    let settingsURL = root.appending(path: "settings.plist")
    if try checkedFile(settingsURL) {
      guard
        let plist = try? PropertyListSerialization.propertyList(
          from: Data(contentsOf: settingsURL), format: nil) as? [String: Any]
      else { throw BackupError.invalidArchive("its settings are unreadable") }
      settings = plist.filter { isPortableSetting($0.key, value: $0.value) }
    }
    return Contents(root: root, manifest: manifest, files: files, settings: settings)
  }

  /// True for a regular file within the size limit, false when absent; throws for a link,
  /// a folder in a file's place, or an oversized file.
  private static func checkedFile(_ url: URL) throws -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return false
    }
    switch attributes[.type] as? FileAttributeType {
    case .typeRegular?:
      guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxFileBytes else {
        throw BackupError.invalidArchive("\(url.lastPathComponent) is too large")
      }
      return true
    case .typeSymbolicLink?:
      throw BackupError.invalidArchive("it contains a link")
    default:
      throw BackupError.invalidArchive("\(url.lastPathComponent) is not a file")
    }
  }

  // MARK: Archive handling

  /// Extracts a backup into a fresh temporary folder after checking no entry could land
  /// outside it.
  static func extract(_ archive: URL) throws -> URL {
    let listing = try run("/usr/bin/zipinfo", ["-1", archive.path])
    let entries = listing.split(whereSeparator: \.isNewline)
    // Sizes come from the archive's directory, so an archive that unpacks to far more than any
    // setup could be is refused before ditto writes a byte.
    let totals = try run("/usr/bin/zipinfo", ["-t", archive.path])
    guard entries.count <= maxArchiveEntries,
      let unpacked = uncompressedBytes(totals), unpacked <= maxArchiveBytes
    else { throw BackupError.invalidArchive("it is too large") }
    for entry in entries {
      let components = entry.split(separator: "/", omittingEmptySubsequences: false)
      guard !entry.hasPrefix("/"), !components.contains("..") else {
        throw BackupError.invalidArchive("it contains an unsafe path")
      }
    }
    let directory = try temporaryDirectory("otto-backup-read")
    do {
      try run("/usr/bin/ditto", ["-x", "-k", "--norsrc", archive.path, directory.path])
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    return directory
  }

  @discardableResult
  private static func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail = String(decoding: errorData.prefix(300), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw BackupError.toolFailed(detail.isEmpty ? "status \(process.terminationStatus)" : detail)
    }
    return String(decoding: outputData, as: UTF8.self)
  }

  // MARK: Helpers

  static func stateFolder(_ workspacePath: String) -> URL {
    URL(fileURLWithPath: workspacePath).appending(path: ".otto", directoryHint: .isDirectory)
  }

  /// Reads the total from `zipinfo -t`, such as "6 files, 494 bytes uncompressed, …".
  static func uncompressedBytes(_ totals: String) -> Int? {
    let words = totals.split(whereSeparator: \.isWhitespace)
    guard let index = words.firstIndex(of: "uncompressed,"), index >= 2,
      words[index - 1] == "bytes"
    else { return nil }
    return Int(words[index - 2])
  }

  static func looksSecret(_ data: Data) -> Bool {
    looksSecret(String(decoding: data, as: UTF8.self))
  }

  static func looksSecret(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return secretPatterns.contains { $0.firstMatch(in: text, range: range) != nil }
  }

  private static func isAvatar(_ url: URL) -> Bool {
    avatarExtensions.contains(url.pathExtension.lowercased()) && isRegularFile(url)
      && ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
        .intValue ?? 0) <= maxFileBytes
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
      == .typeRegular
  }

  private static func isSymbolicLink(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
      == .typeSymbolicLink
  }

  private static func temporaryDirectory(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }

  /// A file-name-safe local timestamp, such as 2026-10-29 at 16.05.12.
  public static func fileStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter.string(from: date)
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

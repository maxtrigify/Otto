import Foundation
import OttoModels

/// Watches sources only in Otto Dev. Keeping the monitor in the foreground application means
/// protected-folder access is attributed to Otto Dev instead of an anonymous LaunchAgent.
@MainActor
enum DevelopmentAutoReloader {
  private static var monitorTask: Task<Void, Never>?

  static func startIfNeeded() {
    guard monitorTask == nil,
      Bundle.main.bundleIdentifier == OttoNames.developmentBundleIdentifier,
      Bundle.main.object(forInfoDictionaryKey: "OttoDevelopmentAutoReload") as? Bool == true,
      let repositoryPath = Bundle.main.object(
        forInfoDictionaryKey: "OttoDevelopmentRepositoryPath") as? String
    else { return }

    let root = URL(fileURLWithPath: repositoryPath, isDirectory: true)
      .standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path)
    else { return }

    let scratchPath =
      Bundle.main.object(
        forInfoDictionaryKey: "OttoDevelopmentScratchPath") as? String
    let monitor = DevelopmentSourceMonitor(repositoryRoot: root, scratchPath: scratchPath)
    monitorTask = Task { await monitor.run() }
  }
}

private actor DevelopmentSourceMonitor {
  private struct FileStamp: Equatable {
    let path: String
    let modifiedAt: TimeInterval
    let size: UInt64
  }

  private let repositoryRoot: URL
  private let scratchPath: String?
  private let logURL: URL

  init(repositoryRoot: URL, scratchPath: String?) {
    self.repositoryRoot = repositoryRoot
    self.scratchPath = scratchPath
    let logs =
      FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
      .appending(path: "Logs/Otto", directoryHint: .isDirectory)
      ?? FileManager.default.temporaryDirectory.appending(
        path: "Otto/Logs", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    logURL = logs.appending(path: "dev-reloader.log")
  }

  func run() async {
    guard var previous = fingerprint() else {
      appendLog("Otto Dev cannot read the configured source workspace.")
      return
    }
    appendLog("Watching \(repositoryRoot.path) from Otto Dev.")

    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1))
      guard let current = fingerprint(), current != previous else { continue }
      previous = current
      try? await Task.sleep(for: .milliseconds(900))
      if let settled = fingerprint() { previous = settled }
      appendLog("Source change detected; rebuilding Otto Dev.")
      let status = await rebuildAndRelaunch()
      if status != 0 {
        appendLog("Reload failed with exit status \(status); waiting for the next source change.")
      }
    }
  }

  private func fingerprint() -> [FileStamp]? {
    let fileManager = FileManager.default
    let watched = ["Sources", "Tests", "packaging", "scripts", "Package.swift"]
    var stamps: [FileStamp] = []

    for relativePath in watched {
      let url = repositoryRoot.appending(path: relativePath)
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
      if !isDirectory.boolValue {
        if let stamp = stamp(for: url) { stamps.append(stamp) }
        continue
      }
      guard
        let enumerator = fileManager.enumerator(
          at: url,
          includingPropertiesForKeys: [
            .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
          ],
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else { return nil }
      for case let fileURL as URL in enumerator where isWatchedFile(fileURL) {
        if let stamp = stamp(for: fileURL) { stamps.append(stamp) }
      }
    }
    return stamps.sorted { $0.path < $1.path }
  }

  private func isWatchedFile(_ url: URL) -> Bool {
    ["swift", "plist", "entitlements", "sh"].contains(url.pathExtension)
      || url.lastPathComponent == "Package.swift"
  }

  private func stamp(for url: URL) -> FileStamp? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .contentModificationDateKey, .fileSizeKey,
      ]), values.isRegularFile == true
    else { return nil }
    return FileStamp(
      path: url.path,
      modifiedAt: values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
      size: UInt64(max(0, values.fileSize ?? 0))
    )
  }

  private func rebuildAndRelaunch() async -> Int32 {
    let rootPath = repositoryRoot.path
    let scriptPath = repositoryRoot.appending(path: "scripts/dev-app.sh").path
    let logPath = logURL.path
    let scratchPath = scratchPath
    return await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [scriptPath, "reload"]
      var environment = ProcessInfo.processInfo.environment
      // The installed app is already stamped with the canonical integration checkout. Keep the
      // distinction explicit so a worker's inherited OTTO_DEV_REPOSITORY_PATH cannot repoint the
      // one shared Otto Dev.app at an isolated clone.
      environment["OTTO_DEV_CANONICAL_REPOSITORY_PATH"] = rootPath
      if let scratchPath {
        environment["OTTO_DEV_SCRATCH_PATH"] = scratchPath
      }
      process.environment = environment
      process.currentDirectoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)

      _ = FileManager.default.createFile(atPath: logPath, contents: nil)
      let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
      _ = try? log?.seekToEnd()
      process.standardOutput = log
      process.standardError = log
      defer { try? log?.close() }
      do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
      } catch {
        return 127
      }
    }.value
  }

  private func appendLog(_ message: String) {
    let line = "[\(Date().formatted(.iso8601))] \(message)\n"
    if !FileManager.default.fileExists(atPath: logURL.path) {
      _ = FileManager.default.createFile(atPath: logURL.path, contents: Data())
    }
    guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}

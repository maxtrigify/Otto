import AppKit
import Foundation
import OttoModels

/// Where Otto.app should live and what an update (or the one-time rename) retires.
///
/// Muse 0.1.59 and earlier update by replacing their own bundle path, so the first Otto build
/// they install lands at `/Applications/Muse.app`. Otto then moves itself to `Otto.app` beside
/// it: once at launch, and again on every update for as long as it still runs from the old name.
struct AppInstallPlan: Equatable {
  /// The bundle that is running now.
  var current: URL
  /// Where the updated (or renamed) app ends up.
  var target: URL
  /// The old bundle to move to the Trash after a successful swap, when it is not `target`.
  var retired: URL?
}

enum AppInstallLocation {
  static let appName = "Otto.app"
  static let legacyAppName = "Muse.app"
  static let relocationAttemptedKey = "otto.migration.relocationAttempted"

  /// Bundle identifiers whose app Otto may replace at `Otto.app`.
  static let replaceableIdentifiers: Set<String> = [
    OttoNames.releaseBundleIdentifier, OttoNames.legacyReleaseBundleIdentifier,
  ]

  static func plan(
    currentBundle: URL,
    fileManager: FileManager = .default,
    bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
  ) -> AppInstallPlan {
    let current = currentBundle.standardizedFileURL
    guard current.lastPathComponent == legacyAppName else {
      return AppInstallPlan(current: current, target: current, retired: nil)
    }
    let renamed = current.deletingLastPathComponent().appending(
      path: appName, directoryHint: .isDirectory)
    if fileManager.fileExists(atPath: renamed.path) {
      // Never overwrite an unrelated app that happens to be called Otto.
      guard let identifier = bundleIdentifier(renamed),
        replaceableIdentifiers.contains(identifier)
      else {
        return AppInstallPlan(current: current, target: current, retired: nil)
      }
    }
    return AppInstallPlan(current: current, target: renamed, retired: current)
  }

  /// The one-time launch rename: only for the release bundle running as `Muse.app`, only when
  /// `Otto.app` is free, the folder is writable, and it has not been tried before.
  static func launchRelocation(
    currentBundle: URL,
    bundleIdentifier: String?,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) -> AppInstallPlan? {
    guard bundleIdentifier == OttoNames.releaseBundleIdentifier,
      !defaults.bool(forKey: relocationAttemptedKey),
      !currentBundle.path.contains("/AppTranslocation/"),
      fileManager.isWritableFile(atPath: currentBundle.deletingLastPathComponent().path)
    else { return nil }
    let plan = plan(currentBundle: currentBundle, fileManager: fileManager)
    guard plan.target != plan.current, !fileManager.fileExists(atPath: plan.target.path) else {
      return nil
    }
    return plan
  }

  /// Renames the running `Muse.app` to `Otto.app` after this process exits, then reopens it.
  /// A plain rename in the same folder: if it fails, the original app is reopened unchanged.
  @MainActor
  static func relocateAndRelaunch(_ plan: AppInstallPlan, defaults: UserDefaults = .standard)
    throws
  {
    defaults.set(true, forKey: relocationAttemptedKey)
    // The app quits a moment later. If this flag were lost and the rename failed, the reopened
    // Muse.app would try again on every launch.
    defaults.synchronize()
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-relocate-\(UUID().uuidString).sh")
    try relocationHelperScript.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
      scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), plan.current.path,
      plan.target.path,
    ]
    try helper.run()
    UpdateRelaunchRequest.shared.begin()
    NSApplication.shared.terminate(nil)
  }

  static let relocationHelperScript = """
    #!/bin/sh
    PID="$1"; FROM="$2"; TO="$3"
    WAITED=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
      /bin/sleep 0.2
      WAITED=$((WAITED + 1))
      if [ "$WAITED" -eq 40 ]; then /bin/kill -TERM "$PID" 2>/dev/null || true; fi
      if [ "$WAITED" -eq 60 ]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi
    done
    if [ ! -e "$TO" ] && /bin/mv -n "$FROM" "$TO" && [ -d "$TO" ] && [ ! -e "$FROM" ]; then
      /usr/bin/open "$TO"
    else
      /usr/bin/open "$FROM"
    fi
    """
}

import AppKit
import Foundation
import OttoCommercial
import OttoModels
import SwiftUI

/// Checks the public release feed for newer builds, surfaces the changelog, and performs the
/// verified download → swap → relaunch cycle. The feed is a statically hosted signed manifest;
/// only releases signed by an embedded Otto release key and matching the manifest's exact
/// SHA-256 and byte count are ever installed.
@MainActor
final class AppUpdateController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case checking
    case upToDate
    case downloading(progress: Double)
    case preparing
    case restarting
    case failed(String)
  }

  @Published var availableRelease: UpdateRelease?
  @Published var isPresentingUpdateSheet = false
  @Published var phase: Phase = .idle

  /// Public landing page shown when in-place install is not possible.
  static let downloadPageURL = URL(string: OttoLegacyWire.updateFeedURL)!

  private static let defaultFeedBaseURL = URL(string: OttoLegacyWire.updateFeedURL)!
  private static let trustedPublicKeys: [String: Data] = [
    OttoLegacyWire.releaseSigningKeyID: Data(
      base64Encoded: "yf0EYlEAlBCEF5spXmxgAraJ1RqgQdfBk7HipdGu4o0=")!
  ]
  private static let skippedVersionKey = "OttoUpdateSkippedVersion"
  private static let rolloutBucketKey = "OttoUpdateRolloutBucket"
  /// Keep an already-running copy informed without making users relaunch to discover a release.
  /// The feed is a small static document, so a five-minute cadence is intentionally inexpensive.
  private static let checkInterval: Duration = .seconds(5 * 60)
  private static let minimumActivationCheckInterval: TimeInterval = 60

  private var checkLoopTask: Task<Void, Never>?
  private var lastAutomaticCheckAt: Date?
  private var automaticallyPresentedVersions: Set<String> = []

  deinit {
    checkLoopTask?.cancel()
  }

  /// Automatic checks run only for the production bundle so development builds (which carry
  /// placeholder versions and reload from source) never offer downgrades. A feed override makes
  /// the whole pipeline testable from any bundle.
  var isEnabled: Bool {
    if feedOverrideURL != nil { return true }
    return Bundle.main.bundleIdentifier == OttoNames.releaseBundleIdentifier
  }

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  private var currentBuild: Int {
    Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
  }

  private var feedOverrideURL: URL? {
    guard let raw = OttoEnvironment.value("UPDATE_FEED_URL"), !raw.isEmpty
    else { return nil }
    return URL(string: raw)
  }

  private var feedBaseURL: URL { feedOverrideURL ?? Self.defaultFeedBaseURL }

  func startAutomaticChecks() {
    guard isEnabled, checkLoopTask == nil else { return }
    checkLoopTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check(userInitiated: false)
        try? await Task.sleep(for: Self.checkInterval)
      }
    }
  }

  /// App activation is another opportunity to discover a release published while Otto was in
  /// the background. Closely repeated activations are coalesced with the periodic check.
  func checkAfterActivation(now: Date = .now) {
    guard Self.shouldCheckAfterActivation(lastCheckAt: lastAutomaticCheckAt, now: now) else {
      return
    }
    Task { await check(userInitiated: false) }
  }

  static func shouldCheckAfterActivation(lastCheckAt: Date?, now: Date) -> Bool {
    guard let lastCheckAt else { return true }
    return now.timeIntervalSince(lastCheckAt) >= minimumActivationCheckInterval
  }

  func checkNow() {
    Task { await check(userInitiated: true) }
  }

  func check(userInitiated: Bool) async {
    guard isEnabled || userInitiated else { return }
    guard !phase.isBusy else { return }
    if !userInitiated { lastAutomaticCheckAt = .now }
    phase = .checking
    do {
      let client = try CommercialClient(baseURL: feedBaseURL)
      let manager = UpdateManager(
        client: client,
        verifier: SignedDocumentVerifier(publicKeys: Self.trustedPublicKeys)
      )
      let os = ProcessInfo.processInfo.operatingSystemVersion
      let release = try await manager.availableRelease(
        channel: .stable,
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        rolloutBucket: rolloutBucket()
      )
      if let release {
        availableRelease = release
        phase = .idle
        let skipped = UserDefaults.standard.string(forKey: Self.skippedVersionKey)
        let isFirstAutomaticPresentation = automaticallyPresentedVersions.insert(
          release.version
        ).inserted
        if userInitiated || (release.version != skipped && isFirstAutomaticPresentation) {
          isPresentingUpdateSheet = true
        }
      } else {
        availableRelease = nil
        phase = .upToDate
        if userInitiated { isPresentingUpdateSheet = true }
      }
    } catch {
      phase = .failed(error.localizedDescription)
      if userInitiated { isPresentingUpdateSheet = true }
    }
  }

  func skipAvailableVersion() {
    guard let release = availableRelease else { return }
    UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
    isPresentingUpdateSheet = false
  }

  func downloadAndInstall() {
    guard let release = availableRelease, !phase.isBusy else { return }
    Task { await performInstall(of: release) }
  }

  private func rolloutBucket() -> Int {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.rolloutBucketKey) != nil {
      let stored = defaults.integer(forKey: Self.rolloutBucketKey)
      if (0..<100).contains(stored) { return stored }
    }
    let bucket = Int.random(in: 0..<100)
    defaults.set(bucket, forKey: Self.rolloutBucketKey)
    return bucket
  }

  private func performInstall(of release: UpdateRelease) async {
    phase = .downloading(progress: 0)
    do {
      let staged = try await downloadAndStage(release)
      phase = .restarting
      try relaunchReplacing(with: staged)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Downloads the artifact, verifies it byte-for-byte against the signed manifest, and expands
  /// it in a private staging directory. Returns the staged `.app` bundle URL.
  private func downloadAndStage(_ release: UpdateRelease) async throws -> URL {
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    let archive = staging.appendingPathComponent("Otto.zip")
    try await UpdateDownloader.download(
      from: release.artifactURL,
      to: archive,
      expectedByteCount: release.byteCount
    ) { [weak self] progress in
      Task { @MainActor [weak self] in
        guard case .downloading = self?.phase else { return }
        self?.phase = .downloading(progress: progress)
      }
    }
    phase = .preparing
    try UpdateArtifactVerifier.verify(fileURL: archive, release: release)

    let expanded = staging.appendingPathComponent("expanded", isDirectory: true)
    try runProcess("/usr/bin/ditto", ["-xk", archive.path, expanded.path])

    let contents = try FileManager.default.contentsOfDirectory(
      at: expanded, includingPropertiesForKeys: nil)
    guard let application = contents.first(where: { $0.pathExtension == "app" }) else {
      throw AppUpdateError.artifactMissingApplication
    }
    return application
  }

  /// Hands the swap to a detached helper that waits for this process to exit, replaces the
  /// installed bundle with the staged one, and relaunches. Translocated or read-only installs
  /// fall back to the download page instead of failing mid-swap.
  ///
  /// A copy still running as `Muse.app` (installed there by a pre-rename updater) is updated
  /// into `Otto.app` beside it; the old bundle goes to the Trash only after the new one is in
  /// place.
  private func relaunchReplacing(with staged: URL) throws {
    let plan = AppInstallLocation.plan(currentBundle: Bundle.main.bundleURL)
    let target = plan.target
    let parent = target.deletingLastPathComponent()
    guard !plan.current.path.contains("/AppTranslocation/"),
      FileManager.default.isWritableFile(atPath: parent.path)
    else {
      NSWorkspace.shared.open(Self.downloadPageURL)
      throw AppUpdateError.cannotReplaceInstalledApplication
    }

    let script = Self.relaunchHelperScript
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("otto-relaunch-\(UUID().uuidString).sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
      scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path,
      plan.retired?.path ?? "",
    ]
    try helper.run()
    UpdateRelaunchRequest.shared.begin()
    NSApplication.shared.terminate(nil)
  }

  /// Normal termination stops supervised processes first. This detached fallback prevents a
  /// wedged child process from leaving Download & Restart waiting forever.
  ///
  /// The new bundle is copied next to the target first and swapped in with renames, so a failed
  /// copy (full disk, permissions) leaves the installed app untouched and reopens it. `RETIRE`
  /// is the old `Muse.app` when the update also renames the app; it is moved to the Trash only
  /// after `TARGET` holds the new version.
  nonisolated static let relaunchHelperScript = """
    #!/bin/sh
    PID="$1"; STAGED="$2"; TARGET="$3"; RETIRE="$4"
    WAITED=0
    while /bin/kill -0 "$PID" 2>/dev/null; do
      /bin/sleep 0.2
      WAITED=$((WAITED + 1))
      if [ "$WAITED" -eq 40 ]; then /bin/kill -TERM "$PID" 2>/dev/null || true; fi
      if [ "$WAITED" -eq 60 ]; then /bin/kill -KILL "$PID" 2>/dev/null || true; fi
    done
    reopen() {
      if [ -n "$RETIRE" ] && [ -e "$RETIRE" ]; then /usr/bin/open "$RETIRE"
      elif [ -e "$TARGET" ]; then /usr/bin/open "$TARGET"; fi
    }
    PARENT=$(/usr/bin/dirname "$TARGET")
    NEXT="$PARENT/.otto-update-$$.app"
    PREVIOUS="$PARENT/.otto-previous-$$.app"
    /bin/rm -rf "$NEXT" "$PREVIOUS"
    if ! /usr/bin/ditto "$STAGED" "$NEXT"; then
      /bin/rm -rf "$NEXT"; reopen; exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$NEXT" 2>/dev/null
    if [ -e "$TARGET" ] && ! /bin/mv "$TARGET" "$PREVIOUS"; then
      /bin/rm -rf "$NEXT"; reopen; exit 1
    fi
    if ! /bin/mv "$NEXT" "$TARGET"; then
      [ -e "$PREVIOUS" ] && /bin/mv "$PREVIOUS" "$TARGET"
      /bin/rm -rf "$NEXT"; reopen; exit 1
    fi
    /bin/rm -rf "$PREVIOUS"
    if [ -n "$RETIRE" ] && [ "$RETIRE" != "$TARGET" ] && [ -e "$RETIRE" ]; then
      /bin/mkdir -p "$HOME/.Trash"
      /bin/mv "$RETIRE" "$HOME/.Trash/Muse $(/bin/date +%Y%m%d%H%M%S).app" 2>/dev/null || true
    fi
    /usr/bin/open "$TARGET"
    """

  private func runProcess(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw AppUpdateError.processFailed(command: path, status: process.terminationStatus)
    }
  }
}

extension AppUpdateController.Phase {
  fileprivate var isBusy: Bool {
    switch self {
    case .checking, .downloading, .preparing, .restarting:
      true
    case .idle, .upToDate, .failed:
      false
    }
  }
}

/// A download delegate gives the update sheet real byte progress and applies bounded network
/// timeouts. URLSession's convenience download API exposes neither, which made a healthy 40 MB
/// transfer and a genuinely stalled transfer look identical.
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  typealias ProgressHandler = @Sendable (Double) -> Void

  private let destination: URL
  private let expectedByteCount: Int64
  private let progressHandler: ProgressHandler
  private var continuation: CheckedContinuation<Void, Error>?
  private var session: URLSession?
  private var completed = false

  private init(
    destination: URL,
    expectedByteCount: Int64,
    progressHandler: @escaping ProgressHandler
  ) {
    self.destination = destination
    self.expectedByteCount = expectedByteCount
    self.progressHandler = progressHandler
  }

  static func download(
    from source: URL,
    to destination: URL,
    expectedByteCount: Int64,
    progressHandler: @escaping ProgressHandler
  ) async throws {
    let delegate = UpdateDownloader(
      destination: destination,
      expectedByteCount: expectedByteCount,
      progressHandler: progressHandler
    )
    try await delegate.start(source)
  }

  private func start(_ source: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 10 * 60
      configuration.waitsForConnectivity = false
      let queue = OperationQueue()
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      self.session = session
      session.downloadTask(with: source).resume()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let total = expectedByteCount > 0 ? expectedByteCount : totalBytesExpectedToWrite
    guard total > 0 else { return }
    progressHandler(min(max(Double(totalBytesWritten) / Double(total), 0), 1))
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      finish(with: .success(()))
    } catch {
      finish(with: .failure(error))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error { finish(with: .failure(error)) }
  }

  private func finish(with result: Result<Void, Error>) {
    guard !completed else { return }
    completed = true
    let continuation = continuation
    self.continuation = nil
    session?.finishTasksAndInvalidate()
    session = nil
    continuation?.resume(with: result)
  }
}

/// Lets the application delegate distinguish an explicit update restart from an ordinary quit.
/// Update restarts must stop resumable processes automatically rather than placing a quit alert
/// behind the update sheet and leaving the detached installer waiting forever.
@MainActor
final class UpdateRelaunchRequest {
  static let shared = UpdateRelaunchRequest()

  private(set) var isActive = false

  init() {}

  func begin() {
    isActive = true
  }
}

enum AppUpdateError: Error, LocalizedError {
  case artifactMissingApplication
  case cannotReplaceInstalledApplication
  case processFailed(command: String, status: Int32)

  var errorDescription: String? {
    switch self {
    case .artifactMissingApplication:
      "The downloaded update did not contain an application bundle."
    case .cannotReplaceInstalledApplication:
      "This copy of Otto cannot update itself in place. Download the latest version manually."
    case .processFailed(let command, let status):
      "\(command) exited with status \(status)."
    }
  }
}

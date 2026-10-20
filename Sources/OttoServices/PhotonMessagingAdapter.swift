import Foundation

@MainActor
public protocol MessagingProviderAdapter: AnyObject {
  var onEvent: ((Data) -> Void)? { get set }
  func connect(accountID: String, secret: String) throws
  func send(_ job: MessagingJob) throws
  func disconnect()
  func signal(_ action: String, binding: MessagingBinding, eventID: String?) throws
}

extension MessagingProviderAdapter {
  public func signal(_ action: String, binding: MessagingBinding, eventID: String? = nil) throws {}
}

/// The child process is owned by the application and communicates on private pipes only.
/// No credentials in argv, environment, a shell, or SDK log files.
@MainActor
public final class PhotonMessagingAdapter: MessagingProviderAdapter {
  public var onEvent: ((Data) -> Void)?
  private var process: Process?
  private var input: FileHandle?
  private var output: FileHandle?
  private var buffer = Data()
  public static var directory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Otto/PhotonBridge-12.8.0")
  }
  public init() {}

  private static var installer: Process?
  public static func cancelInstallation() {
    if installer?.isRunning == true { installer?.terminate() }
  }
  public static func install() async throws {
    guard installer == nil else { throw MessagingError.runtimeMissing }
    let directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard let source = bundledBridge else {
      throw MessagingError.runtimeMissing
    }
    for name in ["bridge.mjs", "package.json", "package-lock.json"] {
      try Data(contentsOf: source.appending(path: name)).write(
        to: directory.appending(path: name), options: .atomic)
    }
    let process = Process()
    installer = process
    defer { installer = nil }
    let deadline = Task {
      try? await Task.sleep(for: .seconds(180))
      guard !Task.isCancelled else { return }
      if process.isRunning { process.terminate() }
    }
    defer { deadline.cancel() }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
    process.environment = runtimeEnvironment
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      process.terminationHandler = { process in
        if process.terminationStatus == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: MessagingError.runtimeMissing)
        }
      }
      do { try process.run() } catch {
        continuation.resume(throwing: MessagingError.runtimeMissing)
      }
    }
  }

  static func packagedBridge(in appURL: URL) -> URL? {
    // Newer toolchains package resource bundles with their own Contents/Resources folder.
    let bundle = appURL.appending(path: "Contents/Resources/Otto_OttoServices.bundle")
    return [
      bundle.appending(path: "Contents/Resources/PhotonBridge"),
      bundle.appending(path: "PhotonBridge"),
    ].first { FileManager.default.fileExists(atPath: $0.appending(path: "bridge.mjs").path) }
  }

  private static var bundledBridge: URL? {
    if let packaged = packagedBridge(in: Bundle.main.bundleURL) { return packaged }
    // A missing packaged resource must return a setup error, not trap inside Bundle.module.
    guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
    return Bundle.module.url(forResource: "PhotonBridge", withExtension: nil)
  }

  private static var runtimeEnvironment: [String: String] {
    // Explicit minimum environment avoids inheriting unrelated credentials into the SDK.
    [
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "LOG_LEVEL": "silent", "DO_NOT_TRACK": "1",
    ]
  }

  public func connect(accountID: String, secret: String) throws {
    disconnect()
    let script = Self.directory.appending(path: "bridge.mjs")
    guard FileManager.default.fileExists(atPath: script.path),
      FileManager.default.fileExists(
        atPath: Self.directory.appending(path: "node_modules/spectrum-ts").path)
    else { throw MessagingError.runtimeMissing }
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", script.path]
    process.environment = Self.runtimeEnvironment
    process.currentDirectoryURL = Self.directory
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let identity = UUID()
    generation = identity
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task { @MainActor [weak self] in
        guard let self, self.generation == identity else { return }
        self.consume(data)
      }
    }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor [weak self] in
        guard self?.generation == identity else { return }
        self?.onEvent?(Data("{\"kind\":\"offline\"}".utf8))
      }
    }
    self.process = process
    input = stdin.fileHandleForWriting
    output = stdout.fileHandleForReading
    try process.run()
    try write(["kind": "connect", "accountID": accountID, "secret": secret])
  }
  private var generation = UUID()
  public func send(_ job: MessagingJob) throws {
    guard let conversation = job.binding.conversation, let text = job.reply else {
      throw MessagingError.invalidConfiguration
    }
    try write([
      "kind": "send", "id": job.id.uuidString, "conversation": conversation,
      "destination": job.binding.destination, "text": text,
    ])
  }
  public func signal(_ action: String, binding: MessagingBinding, eventID: String? = nil) throws {
    guard let conversation = binding.conversation else { return }
    var command = [
      "kind": "signal", "action": action, "conversation": conversation,
      "destination": binding.destination,
    ]
    if let eventID { command["eventID"] = eventID }
    try write(command)
  }
  public func disconnect() {
    generation = UUID()
    output?.readabilityHandler = nil
    try? input?.close()
    if process?.isRunning == true { process?.terminate() }
    input = nil
    output = nil
    process = nil
    buffer.removeAll()
  }
  private func write(_ value: [String: String]) throws {
    guard process?.isRunning == true, let input else { throw MessagingError.providerUnavailable }
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10)
    try input.write(contentsOf: data)
  }
  private func consume(_ data: Data) {
    guard !data.isEmpty else { return }
    buffer.append(data)
    guard buffer.count <= 1_048_576 else {
      disconnect()
      onEvent?(Data("{\"kind\":\"offline\"}".utf8))
      return
    }
    while let end = buffer.firstIndex(of: 10) {
      let line = Data(buffer[..<end])
      buffer.removeSubrange(...end)
      onEvent?(line)
    }
  }
}

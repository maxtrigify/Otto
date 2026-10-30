import CryptoKit
import Foundation

public enum WhistleInstallationState: Sendable, Equatable {
  case notInstalled
  case downloadingEngine
  case downloadingModel
  case verifying
  case installing
  case installed
  case failed(String)

  public var detail: String {
    switch self {
    case .notInstalled: "Not installed"
    case .downloadingEngine: "Downloading the 1.1 MB engine…"
    case .downloadingModel: "Downloading the 17 MB model…"
    case .verifying: "Verifying official downloads…"
    case .installing: "Installing locally…"
    case .installed: "Whistle is ready"
    case .failed(let message): message
    }
  }

  public var isBusy: Bool {
    switch self {
    case .downloadingEngine, .downloadingModel, .verifying, .installing: true
    default: false
    }
  }
}

public enum WhistleInstallerError: Error, LocalizedError {
  case termsNotAccepted
  case size(name: String, expected: Int, actual: Int)
  case checksum(name: String)
  case invalidInstallation(String)

  public var errorDescription: String? {
    switch self {
    case .termsNotAccepted: "Agree to Whistle's license terms before downloading it."
    case .size(let name, let expected, let actual):
      "The downloaded \(name) is \(actual) bytes; \(expected) were expected"
    case .checksum(let name): "The downloaded \(name) failed its checksum"
    case .invalidInstallation(let detail): detail
    }
  }
}

/// The terms a person agrees to before Otto downloads Whistle, shown in Voice Settings. Agreement
/// is stored against the pinned files, so a later revision asks again.
public enum WhistleTerms {
  public static let revision = "whistle@741118687e1f needle3@d6c7d6a2e965"
  public static let author = "Cactus Compute, Inc."
  public static let license = "Apache License 2.0"
  public static let licenseURL = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
  public static let modelPage = URL(string: "https://huggingface.co/Cactus-Compute/whistle")!
  public static let enginePage = URL(string: "https://huggingface.co/Cactus-Compute/needle3")!
  public static let downloadSize = "18 MB"
  public static let acceptedKey = "otto.voice.whistle.acceptedTerms"

  public static func isAccepted(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.string(forKey: acceptedKey) == revision
  }

  public static func accept(_ defaults: UserDefaults = .standard) {
    defaults.set(revision, forKey: acceptedKey)
  }

  public static func withdraw(_ defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: acceptedKey)
  }
}

/// One pinned download: an exact Hugging Face revision, its size and its sha256.
struct WhistleArtifact: Sendable {
  var name: String
  var url: URL
  var size: Int
  var sha256: String
  var relativePath: String
  var executable: Bool
}

/// Downloads Cactus Compute's `needle` engine and Whistle weights, both Apache-2.0, at pinned
/// revisions into Application Support. Nothing runs until both files match their pinned size
/// and sha256; an existing installation is replaced only after the new one validates.
public actor WhistleInstaller {
  public nonisolated let updates: AsyncStream<WhistleInstallationState>
  private let continuation: AsyncStream<WhistleInstallationState>.Continuation
  private let fileManager: FileManager
  private let installRoot: URL
  private let termsAccepted: @Sendable () -> Bool
  private let download: @Sendable (URL) async throws -> URL

  static let engine = WhistleArtifact(
    name: "engine",
    url: URL(
      string:
        "https://huggingface.co/Cactus-Compute/needle3/resolve/d6c7d6a2e9655505e0f8e23339356dd1705900eb/macos-arm64/needle"
    )!,
    size: 1_107_096,
    sha256: "0a480f7e01d1fcf9df2e6dbc29af29411406720a5c5cb73024fcd6d16aa25b60",
    relativePath: "engine/needle",
    executable: true)

  static let model = WhistleArtifact(
    name: "model",
    url: URL(
      string:
        "https://huggingface.co/Cactus-Compute/whistle/resolve/741118687e1f008f06d1351a402a731274789790/whistle.cact"
    )!,
    size: 16_919_407,
    sha256: "b6e02f048568ac5d01a2042556c658061e699acbc0aa2a1439f52f3d461dffeb",
    relativePath: "model/whistle.cact",
    executable: false)

  public init(
    fileManager: FileManager = .default,
    installRoot: URL = WhistleRuntimeConfiguration.defaultRoot,
    termsAccepted: @escaping @Sendable () -> Bool = { WhistleTerms.isAccepted() },
    download: @escaping @Sendable (URL) async throws -> URL = { url in
      try await URLSession.shared.download(from: url).0
    }
  ) {
    self.fileManager = fileManager
    self.installRoot = installRoot
    self.termsAccepted = termsAccepted
    self.download = download
    var continuation: AsyncStream<WhistleInstallationState>.Continuation!
    updates = AsyncStream { continuation = $0 }
    self.continuation = continuation
    continuation.yield(
      WhistleRuntimeConfiguration(root: installRoot).validationError(fileManager: fileManager)
        == nil ? .installed : .notInstalled)
  }

  public func install() async {
    let staging = fileManager.temporaryDirectory
      .appending(path: "otto-whistle-install-\(UUID().uuidString)")
    do {
      guard termsAccepted() else { throw WhistleInstallerError.termsNotAccepted }
      let candidate = staging.appending(path: "Whistle")
      try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
      for (artifact, state) in [
        (Self.engine, WhistleInstallationState.downloadingEngine), (Self.model, .downloadingModel),
      ] {
        continuation.yield(state)
        let downloaded = try await download(artifact.url)
        continuation.yield(.verifying)
        try verify(downloaded, as: artifact)
        let destination = candidate.appending(path: artifact.relativePath)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: downloaded, to: destination)
        try? fileManager.removeItem(at: downloaded)
        if artifact.executable {
          try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
      }
      continuation.yield(.installing)
      try Data(Self.notice.utf8).write(to: candidate.appending(path: "NOTICE.md"))
      if let error = WhistleRuntimeConfiguration(root: candidate).validationError(
        fileManager: fileManager)
      {
        throw WhistleInstallerError.invalidInstallation(error)
      }
      try replaceInstallation(with: candidate)
      try? fileManager.removeItem(at: staging)
      continuation.yield(.installed)
    } catch {
      try? fileManager.removeItem(at: staging)
      continuation.yield(.failed(error.localizedDescription))
    }
  }

  /// Removes the downloaded engine and model. Agreement to the terms is kept separately.
  public func remove() async {
    try? fileManager.removeItem(at: installRoot)
    continuation.yield(.notInstalled)
  }

  func verify(_ file: URL, as artifact: WhistleArtifact) throws {
    let size = (try fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
    guard size == artifact.size else {
      throw WhistleInstallerError.size(
        name: artifact.name, expected: artifact.size, actual: size ?? -1)
    }
    guard try sha256(of: file) == artifact.sha256 else {
      throw WhistleInstallerError.checksum(name: artifact.name)
    }
  }

  private func replaceInstallation(with candidate: URL) throws {
    let parent = installRoot.deletingLastPathComponent()
    let backup = parent.appending(path: installRoot.lastPathComponent + ".previous")
    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
    if fileManager.fileExists(atPath: installRoot.path) {
      try fileManager.moveItem(at: installRoot, to: backup)
    }
    do {
      try fileManager.moveItem(at: candidate, to: installRoot)
      if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
    } catch {
      if fileManager.fileExists(atPath: backup.path) {
        try? fileManager.moveItem(at: backup, to: installRoot)
      }
      throw error
    }
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static let notice = """
    # Whistle speech recognition

    Downloaded by Otto from the authors' own repositories after the user agreed to the terms.

    - Whistle weights (`model/whistle.cact`): \(WhistleTerms.modelPage.absoluteString), revision
      741118687e1f008f06d1351a402a731274789790, sha256 \(model.sha256).
    - needle engine (`engine/needle`, macOS arm64): \(WhistleTerms.enginePage.absoluteString),
      revision d6c7d6a2e9655505e0f8e23339356dd1705900eb, sha256 \(engine.sha256).

    Both are © \(WhistleTerms.author) and licensed under the \(WhistleTerms.license):
    \(WhistleTerms.licenseURL.absoluteString)
    """
}

import CryptoKit
import Foundation

public enum ParakeetInstallationState: Sendable, Equatable {
  case notInstalled
  case downloadingRuntime
  case downloadingModel
  case verifying
  case installing
  case installed
  case failed(String)

  public var detail: String {
    switch self {
    case .notInstalled: "Not installed"
    case .downloadingRuntime: "Downloading the 23 MB runtime…"
    case .downloadingModel: "Downloading the 467 MB model…"
    case .verifying: "Verifying official downloads…"
    case .installing: "Installing locally…"
    case .installed: "Parakeet is ready"
    case .failed(let message): message
    }
  }

  public var isBusy: Bool {
    switch self {
    case .downloadingRuntime, .downloadingModel, .verifying, .installing: true
    default: false
    }
  }
}

public enum ParakeetInstallerError: Error, LocalizedError {
  case checksum(name: String)
  case archive(String)
  case invalidInstallation(String)

  public var errorDescription: String? {
    switch self {
    case .checksum(let name): "The downloaded \(name) failed its checksum"
    case .archive(let detail): "Could not extract Parakeet: \(detail)"
    case .invalidInstallation(let detail): detail
    }
  }
}

/// Downloads pinned official sherpa-onnx and Parakeet artifacts into Application Support. All
/// extraction happens in a staging directory; an existing installation is replaced only after
/// the new one validates successfully.
public actor ParakeetInstaller {
  public nonisolated let updates: AsyncStream<ParakeetInstallationState>
  private let continuation: AsyncStream<ParakeetInstallationState>.Continuation
  private let fileManager: FileManager

  private static let runtimeURL = URL(
    string:
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.2/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts.tar.bz2"
  )!
  private static let modelURL = URL(
    string:
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
  )!
  private static let runtimeSHA256 =
    "d880aaa79d36b784168a0398b278813d57ba8e135f468894b8f134b664e2e225"
  private static let modelSHA256 =
    "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    var continuation: AsyncStream<ParakeetInstallationState>.Continuation!
    updates = AsyncStream { continuation = $0 }
    self.continuation = continuation
    continuation.yield(
      ParakeetRuntimeConfiguration.installed(fileManager: fileManager) == nil
        ? .notInstalled : .installed
    )
  }

  public func install() async {
    let staging = fileManager.temporaryDirectory
      .appending(path: "otto-parakeet-install-\(UUID().uuidString)")
    do {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
      continuation.yield(.downloadingRuntime)
      let (runtimeDownload, _) = try await URLSession.shared.download(from: Self.runtimeURL)
      let runtimeArchive = staging.appending(path: "runtime.tar.bz2")
      try fileManager.copyItem(at: runtimeDownload, to: runtimeArchive)

      continuation.yield(.downloadingModel)
      let (modelDownload, _) = try await URLSession.shared.download(from: Self.modelURL)
      let modelArchive = staging.appending(path: "model.tar.bz2")
      try fileManager.copyItem(at: modelDownload, to: modelArchive)

      continuation.yield(.verifying)
      guard try sha256(of: runtimeArchive) == Self.runtimeSHA256 else {
        throw ParakeetInstallerError.checksum(name: "runtime")
      }
      guard try sha256(of: modelArchive) == Self.modelSHA256 else {
        throw ParakeetInstallerError.checksum(name: "model")
      }

      continuation.yield(.installing)
      let extracted = staging.appending(path: "extracted")
      try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
      try await extract(runtimeArchive, into: extracted)
      try await extract(modelArchive, into: extracted)
      let runtimeSource = extracted.appending(
        path: "sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts")
      let modelSource = extracted.appending(
        path: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
      let candidate = staging.appending(path: "Parakeet")
      try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
      try fileManager.copyItem(at: runtimeSource, to: candidate.appending(path: "runtime"))
      try fileManager.copyItem(at: modelSource, to: candidate.appending(path: "model"))

      let configuration = ParakeetRuntimeConfiguration(
        executableURL: candidate.appending(path: "runtime/bin/sherpa-onnx-offline"),
        libraryDirectory: candidate.appending(path: "runtime/lib"),
        modelDirectory: candidate.appending(path: "model")
      )
      if let error = configuration.warmValidationError(fileManager: fileManager) {
        throw ParakeetInstallerError.invalidInstallation(error)
      }

      let parent = fileManager.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Otto/VoiceModels")
      let destination = parent.appending(path: "Parakeet")
      let backup = parent.appending(path: "Parakeet.previous")
      try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.moveItem(at: destination, to: backup)
      }
      do {
        try fileManager.moveItem(at: candidate, to: destination)
        if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
      } catch {
        if fileManager.fileExists(atPath: backup.path) {
          try? fileManager.moveItem(at: backup, to: destination)
        }
        throw error
      }
      try? fileManager.removeItem(at: staging)
      continuation.yield(.installed)
    } catch {
      try? fileManager.removeItem(at: staging)
      continuation.yield(.failed(error.localizedDescription))
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

  private func extract(_ archive: URL, into directory: URL) async throws {
    let process = Process()
    let error = Pipe()
    process.executableURL = URL(filePath: "/usr/bin/tar")
    process.arguments = ["-xjf", archive.path, "-C", directory.path]
    process.standardError = error
    try process.run()
    let errorTask = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
    await withCheckedContinuation { continuation in
      process.terminationHandler = { _ in continuation.resume() }
    }
    let errorData = await errorTask.value
    guard process.terminationStatus == 0 else {
      throw ParakeetInstallerError.archive(
        String(decoding: errorData.suffix(2_000), as: UTF8.self)
      )
    }
  }
}

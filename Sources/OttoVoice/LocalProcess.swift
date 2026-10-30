import AVFoundation
import Foundation

public enum LocalProcessError: Error, LocalizedError, Equatable {
  case timedOut(String)

  public var errorDescription: String? {
    switch self {
    case .timedOut(let name): "\(name) took too long and was stopped"
    }
  }
}

/// Runs one local helper (`afconvert`, `needle`, `sherpa-onnx-offline`) to completion without
/// blocking a thread. The helper is terminated when it outlives `timeout` or the calling task
/// is cancelled, so a stuck engine can never hang a transcription forever.
enum LocalProcess {
  struct Result: Sendable {
    var status: Int32
    var output: Data
    var errorText: String
  }

  static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
    timeout: Duration
  ) async throws -> Result {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    let exit = ExitSignal()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardOutput = output
    process.standardError = error
    // Set before launch: a helper that exits immediately must still be seen to exit.
    process.terminationHandler = { _ in exit.signal() }
    try process.run()
    let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
    let errorTask = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
    let watchdog = Task.detached {
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, exit.markTimedOut() else { return }
      process.terminate()
    }
    await withTaskCancellationHandler {
      await exit.wait()
    } onCancel: {
      process.terminate()
    }
    watchdog.cancel()
    let outputData = await outputTask.value
    let errorText = String(decoding: await errorTask.value.suffix(2_000), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try Task.checkCancellation()
    if exit.timedOut { throw LocalProcessError.timedOut(executable.lastPathComponent) }
    return Result(status: process.terminationStatus, output: outputData, errorText: errorText)
  }

  /// A generous limit for transcribing recordings: a minute to load the model plus twice the
  /// audio's length, capped at fifteen minutes. Unreadable audio gets the cap.
  static func transcriptionTimeout(for audioURLs: [URL]) -> Duration {
    let cap = 15.0 * 60
    var seconds = 0.0
    for url in audioURLs {
      guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
        return .seconds(cap)
      }
      seconds += Double(file.length) / file.fileFormat.sampleRate
    }
    return .seconds(min(cap, 60 + seconds * 2))
  }

  /// Converting even a 20 MB recording takes seconds; this only stops a wedged `afconvert`.
  static let conversionTimeout = Duration.seconds(120)
}

/// The helper's exit, observed once by `terminationHandler` and awaited by `run`.
private final class ExitSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var exited = false
  private var didTimeOut = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var timedOut: Bool { lock.withLock { didTimeOut } }

  func signal() {
    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      exited = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  /// True when the helper was still running, so the caller should stop it.
  func markTimedOut() -> Bool {
    lock.withLock {
      guard !exited else { return false }
      didTimeOut = true
      return true
    }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let done = lock.withLock { () -> Bool in
        if exited { return true }
        waiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }
}

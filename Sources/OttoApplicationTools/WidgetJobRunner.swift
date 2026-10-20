import Foundation
import OttoCore
import OttoDocuments
import OttoModels
import OttoRuntime
import OttoTools

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public enum WidgetJobError: LocalizedError, Equatable {
  case nodeNotFound(UUID)
  case missingDataConfiguration
  case alreadyRunning
  case scriptMissing(String)
  case scriptFailed(status: Int32, stderr: String)
  case timedOut(seconds: Int)
  case resourcePressure
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .nodeNotFound(let id):
      "No widget node \(id.uuidString) exists"
    case .missingDataConfiguration:
      "The widget does not declare the required data view or job"
    case .alreadyRunning:
      "The widget job is already running"
    case .scriptMissing(let path):
      "Widget script '\(path)' does not exist"
    case .scriptFailed(let status, let stderr):
      "Widget script exited \(status): \(stderr.isEmpty ? "no stderr output" : stderr)"
    case .timedOut(let seconds):
      "Widget script exceeded its \(seconds)s budget and was terminated"
    case .resourcePressure:
      "Widget jobs are paused while system memory or thermal pressure is critical"
    case .cancelled:
      "Widget job was cancelled and its process tree was terminated"
    }
  }
}

/// Executes a typed widget's data job — the package-owned script whose stdout is the payload
/// for the widget's declared view — then validates the output and persists the result into the
/// node's runtime state. One run per widget at a time; every run is appended to the package's
/// `runs.jsonl` history.
public actor WidgetJobRunner {
  public static let runLogRelativeName = "runs.jsonl"
  private static let runLogByteLimit = 65_536
  private static let stdoutByteLimit = WidgetPayload.maximumBytes + 1_024
  private static let stderrByteLimit = 16_384
  static let cpuTimeLimitSeconds = 10
  static let memoryLimitKilobytes = 262_144
  static let niceValue = 15

  private let store: CanvasStore
  private let documents: WorkspaceDocumentStore
  private let resourceScheduler: AgentResourceScheduler
  private var inFlight: Set<UUID> = []

  public init(
    store: CanvasStore,
    documents: WorkspaceDocumentStore,
    resourceScheduler: AgentResourceScheduler = AgentResourceScheduler(
      configuration: AgentResourceSchedulerConfiguration(
        nominalLimit: 1, elevatedLimit: 1, criticalLimit: 1))
  ) {
    self.store = store
    self.documents = documents
    self.resourceScheduler = resourceScheduler
  }

  /// Runs the widget's data job once and returns the updated runtime state. Failures are
  /// recorded into the node state (so the canvas shows them) before being rethrown.
  @discardableResult
  public func run(nodeID: UUID) async throws -> WidgetRuntimeState {
    guard !inFlight.contains(nodeID) else { throw WidgetJobError.alreadyRunning }
    inFlight.insert(nodeID)
    defer { inFlight.remove(nodeID) }

    guard await resourceScheduler.snapshot().pressure != .critical else {
      throw WidgetJobError.resourcePressure
    }
    try await resourceScheduler.acquire(nodeID)
    do {
      guard await resourceScheduler.snapshot().pressure != .critical else {
        throw WidgetJobError.resourcePressure
      }
      let state = try await runAdmitted(nodeID: nodeID)
      await resourceScheduler.release(nodeID)
      return state
    } catch {
      await resourceScheduler.release(nodeID)
      throw error
    }
  }

  private func runAdmitted(nodeID: UUID) async throws -> WidgetRuntimeState {
    let located = try await locate(nodeID)
    let manifestText = try await documents.read(relativePath: "\(located.packagePath)/widget.json")
    let manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(manifestText.utf8))
    guard let job = manifest.job else {
      throw WidgetJobError.missingDataConfiguration
    }
    let scriptRelative = try Self.validatedScriptPath(job.script)
    let packageDirectory = URL(fileURLWithPath: documents.rootPath)
      .appending(path: located.packagePath).path
    let scriptAbsolute = URL(fileURLWithPath: packageDirectory).appending(path: scriptRelative)
      .path
    let startedAt = Date()

    do {
      let output = try await Self.execute(
        scriptPath: scriptAbsolute,
        workingDirectory: packageDirectory,
        timeoutSeconds: job.resolvedTimeoutSeconds
      )
      let payloadJSON = output.trimmingCharacters(in: .whitespacesAndNewlines)
      let typedPayload = try manifest.view.map {
        try WidgetPayload.parse(json: payloadJSON, kind: $0.kind)
      }
      if manifest.view == nil {
        _ = try validatedWidgetDataJSON(payloadJSON)
      }
      let state = try await persist(nodeID: nodeID) { state in
        if let view = manifest.view, let typedPayload {
          state.recordSuccess(
            payloadJSON: payloadJSON, payload: typedPayload, at: Date(),
            historyLimit: view.resolvedHistoryLimit)
        } else {
          state.recordHTMLSuccess(payloadJSON: payloadJSON, at: Date())
        }
      }
      await appendRunLog(
        packagePath: located.packagePath, startedAt: startedAt, success: true, message: "ok")
      return state
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      _ = try? await persist(nodeID: nodeID) { state in
        state.recordFailure(message, at: Date())
      }
      await appendRunLog(
        packagePath: located.packagePath, startedAt: startedAt, success: false, message: message)
      throw error
    }
  }

  /// Validates agent-supplied payload JSON against the widget's view and stores it directly,
  /// bypassing the script — the push-style alternative to a scheduled pull.
  @discardableResult
  public func setPayload(nodeID: UUID, payloadJSON: String) async throws -> WidgetRuntimeState {
    let located = try await locate(nodeID)
    let manifestText = try await documents.read(relativePath: "\(located.packagePath)/widget.json")
    let manifest = try JSONDecoder().decode(WidgetManifest.self, from: Data(manifestText.utf8))
    let trimmed = payloadJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    let typedPayload = try manifest.view.map {
      try WidgetPayload.parse(json: trimmed, kind: $0.kind)
    }
    if manifest.view == nil {
      _ = try validatedWidgetDataJSON(trimmed)
    }
    return try await persist(nodeID: nodeID) { state in
      if let view = manifest.view, let typedPayload {
        state.recordSuccess(
          payloadJSON: trimmed, payload: typedPayload, at: Date(),
          historyLimit: view.resolvedHistoryLimit)
      } else {
        state.recordHTMLSuccess(payloadJSON: trimmed, at: Date())
      }
    }
  }

  public func runHistory(nodeID: UUID, limit: Int) async throws -> [String] {
    let located = try await locate(nodeID)
    let path = "\(located.packagePath)/\(Self.runLogRelativeName)"
    guard let content = try? await documents.read(relativePath: path) else { return [] }
    let lines = content.split(separator: "\n").map(String.init)
    return Array(lines.suffix(max(1, min(200, limit))))
  }

  private struct LocatedWidget: Sendable {
    var canvasID: UUID
    var packagePath: String
  }

  private func locate(_ nodeID: UUID) async throws -> LocatedWidget {
    let store = store
    return try await MainActor.run {
      for canvas in store.snapshot.canvases {
        guard let node = canvas.nodes.first(where: { $0.id == nodeID }) else { continue }
        guard node.kind == .widget, case .widget(let path, _) = node.content, !path.isEmpty
        else { throw WidgetJobError.missingDataConfiguration }
        return LocatedWidget(canvasID: canvas.id, packagePath: path)
      }
      throw WidgetJobError.nodeNotFound(nodeID)
    }
  }

  /// Re-reads the freshest node state before mutating so a run never clobbers data written
  /// while the script was executing.
  private func persist(
    nodeID: UUID, mutate: @Sendable (inout WidgetRuntimeState) -> Void
  ) async throws -> WidgetRuntimeState {
    let store = store
    return try await MainActor.run {
      for canvas in store.snapshot.canvases {
        guard let node = canvas.nodes.first(where: { $0.id == nodeID }) else { continue }
        guard case .widget(let path, let stateJSON) = node.content else {
          throw WidgetJobError.missingDataConfiguration
        }
        var state = WidgetRuntimeState.decode(from: stateJSON)
        mutate(&state)
        _ = store.dispatch(
          .setNodeContent(id: nodeID, content: .widget(packagePath: path, state: state.encoded())),
          targetCanvasID: canvas.id
        )
        return state
      }
      throw WidgetJobError.nodeNotFound(nodeID)
    }
  }

  private func appendRunLog(
    packagePath: String, startedAt: Date, success: Bool, message: String
  ) async {
    struct RunRecord: Codable {
      var at: Date
      var durationSeconds: Double
      var success: Bool
      var message: String
    }
    let record = RunRecord(
      at: startedAt,
      durationSeconds: (Date().timeIntervalSince(startedAt) * 1_000).rounded() / 1_000,
      success: success,
      message: String(message.prefix(500))
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(record), let line = String(data: data, encoding: .utf8)
    else { return }
    let path = "\(packagePath)/\(Self.runLogRelativeName)"
    guard let content = try? await documents.append(relativePath: path, text: line + "\n") else {
      return
    }
    if content.utf8.count > Self.runLogByteLimit {
      let trimmed = content.split(separator: "\n").suffix(100).joined(separator: "\n") + "\n"
      try? await documents.replace(relativePath: path, text: trimmed)
    }
  }

  static func validatedScriptPath(_ value: String) throws -> String {
    let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = NSString(string: path).pathComponents
    guard !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), !components.contains(".."),
      !components.contains("~")
    else { throw WidgetJobError.scriptMissing(value) }
    return path
  }

  private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
      self.limit = limit
    }

    func append(_ chunk: Data) {
      lock.lock()
      defer { lock.unlock() }
      guard data.count < limit else { return }
      data.append(chunk.prefix(limit - data.count))
    }

    var text: String {
      lock.lock()
      defer { lock.unlock() }
      return String(data: data, encoding: .utf8) ?? ""
    }
  }

  private static func execute(
    scriptPath: String, workingDirectory: String, timeoutSeconds: Int
  ) async throws -> String {
    guard FileManager.default.fileExists(atPath: scriptPath) else {
      throw WidgetJobError.scriptMissing(scriptPath)
    }
    let stdout = PipeBuffer(limit: stdoutByteLimit)
    let stderr = PipeBuffer(limit: stderrByteLimit)
    let executionTask = Task.detached(priority: .background) {
      () -> (status: Int32, timedOut: Bool, cancelled: Bool) in
      let process = Process()
      #if canImport(Darwin)
        // macOS rejects shell-level RLIMIT_AS/RLIMIT_RSS changes for these child processes.
        // Wall-clock, CPU, priority, output, and system-pressure limits still apply.
        let memoryLimitCommand = ""
      #else
        let memoryLimitCommand = "ulimit -v \(memoryLimitKilobytes)"
      #endif
      let wrapper = """
        ulimit -t \(min(cpuTimeLimitSeconds, timeoutSeconds))
        \(memoryLimitCommand)
        exec /bin/zsh "$1"
        """
      if FileManager.default.isExecutableFile(atPath: "/usr/bin/nice") {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = [
          "-n", "\(niceValue)", "/bin/zsh", "-c", wrapper, "otto-widget", scriptPath,
        ]
      } else {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", wrapper, "otto-widget", scriptPath]
      }
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
      var environment = ProcessInfo.processInfo.environment
      environment["OTTO_WIDGET_PACKAGE"] = workingDirectory
      environment["NO_COLOR"] = "1"
      process.environment = environment
      process.standardInput = FileHandle.nullDevice
      let outPipe = Pipe()
      let errPipe = Pipe()
      let outHandle = outPipe.fileHandleForReading
      let errHandle = errPipe.fileHandleForReading
      process.standardOutput = outPipe
      process.standardError = errPipe
      outHandle.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { stdout.append(chunk) }
      }
      errHandle.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { stderr.append(chunk) }
      }
      defer {
        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil
        try? outHandle.close()
        try? errHandle.close()
      }
      do {
        try process.run()
      } catch {
        return (127, false, false)
      }
      let processID = process.processIdentifier
      let ownsProcessGroup = setpgid(processID, processID) == 0
      let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
      while process.isRunning && Date() < deadline && !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(50))
      }
      if process.isRunning {
        let cancelled = Task.isCancelled
        let descendants = descendantProcessIDs(of: processID)
        sendSignal(
          processID: processID, ownsProcessGroup: ownsProcessGroup, signal: SIGTERM)
        for descendant in descendants.reversed() {
          sendSignal(processID: descendant, ownsProcessGroup: false, signal: SIGTERM)
        }
        try? await Task.sleep(for: .milliseconds(500))
        if process.isRunning {
          let remainingDescendants = Set(descendants + descendantProcessIDs(of: processID))
          for descendant in remainingDescendants {
            sendSignal(processID: descendant, ownsProcessGroup: false, signal: SIGKILL)
          }
          sendSignal(
            processID: processID, ownsProcessGroup: ownsProcessGroup, signal: SIGKILL)
        }
        process.waitUntilExit()
        return (process.terminationStatus, !cancelled, cancelled)
      }
      process.waitUntilExit()
      return (process.terminationStatus, false, false)
    }
    let result = await withTaskCancellationHandler {
      await executionTask.value
    } onCancel: {
      executionTask.cancel()
    }
    if result.cancelled {
      throw WidgetJobError.cancelled
    }
    if result.timedOut {
      throw WidgetJobError.timedOut(seconds: timeoutSeconds)
    }
    guard result.status == 0 else {
      throw WidgetJobError.scriptFailed(
        status: result.status,
        stderr: String(stderr.text.suffix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return stdout.text
  }

  private nonisolated static func sendSignal(
    processID: pid_t, ownsProcessGroup: Bool, signal: Int32
  ) {
    let target = ownsProcessGroup ? -processID : processID
    #if canImport(Darwin)
      _ = Darwin.kill(target, signal)
    #elseif canImport(Glibc)
      _ = Glibc.kill(target, signal)
    #endif
  }

  /// Process groups are the fast path, but `Process.run()` can race with `setpgid` after exec.
  /// Recursively capturing descendants before termination closes that gap and prevents a script
  /// from escaping its wall-clock budget by leaving a busy child behind.
  private nonisolated static func descendantProcessIDs(of root: pid_t) -> [pid_t] {
    let candidates = ["/usr/bin/pgrep", "/bin/pgrep"]
    guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    else { return [] }
    var descendants: [pid_t] = []
    var pending = [root]
    while let parent = pending.popLast() {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-P", "\(parent)"]
      process.standardInput = FileHandle.nullDevice
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        process.waitUntilExit()
      } catch {
        continue
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let children = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isWhitespace)
        .compactMap { pid_t($0) }
      descendants.append(contentsOf: children)
      pending.append(contentsOf: children)
    }
    return descendants
  }
}

import Foundation
import OttoTools

public enum LocalVoiceBrainEvent: Sendable, Equatable {
  /// More of the reply, as it is written.
  case text(String)
  /// A stretch of the reply has ended, usually because a tool is about to run.
  case pause
  /// The whole reply to the last request is complete.
  case finished
  case failed(String)
}

public enum LocalVoiceBrainError: Error, LocalizedError, Sendable {
  case assistantMissing
  case couldNotStart(String)

  public var errorDescription: String? {
    switch self {
    case .assistantMissing:
      "Sign in to Claude Code on this Mac to use voice without an API key."
    case .couldNotStart(let detail):
      "The assistant behind local voice could not start: \(detail)"
    }
  }
}

/// What does the thinking for the local voice engine.
public protocol LocalVoiceThinking: Sendable {
  var events: AsyncStream<LocalVoiceBrainEvent> { get }
  func start(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) async throws
  func ask(_ text: String) async
  func interrupt() async
  func stop() async
}

public struct LocalVoiceBrainConfiguration: Sendable {
  public var executable: URL
  public var model: String
  public var instructions: String

  public init(executable: URL, model: String = "haiku", instructions: String) {
    self.executable = executable
    self.model = model
    self.instructions = instructions
  }
}

/// Thinks with the person's own Claude Code sign-in, so local voice needs no API key.
///
/// One assistant process stays open for the whole conversation: starting a new one for every
/// sentence would add seconds of silence. It is given no tools of its own and no settings from
/// the Mac; the only things it can do are the Otto tools offered through `LocalToolBridge`.
public actor ClaudeCodeVoiceBrain: LocalVoiceThinking {
  public nonisolated let events: AsyncStream<LocalVoiceBrainEvent>
  private let continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation
  private let configuration: LocalVoiceBrainConfiguration
  private var process: Process?
  private var input: FileHandle?
  private var bridge: LocalToolBridge?
  private var workDirectory: URL?
  private var readTask: Task<Void, Never>?
  /// Replies still on their way from requests that were interrupted; their text is not spoken.
  private var abandonedReplies = 0
  private var awaitingReply = false

  public init(configuration: LocalVoiceBrainConfiguration) {
    self.configuration = configuration
    var continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  public func start(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) async throws {
    guard FileManager.default.isExecutableFile(atPath: configuration.executable.path) else {
      throw LocalVoiceBrainError.assistantMissing
    }
    let bridge = try LocalToolBridge(tools: tools, call: call)
    try await bridge.start()
    self.bridge = bridge

    // The connection secret goes in a private file rather than on the command line, where any
    // process on the Mac could read it.
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "otto-voice-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let settingsURL = directory.appending(path: "tools.json")
    let settings: JSONValue = .object([
      "mcpServers": .object([
        "otto": .object([
          "type": .string("http"),
          "url": .string(bridge.address),
          "headers": .object(["Authorization": .string("Bearer \(bridge.token)")]),
        ])
      ])
    ])
    try JSONEncoder().encode(settings).write(to: settingsURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    workDirectory = directory

    let process = Process()
    process.executableURL = configuration.executable
    process.arguments = Self.arguments(configuration: configuration, settings: settingsURL)
    process.currentDirectoryURL = directory
    process.environment = Self.environment(ProcessInfo.processInfo.environment)
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      throw LocalVoiceBrainError.couldNotStart(error.localizedDescription)
    }
    self.process = process
    input = stdin.fileHandleForWriting
    let handle = stdout.fileHandleForReading
    readTask = Task { [weak self] in
      do {
        for try await line in handle.bytes.lines {
          await self?.handle(line: line)
        }
      } catch {}
      await self?.ended()
    }
  }

  static func arguments(configuration: LocalVoiceBrainConfiguration, settings: URL) -> [String] {
    [
      "-p", "--input-format", "stream-json", "--output-format", "stream-json",
      "--include-partial-messages", "--verbose",
      "--model", configuration.model,
      "--system-prompt", configuration.instructions,
      // No file, shell or web tools: only what Otto offers through the bridge.
      "--tools", "",
      "--strict-mcp-config", "--mcp-config", settings.path,
      "--allowedTools", "mcp__otto",
      // Hooks, plugins and project instructions on this Mac must not shape a voice reply.
      "--setting-sources", "",
      "--disable-slash-commands", "--no-session-persistence",
    ]
  }

  /// Variables from a surrounding Claude Code or API session would point the assistant at the
  /// wrong account, so it starts from the person's own sign-in.
  static func environment(_ inherited: [String: String]) -> [String: String] {
    inherited.filter { key, _ in
      !(key.hasPrefix("CLAUDE") || key.hasPrefix("ANTHROPIC") || key.hasPrefix("OTTO_"))
    }
  }

  public func ask(_ text: String) async {
    if awaitingReply {
      abandonedReplies += 1
    }
    awaitingReply = true
    write([
      "type": .string("user"),
      "message": .object(["role": .string("user"), "content": .string(text)]),
    ])
  }

  public func interrupt() async {
    guard awaitingReply else { return }
    awaitingReply = false
    abandonedReplies += 1
    write([
      "type": .string("control_request"),
      "request_id": .string(UUID().uuidString),
      "request": .object(["subtype": .string("interrupt")]),
    ])
  }

  public func stop() async {
    readTask?.cancel()
    readTask = nil
    try? input?.close()
    input = nil
    if process?.isRunning == true { process?.terminate() }
    process = nil
    bridge?.stop()
    bridge = nil
    if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    workDirectory = nil
    continuation.finish()
  }

  private func write(_ object: [String: JSONValue]) {
    guard let input, var data = try? JSONEncoder().encode(JSONValue.object(object)) else { return }
    data.append(0x0A)
    try? input.write(contentsOf: data)
  }

  private func handle(line: String) {
    guard let event = Self.parse(line) else { return }
    switch event {
    case .finished, .failed:
      if abandonedReplies > 0 {
        abandonedReplies -= 1
        return
      }
      awaitingReply = false
      continuation.yield(event)
    case .text, .pause:
      guard abandonedReplies == 0, awaitingReply else { return }
      continuation.yield(event)
    }
  }

  private func ended() {
    guard process != nil else { return }
    continuation.yield(
      .failed("The assistant behind local voice stopped. Is Claude Code signed in?"))
  }

  /// Reads one line of the assistant's output stream.
  static func parse(_ line: String) -> LocalVoiceBrainEvent? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
      let object = value.objectValue, let type = object["type"]?.stringValue
    else { return nil }
    switch type {
    case "stream_event":
      guard let event = object["event"]?.objectValue, let kind = event["type"]?.stringValue
      else { return nil }
      if kind == "content_block_delta", let delta = event["delta"]?.objectValue,
        delta["type"]?.stringValue == "text_delta", let text = delta["text"]?.stringValue
      {
        return .text(text)
      }
      return kind == "content_block_stop" ? .pause : nil
    case "result":
      if case .bool(true)? = object["is_error"] {
        return .failed(object["result"]?.stringValue ?? "The assistant returned an error.")
      }
      return .finished
    default:
      return nil
    }
  }
}

import Foundation
import OttoModels
import OttoRuntime
import OttoTools
import OttoVoice
import os

/// Thinks for local voice with any harness Otto can already run: Codex, Otto's own API and
/// local-model harness, Cursor, Grok, Kimi, OpenCode or Pi.
///
/// It leans on what Otto has for agents. The harness's adapter builds the command for one
/// prompt, the shared parser reads its output, and the conversation continues by resuming the
/// harness's own session. Two things differ from an agent: the folder is an empty one made for
/// voice, and the tools come from the voice engine, so what they do carries the person's own
/// privileges and anything opened is a session the person can see.
///
/// A harness is started afresh for every request, which costs a second or two that the kept-open
/// Claude Code assistant does not pay, and it speaks once its reply is complete.
actor HarnessVoiceBrain: LocalVoiceThinking {
  nonisolated let events: AsyncStream<LocalVoiceBrainEvent>
  private let continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation
  private static let logger = Logger(subsystem: "io.openotto.desktop", category: "LocalVoice")

  private let provider: AgentProvider
  private let adapter: any AgentAdapter
  private let model: String?
  private let instructions: String
  private let workspace: URL
  private let toolBridgeExecutable: String?

  private var bridge: LocalToolBridge?
  private var sessionID: String?
  private var process: Process?
  /// Raised for each request and each interruption, so a superseded run's words are dropped.
  private var turn = 0

  init(
    provider: AgentProvider,
    model: String?,
    instructions: String,
    workspace: URL = HarnessVoiceBrain.defaultWorkspace(),
    toolBridgeExecutable: String? = HarnessVoiceBrain.toolBridgeExecutable()
  ) {
    self.provider = provider
    adapter = Self.adapter(for: provider)
    self.model = model
    self.instructions = instructions
    self.workspace = workspace
    self.toolBridgeExecutable = toolBridgeExecutable
    var continuation: AsyncStream<LocalVoiceBrainEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  /// The harnesses voice can think with, in the order Otto prefers when nothing has been chosen.
  static let providers: [AgentProvider] = [
    .claudeCode, .codex, .openAI, .cursor, .grok, .kimi, .openCode, .pi,
  ]

  static func adapter(for provider: AgentProvider) -> any AgentAdapter {
    switch provider {
    case .claudeCode: ClaudeCodeAdapter()
    case .codex: CodexAdapter()
    case .openAI: OpenAIDirectAdapter()
    case .cursor: CursorAdapter()
    case .grok: GrokAdapter()
    case .kimi: KimiAdapter()
    case .openCode: OpenCodeAdapter()
    case .pi: PiAdapter()
    case .hermes: HermesAdapter()
    case .shell: ShellAdapter()
    }
  }

  /// An empty folder of voice's own. Several harnesses write their tool settings into the folder
  /// they start in, and none of them should start inside a project.
  static func defaultWorkspace() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Otto/VoiceThinking")
  }

  static func toolBridgeExecutable() -> String? {
    let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
      .appending(path: "otto-mcp").path
    if let bundled, FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    return ExecutableLocator.find("otto-mcp")
  }

  func start(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) async throws {
    guard case .installed = await adapter.detectInstallation() else {
      throw LocalVoiceBrainError.couldNotStart(
        "\(provider.rawValue) is not installed. Choose another harness in Voice settings.")
    }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let bridge = try LocalToolBridge(tools: tools, call: call)
    try await bridge.start()
    self.bridge = bridge
  }

  func ask(_ text: String) async {
    turn += 1
    let current = turn
    stopProcess()
    guard let bridge else { return }
    let request = AgentLaunchRequest(
      workspacePath: workspace.path,
      prompt: text,
      model: model,
      // A spoken reply is wanted in seconds, and deliberating is what makes Codex slow.
      effort: provider == .codex ? "low" : nil,
      // The folder is empty and voice's own, so writing inside it harms nothing. Read-only
      // would also stop harnesses from pre-approving Otto's tools, leaving voice unable to act.
      permissionMode: .workspaceWrite,
      resumeSessionID: sessionID,
      ottoMCPExecutable: toolBridgeExecutable,
      controlEnvironment: [
        "OTTO_VOICE_BRIDGE_URL": bridge.address,
        "OTTO_VOICE_BRIDGE_TOKEN": bridge.token,
      ],
      ottoSelfConfirmingTools: bridge.toolNames,
      profileInstructions: instructions
    )
    let spec: ProcessLaunchSpec
    do {
      spec = try await adapter.buildLaunchSpec(request)
    } catch {
      continuation.yield(.failed(error.localizedDescription))
      return
    }
    guard current == turn else { return }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: spec.executable)
    process.arguments = spec.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: spec.workingDirectory)
    process.environment = Self.environment(for: spec, bridge: request.controlEnvironment)
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      continuation.yield(
        .failed("\(provider.rawValue) could not start: \(error.localizedDescription)"))
      return
    }
    self.process = process
    let provider = provider
    let handle = output.fileHandleForReading
    Task { [weak self] in
      var parser = ProviderParser.forProvider(provider)
      var spoke = false
      var failure: String?
      func absorb(_ parsed: [ParsedAgentEvent]) async {
        for event in parsed {
          switch event {
          case .sessionStarted(let id):
            await self?.remember(session: id, turn: current)
          case .assistantMessage(let message):
            spoke = true
            await self?.deliver(.text(message + " "), turn: current)
            await self?.deliver(.pause, turn: current)
          case .result(let result) where result.status == .failed:
            failure = result.summaryCandidate
          default:
            break
          }
        }
      }
      do {
        for try await line in handle.bytes.lines { await absorb(parser.ingest(line: line)) }
      } catch {}
      await absorb(parser.finish())
      process.waitUntilExit()
      if !spoke, failure != nil || process.terminationStatus != 0 {
        let reason = failure.flatMap { $0.isEmpty ? nil : $0 }
        await self?.deliver(
          .failed(reason ?? "\(provider.rawValue) could not answer. Check that it is signed in."),
          turn: current)
      } else {
        await self?.deliver(.finished, turn: current)
      }
    }
  }

  /// Otto's own variables, and those of a surrounding agent session, must not reach the harness:
  /// they would point it at another conversation or at Otto's agent tools instead of voice's.
  ///
  /// The bridge's address is then added back. Codex is told it through its own settings, but
  /// Cursor, Kimi, Pi and Grok start the tool helper with whatever environment they were given.
  static func environment(for spec: ProcessLaunchSpec, bridge: [String: String])
    -> [String: String]
  {
    let removed = spec.inheritedEnvironmentPrefixesToRemove + ["OTTO_", "MUSE_", "CLAUDECODE"]
    var environment = ProcessInfo.processInfo.environment.filter { key, _ in
      !removed.contains(where: key.hasPrefix)
    }
    environment.merge(bridge) { _, voice in voice }
    environment.merge(spec.environment) { _, launch in launch }
    return environment
  }

  private func remember(session id: String, turn: Int) {
    guard turn == self.turn else { return }
    sessionID = id
  }

  private func deliver(_ event: LocalVoiceBrainEvent, turn: Int) {
    guard turn == self.turn else { return }
    if case .failed(let message) = event {
      Self.logger.error("thinking failed: \(message, privacy: .public)")
    }
    continuation.yield(event)
  }

  func interrupt() async {
    turn += 1
    stopProcess()
  }

  func stop() async {
    turn += 1
    stopProcess()
    bridge?.stop()
    bridge = nil
    continuation.finish()
  }

  private func stopProcess() {
    if process?.isRunning == true { process?.terminate() }
    process = nil
  }
}

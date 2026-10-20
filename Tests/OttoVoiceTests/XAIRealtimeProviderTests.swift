import Foundation
import OttoApplicationTools
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import OttoVoice
import Testing

private struct XAITestInput: Codable, Sendable { let value: String }
private struct XAITestOutput: Codable, Sendable { let echoed: String }

private actor XAIBenchmarkCapture {
  private var values: [String] = []

  func record(_ value: String) { values.append(value) }
  func snapshot() -> [String] { values }
}

private struct XAIBenchmarkTool: OttoTool {
  static let definition = ToolDefinition(
    name: "benchmark.capture_exact_value",
    description: "Captures the exact benchmark value requested by the user.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object([
          "type": .string("string"),
          "description": .string(
            "The exact value supplied by the user, preserving case and punctuation."
          ),
        ])
      ]),
      "required": .array([.string("value")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  let capture: XAIBenchmarkCapture

  func call(_ input: XAITestInput, context: ToolContext) async throws -> XAITestOutput {
    await capture.record(input.value)
    return XAITestOutput(echoed: input.value)
  }
}

private struct XAITestTool: OttoTool {
  static let definition = ToolDefinition(
    name: "test.xai_echo",
    description: "Echoes a realtime fixture value.",
    inputSchema: .object([
      "type": .string("object"),
      "properties": .object([
        "value": .object(["type": .string("string")])
      ]),
      "required": .array([.string("value")]),
    ]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [.canvasRead],
    riskLevel: .read
  )

  func call(_ input: XAITestInput, context: ToolContext) async throws -> XAITestOutput {
    XAITestOutput(echoed: input.value)
  }
}

@Suite("xAI realtime voice transport")
struct XAIRealtimeProviderTests {
  @Test("Benchmarks authenticated xAI exact command routing")
  func authenticatedCommandBenchmark() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_XAI_BENCHMARK"] == "1" else { return }

    let cases = [
      (#"Capture the exact quoted value "Alpha-7"."#, "Alpha-7"),
      ("Use the benchmark capture tool with value build/API_v2.", "build/API_v2"),
      ("Record exactly: Chase, wait for me!", "Chase, wait for me!"),
      ("Capture the value 0042, keeping the leading zeroes.", "0042"),
      ("Send this exact value to the capture tool: don't paraphrase me", "don't paraphrase me"),
    ]
    let capture = XAIBenchmarkCapture()
    let registry = ToolRegistry()
    try await registry.register(XAIBenchmarkTool(capture: capture))
    let provider = XAIRealtimeProvider(
      secrets: KeychainSecretStore(),
      configuration: XAIRealtimeConfiguration(
        instructions: """
          This is a command-routing benchmark. For every user request, call
          benchmark.capture_exact_value exactly once with the requested value. Preserve the value
          exactly, including case, punctuation, apostrophes, slashes, hyphens, and leading zeroes.
          Do not speak or call any other tool.
          """,
        reasoningEffort: "none"
      )
    )
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "xai-command-benchmark", scopes: [.canvasRead])
    )

    await session.connect(provider: provider)
    defer { Task { await session.sleep() } }
    try await waitForLiveSession(session, state: .listening, timeout: .seconds(30))

    var latencies: [Double] = []
    for (index, benchmarkCase) in cases.enumerated() {
      let started = ContinuousClock.now
      try await provider.sendText(benchmarkCase.0)
      let deadline = ContinuousClock.now + .seconds(30)
      while ContinuousClock.now < deadline {
        if await capture.snapshot().count > index { break }
        let snapshot = await session.snapshot()
        if snapshot.state == .error {
          throw LiveXAITestError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      guard await capture.snapshot().count > index else {
        throw LiveXAITestError.timeout("benchmark case \(index + 1)")
      }
      latencies.append(benchmarkMilliseconds(started.duration(to: ContinuousClock.now)))
    }

    let actual = await capture.snapshot()
    let expected = cases.map(\.1)
    let correct = actual.indices.filter { actual[$0] == expected[$0] }.count
    let sorted = latencies.sorted()
    let median = sorted[sorted.count / 2]
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    print(
      "OTTO_XAI_BENCHMARK result=\(correct)/\(cases.count) "
        + "latency_ms=\(latencies.map { Int($0.rounded()) }) "
        + "median_ms=\(Int(median.rounded())) p95_ms=\(Int(p95.rounded())) "
        + "actual=\(actual)"
    )
    #expect(actual.count == cases.count)
    #expect(correct == cases.count)
  }

  @Test("Authenticated xAI realtime session executes a projected Otto tool")
  func authenticatedToolCall() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_XAI_E2E"] == "1" else { return }

    let registry = ToolRegistry()
    try await registry.register(XAITestTool())
    let provider = XAIRealtimeProvider(
      secrets: KeychainSecretStore(),
      configuration: XAIRealtimeConfiguration(
        instructions:
          "When asked to run the echo check, you must call test.xai_echo exactly once with value live-ok.",
        reasoningEffort: "none"
      )
    )
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "xai-live-e2e", scopes: [.canvasRead])
    )

    await session.connect(provider: provider)
    do {
      try await waitForLiveSession(session, state: .listening, timeout: .seconds(30))
      try await provider.sendText(
        "Run the echo check now. You must use test.xai_echo with value live-ok and no other tool."
      )
      let deadline = ContinuousClock.now + .seconds(60)
      while ContinuousClock.now < deadline {
        if await registry.auditLog().contains(where: {
          $0.toolName == "test.xai_echo" && $0.succeeded
        }) {
          break
        }
        let snapshot = await session.snapshot()
        if snapshot.state == .error {
          throw LiveXAITestError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      guard
        await registry.auditLog().contains(where: {
          $0.toolName == "test.xai_echo" && $0.succeeded
        })
      else {
        let snapshot = await session.snapshot()
        let confirmation = snapshot.lastConfirmation.isEmpty ? "none" : snapshot.lastConfirmation
        let lastError = snapshot.lastError ?? "none"
        throw LiveXAITestError.timeout(
          "tool execution (state: \(snapshot.state), confirmation: \(confirmation), error: \(lastError))"
        )
      }
      #expect(await session.snapshot().lastError == nil)
    } catch {
      await session.sleep()
      throw error
    }
    await session.sleep()
  }

  @Test("Authenticated spoken xAI turn executes a projected Otto tool")
  func authenticatedSpokenToolCall() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_XAI_AUDIO_E2E"] == "1" else { return }

    let registry = ToolRegistry()
    try await registry.register(XAITestTool())
    let provider = XAIRealtimeProvider(
      secrets: KeychainSecretStore(),
      configuration: XAIRealtimeConfiguration(
        instructions:
          "When the user asks to run the echo check, you must call test.xai_echo exactly once with value live-ok.",
        reasoningEffort: "none"
      )
    )
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "xai-spoken-e2e", scopes: [.canvasRead])
    )

    await session.connect(provider: provider)
    do {
      try await waitForLiveSession(session, state: .listening, timeout: .seconds(30))
      let speech = try renderedPCM16Fixture("Run the echo check now.")
      try await streamPCM16(Data(repeating: 0, count: 48_000), to: provider)
      try await streamPCM16(speech, to: provider)
      try await streamPCM16(Data(repeating: 0, count: 96_000), to: provider)
      try await waitForSuccessfulTool("test.xai_echo", registry: registry, session: session)
      #expect(await session.snapshot().lastError == nil)
    } catch {
      await session.sleep()
      throw error
    }
    await session.sleep()
  }

  @Test("Authenticated speech semantically clears a disposable canvas exactly once")
  func authenticatedNaturalClearAll() async throws {
    guard ProcessInfo.processInfo.environment["OTTO_XAI_CLEAR_E2E"] == "1" else { return }

    let first = OttoNode(
      kind: .browser,
      displayName: "Disposable browser",
      subtitle: "BROWSER",
      frame: WorldRect(x: 0, y: 0, width: 400, height: 300),
      zIndex: 0
    )
    let second = OttoNode(
      kind: .terminal,
      displayName: "Disposable terminal",
      subtitle: "TERMINAL",
      frame: WorldRect(x: 420, y: 0, width: 400, height: 300),
      zIndex: 1
    )
    let canvas = OttoCanvas(name: "Disposable voice canvas", nodes: [first, second])
    let store = await CanvasStore(
      snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id))
    let registry = ToolRegistry()
    try await ApplicationToolBootstrap.register(
      in: registry, store: store, supervisor: AgentSupervisor())
    let provider = XAIRealtimeProvider(
      secrets: KeychainSecretStore(),
      configuration: XAIRealtimeConfiguration(
        instructions: """
          You are a quiet voice control layer. Interpret natural references from the current canvas.
          If the user asks to clear, remove, tidy, or close the visible items, call node.close_all
          exactly once. Act before speaking, never narrate, and never repeat a failed tool.
          """,
        reasoningEffort: "none"
      )
    )
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "xai-natural-clear-e2e", scopes: Set(ToolScope.allCases))
    )

    await session.connect(provider: provider)
    do {
      try await waitForLiveSession(session, state: .listening, timeout: .seconds(30))
      let speech = try renderedPCM16Fixture("Can you clear them?")
      try await streamPCM16(Data(repeating: 0, count: 48_000), to: provider)
      try await streamPCM16(speech, to: provider)
      try await streamPCM16(Data(repeating: 0, count: 96_000), to: provider)
      try await waitForSuccessfulTool("node.close_all", registry: registry, session: session)
      #expect(await store.activeCanvas.nodes.isEmpty)
      #expect(
        await registry.auditLog().filter { $0.toolName == "node.close_all" && $0.succeeded }.count
          == 1)
    } catch {
      await session.sleep()
      throw error
    }
    await session.sleep()
  }

  @Test("Session projects tools and returns function output over the socket")
  func toolCallEndToEnd() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("xai-test-secret", for: "xai.api-key")
    let socket = MockRealtimeSocket()
    let provider = XAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    let registry = ToolRegistry()
    try await registry.register(XAITestTool())
    let session = VoiceSession(
      registry: registry,
      context: ToolContext(actorID: "voice-test", scopes: [.canvasRead])
    )

    await session.connect(provider: provider)
    let request = try #require(await socket.request)
    #expect(
      request.url?.absoluteString
        == "wss://voice.test/v1/realtime?model=grok-voice-think-fast-2.0"
    )
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-test-secret")
    try await waitUntil { await socket.sent.count == 1 }
    let update = try jsonObject(await socket.sent[0])
    #expect(update["type"] as? String == "session.update")
    let sessionConfiguration = try #require(update["session"] as? [String: Any])
    #expect(sessionConfiguration["voice"] as? String == "eve")
    let turnDetection = try #require(sessionConfiguration["turn_detection"] as? [String: Any])
    #expect(turnDetection["type"] as? String == "server_vad")
    #expect(turnDetection["threshold"] as? Double == 0.85)
    // 800ms: mid-sentence breaths must not end the turn (premature finals made the assistant
    // answer truncated requests twice).
    #expect(turnDetection["silence_duration_ms"] as? Int == 800)
    let projected = try #require(sessionConfiguration["tools"] as? [[String: Any]])
    #expect(projected.first?["name"] as? String == "test.xai_echo")

    await socket.emit(#"{"type":"session.updated"}"#)
    try await waitUntil { await session.snapshot().state == .listening }
    await socket.emit(
      #"{"type":"conversation.item.input_audio_transcription.updated","transcript":"Create"}"#)
    await socket.emit(
      #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Create it"}"#)
    await socket.emit(
      #"{"type":"response.function_call_arguments.done","call_id":"call-1","name":"test.xai_echo","arguments":"{\"value\":\"hello\"}"}"#
    )

    try await waitUntil { await socket.sent.count >= 3 }
    let outputMessage = try jsonObject(await socket.sent[1])
    #expect(outputMessage["type"] as? String == "conversation.item.create")
    let item = try #require(outputMessage["item"] as? [String: Any])
    #expect(item["type"] as? String == "function_call_output")
    #expect(item["call_id"] as? String == "call-1")
    #expect((item["output"] as? String)?.contains("hello") == true)
    #expect((item["output"] as? String)?.contains(#""ok":true"#) == true)
    #expect(try jsonObject(await socket.sent[2])["type"] as? String == "response.create")
    #expect(await registry.auditLog().map(\.requestID) == ["call-1"])

    await socket.emit(#"{"type":"response.text.delta","delta":"Completed"}"#)
    try await waitUntil { await session.snapshot().state == .speaking }
    #expect(await session.snapshot().lastConfirmation == "Completed")

    await session.interrupt()
    try await waitUntil { await socket.sent.contains(where: { $0.contains("response.cancel") }) }
    await session.sleep()
  }

  @Test("Audio input and output use the documented base64 events")
  func audioRoundTrip() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "xai.api-key")
    let socket = MockRealtimeSocket()
    let provider = XAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])
    let expected = Data([0, 1, 2, 254, 255])
    try await provider.appendAudio(expected)
    try await waitUntil { await socket.sent.count >= 2 }
    let appended = try jsonObject(await socket.sent[1])
    #expect(appended["type"] as? String == "input_audio_buffer.append")
    #expect(appended["audio"] as? String == expected.base64EncodedString())

    let audioTask = Task<Data?, Never> {
      for await data in provider.audioOutput { return data }
      return nil
    }
    await socket.emit(
      "{\"type\":\"response.output_audio.delta\",\"delta\":\"\(expected.base64EncodedString())\"}"
    )
    #expect(await audioTask.value == expected)
    await provider.disconnect()
  }

  @Test("Canvas context updates instructions without exposing node detail")
  func contextUpdate() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("key", for: "xai.api-key")
    let socket = MockRealtimeSocket()
    let provider = XAIRealtimeProvider(
      secrets: secrets,
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    try await provider.connect(tools: [])
    let node = OttoNode(
      kind: .agent,
      displayName: "Marlow",
      subtitle: "CLAUDE",
      frame: WorldRect(x: 0, y: 0, width: 300, height: 200),
      zIndex: 0,
      status: .waiting,
      detail: "private terminal transcript",
      content: .agent(provider: .claudeCode)
    )
    let context = VoiceContext(
      canvas: OttoCanvas(name: "Launch", nodes: [node], selectedNodeID: node.id),
      workspace: "/workspace/otto"
    )

    await provider.updateContext(context)
    try await waitUntil { await socket.sent.count == 2 }
    let update = try jsonObject(await socket.sent[1])
    let session = try #require(update["session"] as? [String: Any])
    let instructions = try #require(session["instructions"] as? String)
    #expect(instructions.contains("Launch"))
    #expect(instructions.contains("Marlow"))
    #expect(instructions.contains(node.id.uuidString))
    #expect(!instructions.contains("private terminal transcript"))
    await provider.disconnect()
  }

  @Test("Unexpected disconnect reconnects with a fresh authenticated socket")
  func reconnect() async throws {
    let secrets = InMemorySecretStore()
    try await secrets.set("reconnect-key", for: "xai.api-key")
    let first = MockRealtimeSocket()
    let second = MockRealtimeSocket()
    let factory = MockSocketFactory([first, second])
    let provider = XAIRealtimeProvider(
      secrets: secrets,
      configuration: XAIRealtimeConfiguration(
        endpoint: URL(string: "wss://voice.test/v1/realtime")!,
        instructions: "Test",
        maximumReconnectAttempts: 2,
        reconnectDelay: .zero
      ),
      socketFactory: { await factory.next() }
    )
    let session = VoiceSession(
      registry: ToolRegistry(),
      context: ToolContext(actorID: "reconnect", scopes: [])
    )
    await session.connect(provider: provider)
    await first.emit(#"{"type":"session.updated"}"#)
    try await waitUntil { await session.snapshot().state == .listening }

    await first.finish()
    try await waitUntil {
      let count = await factory.makeCount
      let request = await second.request
      return count == 2 && request != nil
    }
    #expect(
      await second.request?.value(forHTTPHeaderField: "Authorization") == "Bearer reconnect-key")
    await second.emit(#"{"type":"session.updated"}"#)
    try await waitUntil { await session.snapshot().state == .listening }
    await session.sleep()
  }

  @Test("Missing API key fails before opening a socket")
  func missingKey() async {
    let socket = MockRealtimeSocket()
    let provider = XAIRealtimeProvider(
      secrets: InMemorySecretStore(),
      configuration: testConfiguration,
      socketFactory: { socket }
    )
    await #expect(throws: XAIRealtimeError.missingAPIKey) {
      try await provider.connect(tools: [])
    }
    #expect(await socket.request == nil)
  }

  private var testConfiguration: XAIRealtimeConfiguration {
    XAIRealtimeConfiguration(
      endpoint: URL(string: "wss://voice.test/v1/realtime")!,
      instructions: "Control Otto with concise confirmations.",
      reconnectDelay: .zero
    )
  }
}

private actor MockRealtimeSocket: RealtimeSocket {
  nonisolated let messages: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private(set) var request: URLRequest?
  private(set) var sent: [String] = []

  init() {
    var continuation: AsyncStream<String>.Continuation!
    messages = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func connect(request: URLRequest) async throws { self.request = request }
  func send(text: String) async throws { sent.append(text) }
  func disconnect() async { continuation.finish() }
  func emit(_ message: String) { continuation.yield(message) }
  func finish() { continuation.finish() }
}

private actor MockSocketFactory {
  private var sockets: [MockRealtimeSocket]
  private(set) var makeCount = 0

  init(_ sockets: [MockRealtimeSocket]) { self.sockets = sockets }

  func next() -> any RealtimeSocket {
    defer { makeCount += 1 }
    if sockets.isEmpty { return MockRealtimeSocket() }
    return sockets.removeFirst()
  }
}

private func jsonObject(_ string: String) throws -> [String: Any] {
  try #require(
    try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any]
  )
}

private func waitUntil(
  timeout: Duration = .seconds(2),
  _ condition: @escaping @Sendable () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for realtime voice state")
}

private enum LiveXAITestError: Error, CustomStringConvertible {
  case provider(String)
  case timeout(String)

  var description: String {
    switch self {
    case .provider(let message): "xAI realtime provider failed: \(message)"
    case .timeout(let phase): "Timed out waiting for xAI realtime \(phase)"
    }
  }
}

private func waitForLiveSession(
  _ session: VoiceSession,
  state expected: VoiceState,
  timeout: Duration
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    let snapshot = await session.snapshot()
    if snapshot.state == expected { return }
    if snapshot.state == .error {
      throw LiveXAITestError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
    }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw LiveXAITestError.timeout(expected.rawValue)
}

private func waitForSuccessfulTool(
  _ name: String,
  registry: ToolRegistry,
  session: VoiceSession,
  timeout: Duration = .seconds(45)
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await registry.auditLog().contains(where: { $0.toolName == name && $0.succeeded }) {
      return
    }
    let snapshot = await session.snapshot()
    if snapshot.state == .error {
      throw LiveXAITestError.provider(snapshot.lastError ?? "Unknown xAI realtime error")
    }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw LiveXAITestError.timeout("spoken tool execution")
}

private func streamPCM16(_ data: Data, to provider: XAIRealtimeProvider) async throws {
  let chunkSize = 4_800
  var offset = 0
  while offset < data.count {
    let end = min(offset + chunkSize, data.count)
    try await provider.appendAudio(data.subdata(in: offset..<end))
    offset = end
    try await Task.sleep(for: .milliseconds(100))
  }
}

private func renderedPCM16Fixture(_ text: String) throws -> Data {
  let fileManager = FileManager.default
  let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: directory) }
  let source = directory.appendingPathComponent("speech.aiff")
  let output = directory.appendingPathComponent("speech.pcm")

  try runFixtureProcess("/usr/bin/say", arguments: ["-o", source.path, text])
  let ffmpeg = "/opt/homebrew/bin/ffmpeg"
  guard fileManager.isExecutableFile(atPath: ffmpeg) else {
    throw LiveXAITestError.provider("ffmpeg is required for the spoken xAI fixture")
  }
  try runFixtureProcess(
    ffmpeg,
    arguments: [
      "-nostdin", "-loglevel", "error", "-y", "-i", source.path, "-f", "s16le", "-ar",
      "24000", "-ac", "1", output.path,
    ]
  )
  return try Data(contentsOf: output)
}

private func runFixtureProcess(_ executable: String, arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw LiveXAITestError.provider("Audio fixture process failed")
  }
}

private func benchmarkMilliseconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
}

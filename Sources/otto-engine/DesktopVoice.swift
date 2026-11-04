import Foundation
import OttoCore
import OttoModels
import OttoRPCContracts
import OttoSecurity
import OttoServices
import OttoTools
import OttoVoice

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// Otto Desktop's voice: the Mac's own VoiceSession (realtime provider, tools, hand-off to bots)
// running in the engine, with the desktop supplying what is platform-specific: the operating
// system keychain, the microphone and speakers, and the WebSocket to the voice provider.

// MARK: - Secrets in the OS keychain

/// Secrets kept by Otto Desktop with the operating system's keychain (Electron safeStorage:
/// DPAPI on Windows, the Secret Service on Linux, the Keychain on macOS). The engine never writes
/// them to disk itself.
actor DesktopSecretStore: SecretStore {
  private struct KeyParams: Encodable, Sendable { var key: String }
  private struct SetParams: Encodable, Sendable {
    var key: String
    var value: String
  }

  private let host: DesktopHost

  init(host: DesktopHost) { self.host = host }

  func set(_ value: String, for key: String) async throws {
    _ = try await host.call("secrets.set", SetParams(key: key, value: value), as: Bool.self)
  }

  func value(for key: String) async throws -> String? {
    try await host.call("secrets.get", KeyParams(key: key), as: String?.self)
  }

  func delete(_ key: String) async throws {
    _ = try await host.call("secrets.delete", KeyParams(key: key), as: Bool.self)
  }

  /// Moves secrets an older engine saved in its state folder into the keychain, then removes the
  /// file so no copy stays on disk in plain text.
  func adopt(legacyFile: URL) async {
    guard let data = try? Data(contentsOf: legacyFile),
      let saved = try? JSONDecoder().decode([String: String].self, from: data)
    else { return }
    for (key, value) in saved {
      do { try await set(value, for: key) } catch { return }
    }
    try? FileManager.default.removeItem(at: legacyFile)
  }
}

// MARK: - The provider WebSocket, opened by the desktop

/// A RealtimeSocket whose connection lives in Otto Desktop's main process, which works the same
/// on Windows, Linux and macOS. Frames travel over the engine's host channel.
final class DesktopRealtimeSocket: RealtimeSocket, @unchecked Sendable {
  private struct OpenParams: Encodable, Sendable {
    var id: String
    var url: String
    var headers: [String: String]
  }
  private struct FrameParams: Encodable, Sendable {
    var id: String
    var text: String
  }
  private struct IDParams: Encodable, Sendable { var id: String }
  private struct Frame: Decodable {
    var id: String
    var text: String?
  }

  let messages: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private let host: DesktopHost
  private let id = UUID().uuidString

  init(host: DesktopHost) {
    self.host = host
    var continuation: AsyncStream<String>.Continuation!
    messages = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func connect(request: URLRequest) async throws {
    guard let url = request.url?.absoluteString else { throw URLError(.badURL) }
    let continuation = self.continuation
    let id = self.id
    await host.on("socket.message.\(id)") { payload in
      if let frame = try? OttoRPCCodec.decode(Frame.self, from: payload), let text = frame.text {
        continuation.yield(text)
      }
    }
    await host.on("socket.closed.\(id)") { _ in continuation.finish() }
    _ = try await host.call(
      "socket.open",
      OpenParams(id: id, url: url, headers: request.allHTTPHeaderFields ?? [:]),
      as: Bool.self, timeout: .seconds(20))
  }

  func send(text: String) async throws {
    await host.send("socket.send", FrameParams(id: id, text: text))
  }

  func disconnect() async {
    await host.send("socket.close", IDParams(id: id))
    await host.off("socket.message.\(id)")
    await host.off("socket.closed.\(id)")
    continuation.finish()
  }
}

// MARK: - Microphone and speakers, in the desktop

/// 24 kHz mono PCM16 both ways, the format the realtime providers use. The desktop captures and
/// plays it with Chromium's audio stack and reports when the person starts speaking (barge-in).
actor DesktopAudioTransport: VoiceAudioTransport {
  private struct AudioChunk: Codable, Sendable { var pcm: String }
  private struct EnabledParams: Encodable, Sendable { var enabled: Bool }
  private struct Empty: Encodable, Sendable {}

  private let host: DesktopHost
  private var speechHandler: (@Sendable () -> Void)?

  init(host: DesktopHost) { self.host = host }

  func setSpeechActivityHandler(_ handler: (@Sendable () -> Void)?) async {
    speechHandler = handler
  }

  func startInput(_ handler: @escaping @Sendable (Data) -> Void) async throws {
    await host.on("audio.input") { payload in
      if let chunk = try? OttoRPCCodec.decode(AudioChunk.self, from: payload),
        let data = Data(base64Encoded: chunk.pcm)
      {
        handler(data)
      }
    }
    await host.on("audio.speech") { [weak self] _ in await self?.speechStarted() }
    _ = try await host.call("audio.start", Empty(), as: Bool.self, timeout: .seconds(20))
  }

  private func speechStarted() { speechHandler?() }

  func setInputEnabled(_ enabled: Bool) async {
    await host.send("audio.inputEnabled", EnabledParams(enabled: enabled))
  }

  func play(_ data: Data) async throws {
    await host.send("audio.play", AudioChunk(pcm: data.base64EncodedString()))
  }

  func waitForPlaybackToFinish(timeout: Duration) async {
    _ = try? await host.call("audio.drain", Empty(), as: Bool.self, timeout: timeout)
  }

  func stopPlayback() async {
    await host.send("audio.flush", Empty())
  }

  func stop() async {
    await host.off("audio.input")
    await host.off("audio.speech")
    _ = try? await host.call("audio.stop", Empty(), as: Bool.self, timeout: .seconds(5))
  }
}

// MARK: - The voice session

/// Talk to Otto on the desktop: the same VoiceSession, supervisor instructions, workspace context
/// and task planner as the Mac's VoiceController, with desktop audio and sockets.
@MainActor
final class DesktopVoice {
  struct Status: Encodable, Sendable {
    var state: String
    var partialTranscript: String
    var lastTranscript: String
    var lastConfirmation: String
    var lastError: String?
    var provider: String
    var voice: String
    var keys: [String: Bool]
    var voices: [String: [VoiceOption]]
    var conversation: [VoiceConversationRecord]
  }

  private let services: ApplicationServices
  private let store: CanvasStore
  private let host: DesktopHost
  private let secrets: any SecretStore
  private let workspacePath: String
  private let session: VoiceSession
  private var snapshot = VoiceSessionSnapshot()
  private var conversation: [VoiceConversationRecord] = []
  private var keys: [String: Bool] = [:]
  private var lastContext: VoiceContext?
  private(set) var provider: VoiceProviderKind = .openai
  private(set) var voice: String = VoiceCatalog.defaultVoiceID(for: .openai)

  init(
    services: ApplicationServices, store: CanvasStore, host: DesktopHost,
    secrets: any SecretStore, workspacePath: String
  ) {
    self.services = services
    self.store = store
    self.host = host
    self.secrets = secrets
    self.workspacePath = workspacePath
    session = VoiceSession(
      registry: services.registry,
      context: ToolContext(actorID: "otto-voice", scopes: Set(ToolScope.allCases), source: .voice),
      audioTransport: DesktopAudioTransport(host: host),
      taskPlanner: OpenAIVoiceTaskPlanner(secrets: secrets))
  }

  func start() async {
    await refreshKeys()
    let session = self.session
    Task { [weak self] in
      for await update in session.updates {
        self?.snapshot = update
        await self?.publish()
      }
    }
    Task { [weak self] in
      for await records in session.conversationUpdates {
        self?.conversation = records
        await self?.publish()
      }
    }
    Task {
      // Tool calls are audited by the registry; drain the stream so it never buffers.
      for await _ in session.actions {}
    }
    // Keep the voice's picture of bots, teams and sessions current, as the Mac does.
    Task { [weak self] in
      while !Task.isCancelled {
        await self?.syncContext()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func status() -> Status {
    Status(
      state: snapshot.state.rawValue, partialTranscript: snapshot.partialTranscript,
      lastTranscript: snapshot.lastTranscript, lastConfirmation: snapshot.lastConfirmation,
      lastError: snapshot.lastError, provider: provider.rawValue, voice: voice, keys: keys,
      voices: [
        VoiceProviderKind.openai.rawValue: VoiceCatalog.options(for: .openai),
        VoiceProviderKind.xai.rawValue: VoiceCatalog.options(for: .xai),
      ],
      conversation: Array(conversation.suffix(60)))
  }

  func configure(provider: VoiceProviderKind, voice: String?) {
    self.provider = provider
    self.voice = VoiceCatalog.validatedVoiceID(voice, for: provider)
  }

  func setKey(_ key: String?, for provider: VoiceProviderKind) async throws {
    let name = Self.secretName(provider)
    if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try await secrets.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: name)
    } else {
      try await secrets.delete(name)
    }
    await refreshKeys()
    await publish()
  }

  func talk() async {
    let host = self.host
    let factory: @Sendable () async -> any RealtimeSocket = { DesktopRealtimeSocket(host: host) }
    let connected: any VoiceProvider =
      switch provider {
      case .openai:
        OpenAIRealtimeProvider(
          secrets: secrets,
          configuration: OpenAIRealtimeConfiguration(
            voice: voice, instructions: VoiceSupervisor.instructions),
          socketFactory: factory)
      case .xai:
        XAIRealtimeProvider(
          secrets: secrets,
          configuration: XAIRealtimeConfiguration(
            voice: voice, instructions: VoiceSupervisor.instructions, reasoningEffort: "none"),
          socketFactory: factory)
      }
    lastContext = nil
    await session.connect(provider: connected, microphoneEnabled: true)
    snapshot = await session.snapshot()
    await syncContext()
  }

  func sleep() async {
    await session.sleep()
    snapshot = await session.snapshot()
  }

  func interrupt() async {
    await session.interrupt()
    snapshot = await session.snapshot()
  }

  private func syncContext() async {
    let canvas = store.activeCanvas
    let context = services.voiceContext(
      snapshot: store.snapshot, canvas: canvas, workspacePath: workspacePath,
      knownWorkspaces: [workspacePath])
    guard context != lastContext else { return }
    lastContext = context
    await session.updateContext(context)
  }

  private func refreshKeys() async {
    for kind in [VoiceProviderKind.openai, .xai] {
      let value = try? await secrets.value(for: Self.secretName(kind))
      keys[kind.rawValue] = (value ?? nil).map { !$0.isEmpty } ?? false
    }
  }

  private func publish() async {
    await host.send("voice.state", status())
  }

  static func secretName(_ provider: VoiceProviderKind) -> String {
    switch provider {
    case .openai: "openai.api-key"
    case .xai: "xai.api-key"
    }
  }
}

// MARK: - Google sign-in, through the desktop

/// Google sign-in for Gmail and Calendar: Otto Desktop listens on 127.0.0.1 and opens the
/// person's browser; the engine keeps the PKCE secret and checks the callback (as on the Mac).
struct DesktopLoopbackBroker: LoopbackSignInBroker {
  private struct Port: Codable, Sendable { var port: Int }
  private struct CallbackParams: Encodable, Sendable {
    var url: String
    var state: String
    var port: Int
    var timeoutSeconds: Int
  }
  private struct Callback: Decodable { var request: String }

  let host: DesktopHost

  func listen() async throws -> Int {
    try await host.call("oauth.listen", [String: String](), as: Port.self).port
  }

  func callback(opening url: URL, state: String, port: Int, timeout: Duration) async throws
    -> String
  {
    let seconds = Int(timeout.components.seconds)
    return try await host.call(
      "oauth.callback",
      CallbackParams(url: url.absoluteString, state: state, port: port, timeoutSeconds: seconds),
      as: Callback.self, timeout: timeout + .seconds(10)
    ).request
  }
}

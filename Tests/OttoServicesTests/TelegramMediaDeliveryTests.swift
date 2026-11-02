import CryptoKit
import Foundation
import OttoCore
import OttoModels
import OttoRuntime
import OttoSecurity
import Testing

@testable import OttoServices

/// Drives the real connector against a stand-in for Telegram's Bot API: an album with a photo
/// and a video from the paired chat must reach the allowed bot as one prompt, with the files in
/// Otto's workspace, while media from anyone else is never downloaded.
@MainActor
@Suite("Telegram media reaches the bot", .serialized)
struct TelegramMediaDeliveryTests {
  @Test("An album from the paired chat arrives as one prompt; a stranger's photo is ignored")
  func albumReachesBot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "tg-e2e-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let video = root.appending(path: "fixture.mp4")
    try await TelegramMediaTests.writeVideo(to: video, seconds: 4)
    let videoBytes = try Data(contentsOf: video)

    let services = ApplicationServices(store: CanvasStore(), workspacePath: root.path)
    await services.start()
    let bot = try services.createBot(BotCreationRequest(name: "Scout", responsibility: "Help"))
    try services.connectorAccess.setAllowed(true, profileID: bot.id, for: .telegram)
    // The bot's session is a plain shell tagged with the bot, so opening the bot reuses it and
    // the test runs on Macs without Codex or Claude Code, such as CI runners.
    let node = try #require(
      services.store.dispatch(.createNode(kind: .agent, at: WorldPoint(x: 0, y: 0)))
        .affectedNodeIDs.first)
    services.store.dispatch(
      .setAgentDefinition(
        id: node,
        definition: AgentDefinition(
          provider: .shell, workingDirectory: root.path, launchCommand: "/bin/sh",
          permissionMode: "workspaceWrite", profileID: bot.id)))
    _ = try services.botChannels.bindNode(profileID: bot.id, nodeID: node)
    _ = try await services.supervisor.spawn(
      provider: .shell,
      specification: ProcessLaunchSpec(
        executable: "/bin/sh",
        arguments: ["-c", "printf 'OTTO_STATUS:IDLE\\r\\n'; while IFS= read -r line; do :; done"],
        environment: ["NO_COLOR": "1"], workingDirectory: root.path), id: node)
    try await waitUntil { try await services.supervisor.snapshot(agentID: node).state == .idle }

    let suite = "TelegramMediaDelivery-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let hash = SHA256.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }
      .joined().prefix(24)
    defaults.set(NSNumber(value: 123), forKey: "otto.telegram.\(hash).chat")

    let api = FakeBotAPI(videoBytes: videoBytes)
    FakeBotAPI.current = api
    URLProtocol.registerClass(FakeBotAPIProtocol.self)
    defer {
      URLProtocol.unregisterClass(FakeBotAPIProtocol.self)
      FakeBotAPI.current = nil
    }

    let connector = TelegramConnector(
      services: services, secrets: InMemorySecretStore(), defaults: defaults)
    await connector.connect(token: "123456:abcdefghijklmnopqrstuvwxyz")
    #expect(connector.username == "ottotestbot")

    func prompt() async -> String? {
      guard let snapshot = try? await services.supervisor.snapshot(agentID: node) else {
        return nil
      }
      return snapshot.transcript.last {
        $0.role == .user && $0.text.contains("[The user attached")
      }?
      .text
    }
    try await waitUntil(
      timeout: .seconds(60),
      describe: "status: \(connector.status); files: \(api.fileRequests); sent: \(api.sentMessages)"
    ) {
      await prompt() != nil && api.sentMessages.contains { $0.hasPrefix("Sent to @") }
    }
    connector.stop()

    let prompt = try #require(await prompt())
    #expect(prompt.hasPrefix("compare these"))
    #expect(prompt.contains("The video (4 s) is saved at "))
    #expect(prompt.contains("4 still frames from it are attached below."))
    // One photo plus four stills from the video, all in Otto's workspace.
    #expect(prompt.contains("[The user attached 5 images."))
    let directory = TelegramMediaStore.directory(workspacePath: root.path)
    let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(kept.filter { $0.hasSuffix(".mp4") }.count == 1)
    #expect(kept.filter { $0.hasSuffix(".jpg") }.count == 5)
    #expect(prompt.contains(directory.path))

    // The stranger's photo was never fetched: only the album's two files were.
    #expect(api.fileRequests.sorted() == ["photos/album.jpg", "videos/album.mp4"])
    await services.shutdown()
  }

  private func waitUntil(
    timeout: Duration = .seconds(15), describe: @autoclosure () -> String = "",
    _ condition: @MainActor () async throws -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for Telegram media to reach the bot. \(describe())")
  }
}

/// Answers the handful of Bot API calls the connector makes. Updates are served once.
private final class FakeBotAPI: @unchecked Sendable {
  nonisolated(unsafe) static var current: FakeBotAPI?
  private let lock = NSLock()
  private let videoBytes: Data
  private var served = false
  private var _fileRequests: [String] = []
  private var _sentMessages: [String] = []

  init(videoBytes: Data) { self.videoBytes = videoBytes }

  var fileRequests: [String] { lock.withLock { _fileRequests } }
  var hasServed: Bool { lock.withLock { served } }
  var sentMessages: [String] { lock.withLock { _sentMessages } }

  func respond(to request: URLRequest) -> Data {
    let path = request.url?.path ?? ""
    let method = path.split(separator: "/").last.map(String.init) ?? ""
    if path.hasPrefix("/file/") {
      let file = path.split(separator: "/").suffix(2).joined(separator: "/")
      lock.withLock { _fileRequests.append(file) }
      return file.hasSuffix(".mp4") ? videoBytes : Data([0xFF, 0xD8, 0xFF, 0xD9])
    }
    let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
    let arguments = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    switch method {
    case "getMe":
      return Data(#"{"ok":true,"result":{"username":"ottotestbot"}}"#.utf8)
    case "getUpdates":
      let first = lock.withLock {
        defer { served = true }
        return !served
      }
      return Data((first ? Self.updates : #"{"ok":true,"result":[]}"#).utf8)
    case "getFile":
      let id = arguments["file_id"] as? String ?? ""
      let path = id == "video" ? "videos/album.mp4" : id == "photo" ? "photos/album.jpg" : "x/y.jpg"
      return Data(#"{"ok":true,"result":{"file_path":"\#(path)","file_size":1000}}"#.utf8)
    case "sendMessage":
      lock.withLock { _sentMessages.append(arguments["text"] as? String ?? "") }
      return Data(#"{"ok":true,"result":{"message_id":99}}"#.utf8)
    default:
      return Data(#"{"ok":true,"result":true}"#.utf8)
    }
  }

  private static func read(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }

  /// A stranger's photo first, then the paired person's two-item album with its caption on the
  /// second item, as Telegram sometimes sends it.
  static let updates = """
    {"ok":true,"result":[
      {"update_id":1,"message":{"message_id":10,"chat":{"id":555,"type":"private"},
        "from":{"id":555,"is_bot":false},
        "photo":[{"file_id":"stranger","file_unique_id":"s","width":10,"height":10,"file_size":4}]}},
      {"update_id":2,"message":{"message_id":11,"chat":{"id":123,"type":"private"},
        "from":{"id":123,"is_bot":false},"media_group_id":"g1",
        "photo":[{"file_id":"photo","file_unique_id":"p","width":800,"height":600,"file_size":4}]}},
      {"update_id":3,"message":{"message_id":12,"chat":{"id":123,"type":"private"},
        "from":{"id":123,"is_bot":false},"media_group_id":"g1","caption":"compare these",
        "video":{"file_id":"video","file_unique_id":"v","duration":4,"file_size":1000}}}
    ]}
    """
}

private final class FakeBotAPIProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "api.telegram.org" && FakeBotAPI.current != nil
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // Telegram holds an empty long poll open; answering at once would spin the poll loop.
    if request.url?.path.hasSuffix("/getUpdates") == true, FakeBotAPI.current?.hasServed == true {
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in respond() }
      return
    }
    respond()
  }

  private func respond() {
    guard let api = FakeBotAPI.current, let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let data = api.respond(to: request)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

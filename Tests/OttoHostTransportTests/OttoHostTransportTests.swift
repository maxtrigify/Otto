import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import OttoHostRuntime
import OttoHostTransport
import OttoModels
import OttoRPCContracts
import Testing

@Suite("Otto mobile host transport")
struct OttoHostTransportTests {
  @Test("Private login bypasses RPC journals and rejects legacy or unscoped callers")
  func secureLoginTransport() async throws {
    let fixture = try TransportFixture()
    defer { fixture.cleanup() }
    let source = TransportDataSource(environment: fixture.environment, thread: fixture.thread)
    let journal = try RunEventJournal(directory: fixture.events)
    let host = OttoHostRuntime(dataSource: source, journal: journal)
    let pairing = SecureInputPairing(deviceID: fixture.deviceID)
    let app = try OttoHostHTTPApplication.make(
      host: host,
      configuration: OttoHostTransportConfiguration(token: fixture.token), pairing: pairing,
      applicationConfiguration: .init(address: .hostname("127.0.0.1", port: 0)))
    let payload = try JSONEncoder().encode(
      SecureLoginInput(action: .fill, value: "SYNTHETIC-NATIVE-INPUT"))
    try await app.test(.live) { client in
      for token in ["paired-secure-fixture", fixture.token] {
        try await client.execute(
          uri: "/v1/secure-login", method: .post,
          headers: [
            .authorization: "Bearer " + token,
            .init("X-Muse-Device-ID")!: fixture.deviceID.uuidString,
            .contentType: "application/json",
          ],
          body: ByteBuffer(bytes: payload)
        ) { response in
          #expect(response.status != .ok)
          #expect(
            !String(decoding: response.body.readableBytesView, as: UTF8.self).contains(
              "SYNTHETIC-NATIVE-INPUT"))
        }
      }
      try await client.execute(
        uri: "/v1/secure-login", method: .post,
        headers: [
          .authorization: "Bearer paired-secure-fixture",
          .init("X-Muse-Device-ID")!: fixture.deviceID.uuidString, .contentType: "application/json",
        ],
        body: ByteBuffer(bytes: try JSONEncoder().encode(SecureLoginInput(action: .list)))
      ) { response in
        #expect(response.status == .ok)
      }
    }
    #expect(await journal.latestSequence(threadID: fixture.thread.id) == 0)
    await #expect(throws: (any Error).self) {
      try await host.secureLogin(
        SecureLoginInput(action: .list),
        client: OttoHostClientContext(deviceID: fixture.deviceID, scopes: [.approvalRespond]))
    }
  }

  @Test("Transport fails closed for weak tokens, implicit LAN, and plaintext LAN")
  func configurationBoundaries() throws {
    #expect(throws: OttoHostTransportError.weakToken) {
      try OttoHostTransportConfiguration(token: "short")
    }
    #expect(throws: OttoHostTransportError.lanDisabled) {
      try OttoHostTransportConfiguration(
        hostname: "0.0.0.0", token: String(repeating: "a", count: 32))
    }
    #expect(throws: OttoHostTransportError.tlsRequiredForLAN) {
      try OttoHostTransportConfiguration(
        hostname: "0.0.0.0",
        allowLAN: true,
        token: String(repeating: "a", count: 32)
      )
    }
    let loopback = try OttoHostTransportConfiguration(
      token: String(repeating: "a", count: 32)
    )
    #expect(try loopback.advertisedBaseURL().absoluteString == "http://127.0.0.1:7338/")
    #expect(
      try loopback.advertisedBaseURL(override: "https://studio.tailnet.ts.net").absoluteString
        == "https://studio.tailnet.ts.net/"
    )
    #expect(throws: OttoHostTransportError.insecureAdvertisedURL) {
      try loopback.advertisedBaseURL(override: "http://192.168.0.88:7338/")
    }
  }

  @Test("Authenticated HTTP RPC and WebSocket replay share the canonical cursor")
  func rpcAndWebSocket() async throws {
    let fixture = try TransportFixture()
    defer { fixture.cleanup() }
    let source = TransportDataSource(environment: fixture.environment, thread: fixture.thread)
    let journal = try RunEventJournal(directory: fixture.events)
    let host = OttoHostRuntime(dataSource: source, journal: journal)
    let event = try await host.publish(
      RunEventDraft(
        threadID: fixture.thread.id,
        kind: .runCompleted,
        content: RunEventContent(state: .done, notification: .completion)
      ))
    let configuration = try OttoHostTransportConfiguration(
      hostname: "127.0.0.1",
      port: 7338,
      token: fixture.token
    )
    let app = try OttoHostHTTPApplication.make(
      host: host,
      configuration: configuration,
      applicationConfiguration: .init(address: .hostname("127.0.0.1", port: 0))
    )
    let authorization = "Bearer \(fixture.token)"
    try await app.test(.live) { client in
      let request = OttoRPCRequest(method: .threadList)
      try await client.execute(
        uri: "/v1/rpc",
        method: .post,
        headers: [
          .authorization: authorization,
          .init("X-Muse-Device-ID")!: fixture.deviceID.uuidString,
          .contentType: "application/json",
        ],
        body: ByteBuffer(bytes: try OttoRPCCodec.encoder.encode(request))
      ) { response in
        #expect(response.status == .ok)
        let rpc = try OttoRPCCodec.decoder.decode(
          OttoRPCResponse.self,
          from: Data(response.body.readableBytesView)
        )
        let output = try rpc.decodeResult(ThreadListOutput.self)
        #expect(output.threads.map(\.id) == [fixture.thread.id])
      }

      try await client.ws(
        "/v1/events?thread_id=\(fixture.thread.id.uuidString)&after=0",
        configuration: .init(additionalHeaders: [
          .authorization: authorization,
          .init("X-Muse-Device-ID")!: fixture.deviceID.uuidString,
        ])
      ) { inbound, _, _ in
        let message = try await inbound.messages(maxSize: .max).first { _ in true }
        guard case .text(let text) = message else {
          Issue.record("Expected a text event")
          return
        }
        #expect(try OttoRPCCodec.decoder.decode(RunEvent.self, from: Data(text.utf8)) == event)
      }
    }
  }

  @Test("Single-use exchange issues a device credential accepted by the RPC boundary")
  func pairedDeviceAuthentication() async throws {
    let fixture = try TransportFixture()
    defer { fixture.cleanup() }
    let source = TransportDataSource(environment: fixture.environment, thread: fixture.thread)
    let host = OttoHostRuntime(
      dataSource: source,
      journal: try RunEventJournal(directory: fixture.events)
    )
    let pairing = TestPairingHandler(
      environment: fixture.environment,
      baseURL: try #require(URL(string: "https://test-mac.example/"))
    )
    let app = try OttoHostHTTPApplication.make(
      host: host,
      configuration: try OttoHostTransportConfiguration(token: fixture.token),
      pairing: pairing,
      applicationConfiguration: .init(address: .hostname("127.0.0.1", port: 0))
    )
    let offer = pairing.payload
    let exchange = OttoMobilePairingExchangeInput(
      offerID: offer.offerID,
      code: offer.code,
      deviceName: "Max's iPhone",
      devicePublicKey: "device-public-key"
    )

    try await app.test(.live) { client in
      var output: OttoMobilePairingExchangeOutput?
      try await client.execute(
        uri: "/v1/pairing/exchange",
        method: .post,
        headers: [.contentType: "application/json"],
        body: ByteBuffer(bytes: try OttoRPCCodec.encoder.encode(exchange))
      ) { response in
        #expect(response.status == .ok)
        output = try OttoRPCCodec.decoder.decode(
          OttoMobilePairingExchangeOutput.self,
          from: Data(response.body.readableBytesView)
        )
      }
      let paired = try #require(output)
      let request = OttoRPCRequest(method: .threadList)
      try await client.execute(
        uri: "/v1/rpc",
        method: .post,
        headers: [
          .authorization: "Bearer \(paired.credential)",
          .init("X-Muse-Device-ID")!: paired.deviceID.uuidString,
          .contentType: "application/json",
        ],
        body: ByteBuffer(bytes: try OttoRPCCodec.encoder.encode(request))
      ) { response in
        #expect(response.status == .ok)
        let rpc = try OttoRPCCodec.decoder.decode(
          OttoRPCResponse.self,
          from: Data(response.body.readableBytesView)
        )
        #expect(
          try rpc.decodeResult(ThreadListOutput.self).threads.map(\.id) == [fixture.thread.id])
      }

      try await client.execute(
        uri: "/v1/rpc",
        method: .post,
        headers: [
          .authorization: "Bearer wrong-credential",
          .init("X-Muse-Device-ID")!: paired.deviceID.uuidString,
          .contentType: "application/json",
        ],
        body: ByteBuffer(bytes: try OttoRPCCodec.encoder.encode(request))
      ) { response in
        #expect(response.status == .unauthorized)
      }
    }
  }
}

private enum TestPairingError: Error { case rejected }

private actor TestPairingHandler: OttoHostPairingHandling {
  let payload: OttoMobilePairingPayload
  private let credential = "paired-device-credential"
  private let deviceID = UUID()
  private var consumed = false

  init(environment: ExecutionEnvironment, baseURL: URL) {
    payload = OttoMobilePairingPayload(
      offerID: UUID(),
      environmentID: environment.id,
      environmentName: environment.name,
      fingerprint: String(repeating: "f", count: 64),
      baseURL: baseURL,
      code: "482091",
      expiresAt: .now.addingTimeInterval(300),
      scopes: [.environmentRead, .threadRead, .messageWrite, .runControl]
    )
  }

  func exchange(
    _ input: OttoMobilePairingExchangeInput
  ) throws -> OttoMobilePairingExchangeOutput {
    guard !consumed, input.offerID == payload.offerID, input.code == payload.code,
      !input.deviceName.isEmpty, !input.devicePublicKey.isEmpty
    else { throw TestPairingError.rejected }
    consumed = true
    return OttoMobilePairingExchangeOutput(
      deviceID: deviceID,
      credential: credential,
      environmentID: payload.environmentID,
      environmentName: payload.environmentName,
      baseURL: payload.baseURL,
      fingerprint: payload.fingerprint,
      scopes: payload.scopes
    )
  }

  func authenticate(
    deviceID: UUID,
    credential: String,
    requiredScope: OttoRPCScope
  ) throws -> OttoHostClientContext {
    guard deviceID == self.deviceID, credential == self.credential,
      payload.scopes.contains(requiredScope)
    else { throw TestPairingError.rejected }
    return OttoHostClientContext(deviceID: deviceID, scopes: payload.scopes)
  }
}

private actor TransportDataSource: OttoHostDataSource {
  let hostEnvironment: ExecutionEnvironment
  let thread: OttoModels.Thread

  init(environment: ExecutionEnvironment, thread: OttoModels.Thread) {
    hostEnvironment = environment
    self.thread = thread
  }

  func secureLogin(_ input: SecureLoginInput, deviceID: UUID) async throws -> SecureLoginOutput {
    if input.action == .fill { throw NSError(domain: input.value ?? "", code: 1) }
    return SecureLoginOutput(message: "No requests")
  }
  func environment() async -> ExecutionEnvironment { hostEnvironment }
  func listThreads() async throws -> [OttoModels.Thread] { [thread] }
  func snapshot(threadID _: UUID) async throws -> ThreadSnapshot {
    ThreadSnapshot(thread: thread, messages: [], lastEventSequence: 0)
  }
  func sendMessage(threadID _: UUID, body: String) async throws -> ThreadMessage {
    ThreadMessage(role: .user, text: body)
  }
  func interrupt(threadID _: UUID, runID _: UUID) async throws {}
  func stop(threadID _: UUID, runID _: UUID) async throws {}
}

private struct TransportFixture {
  let root: URL
  let events: URL
  let token = String(repeating: "m", count: 48)
  let deviceID = UUID()
  let environment: ExecutionEnvironment
  let thread: OttoModels.Thread

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "otto-host-transport-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    events = root.appending(path: "events", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let environmentID = UUID()
    environment = ExecutionEnvironment(
      id: environmentID,
      name: "Test Mac",
      kind: .macHost,
      status: .online,
      capabilities: [.conversations],
      protocolVersion: OttoRPCProtocol.currentVersion
    )
    thread = OttoModels.Thread(
      id: UUID(),
      kind: .botChannel,
      title: "Ada",
      botProfileIDs: [UUID()],
      executionEnvironmentID: environmentID
    )
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct SecureInputPairing: OttoHostPairingHandling {
  let deviceID: UUID
  func exchange(_ input: OttoMobilePairingExchangeInput) async throws
    -> OttoMobilePairingExchangeOutput
  { throw TestPairingError.rejected }
  func authenticate(deviceID: UUID, credential: String, requiredScope: OttoRPCScope) async throws
    -> OttoHostClientContext
  {
    guard deviceID == self.deviceID, credential == "paired-secure-fixture",
      requiredScope == .secureLogin
    else { throw TestPairingError.rejected }
    return OttoHostClientContext(deviceID: deviceID, scopes: [.secureLogin])
  }
}

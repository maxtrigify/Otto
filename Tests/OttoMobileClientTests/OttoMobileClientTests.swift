import AppKit
import CryptoKit
import Foundation
import OttoCommercial
import OttoMobileClient
import OttoModels
import OttoRPCContracts
import SwiftUI
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Otto mobile client")
struct OttoMobileClientTests {
  @Test("Private input rejects insecure remote transport and unsupported connections")
  func privateInputTransportBoundary() async throws {
    let connection = OttoMobileConnection(
      configuration: OttoMobileConnectionConfiguration(
        baseURL: URL(string: "http://example.invalid")!, token: "synthetic", deviceID: UUID()))
    await #expect(throws: OttoMobileConnectionError.invalidURL) {
      try await connection.secureLogin(SecureLoginInput(action: .fill, value: "synthetic"))
    }
    await #expect(throws: OttoMobileConnectionError.privateInputUnsupported) {
      try await OfflineMobileConnection().secureLogin(SecureLoginInput(action: .list))
    }
  }

  @MainActor
  @Test(
    "A home refresh removes deleted entries, closes their conversation and updates the offline cache"
  )
  func deletedEntriesSync() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = OttoMobileDiskCache(directory: root)
    let store = OttoMobileStore(connection: connection, cache: cache)
    await store.start()
    await store.open(fixture.thread)
    let sync = Task { await store.syncHome() }
    defer { sync.cancel() }
    await connection.deleteRosterEntries()
    for _ in 0..<100 where !store.threads.isEmpty {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(store.threads.isEmpty && store.bots.isEmpty)
    #expect(store.selectedThread == nil && store.messages.isEmpty)
    #expect(store.connectionState == .live)
    let offline = OttoMobileStore(connection: OfflineMobileConnection(), cache: cache)
    await offline.start()
    #expect(offline.threads.isEmpty && offline.bots.isEmpty)
  }

  @MainActor @Test("A partial refresh failure does not treat unavailable roster data as deletion")
  func failedRosterRefreshPreservesHome() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OttoMobileStore(connection: connection, cache: OttoMobileDiskCache(directory: root))
    await store.start()
    await connection.deleteRosterEntries()
    await connection.failRosterRefresh()
    await store.refreshHome()
    #expect(store.threads == [fixture.thread] && store.bots == [fixture.bot])
    if case .offline = store.connectionState {} else { Issue.record("Expected offline state") }
  }

  @MainActor @Test("The actual mobile scene renders a persistent send failure")
  func sendFailureVisualFixture() throws {
    let fixture = MobileClientFixture()
    let view = OttoMobileThreadScene(
      thread: fixture.thread, messages: [], connectionState: .live,
      draft: .constant("Please check this"), isSending: false,
      sendError:
        "The earlier message could not be confirmed. Check the conversation before sending again.",
      sendMayHaveBeenAccepted: true, send: {}
    )
    .frame(width: 390, height: 844)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/otto-mobile-send-error.png"), options: .atomic)
  }

  @MainActor @Test("A send rejection stays visible while synchronization remains live")
  func persistentSendError() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.open(fixture.thread)
    await connection.failNextSend()
    store.composerText = "Keep this draft"
    await store.sendComposer()
    #expect(store.composerText == "Keep this draft")
    #expect(store.sendError != nil)
    #expect(!store.isSending)
    for _ in 0..<100 where !(await connection.hasSubscriber()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.connectionState == .live)
    #expect(store.sendError != nil)
    await store.sendComposer()
    #expect(store.sendError == nil)
    #expect(store.composerText.isEmpty)
    store.closeThread()
  }

  @MainActor @Test("An uncertain send keeps its ID unless the user explicitly sends a new copy")
  func explicitNewSendAfterUncertainty() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = OttoMobileStore(connection: connection, cache: OttoMobileDiskCache(directory: root))
    await store.open(fixture.thread)
    store.composerText = "A new test message"
    await connection.makeNextSendUncertain()
    await store.sendComposer()
    #expect(store.sendMayHaveBeenAccepted)
    await connection.makeNextSendUncertain()
    await store.sendComposer()
    let retries = await connection.sentIDs
    #expect(retries.count == 2 && retries[0] == retries[1])
    await store.sendComposer(asNewMessage: true)
    let sent = await connection.sentIDs
    #expect(sent.count == 3 && sent[2] != sent[1])
    #expect(store.sendError == nil)
    #expect(!store.sendMayHaveBeenAccepted)
    store.closeThread()
  }

  @MainActor @Test("Ambiguous sends retain their command ID across a client restart")
  func durableSendRetry() async throws {
    let fixture = MobileClientFixture()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = OttoMobileDiskCache(directory: root)
    let connection = FakeMobileConnection(fixture: fixture)
    await connection.failNextSend()
    let first = OttoMobileStore(connection: connection, cache: cache)
    await first.open(fixture.thread)
    first.composerText = "Continue the review"
    await first.sendComposer()
    #expect(first.composerText == "Continue the review")
    let pending = try #require(await cache.pendingMessage(threadID: fixture.thread.id))
    first.closeThread()
    let second = OttoMobileStore(
      connection: connection, cache: OttoMobileDiskCache(directory: root))
    await second.open(fixture.thread)
    #expect(second.composerText == "Continue the review")
    await second.sendComposer()
    #expect(await connection.sentIDs == [pending.clientMessageID, pending.clientMessageID])
    #expect(second.composerText.isEmpty)
    second.closeThread()
  }

  @MainActor @Test("Accepted sends are not restored as drafts after refresh failure")
  func acceptedSendRefreshFailure() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    await connection.failEventRefresh()
    let store = OttoMobileStore(connection: connection)
    await store.open(fixture.thread)
    store.composerText = "Accepted work"
    await store.sendComposer()
    #expect(store.composerText.isEmpty)
    store.closeThread()
  }

  @MainActor @Test("Snapshot then stream applies stable event IDs only once")
  func reconnectProjection() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    await store.open(fixture.thread)
    for _ in 0..<100 where !(await connection.hasSubscriber()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let message = ThreadMessage(
      role: .assistant,
      text: "The host boundary is live.",
      author: RunEventAuthor(role: .assistant, displayName: "Ada"),
      createdAt: fixture.timestamp
    )
    let event = RunEvent(
      threadID: fixture.thread.id,
      sequence: 1,
      timestamp: fixture.timestamp,
      kind: .messageAdded,
      content: RunEventContent(message: message)
    )
    await connection.emit(event)
    await connection.emit(event)
    for _ in 0..<100 where store.messages.count != 1 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.messages == [message])
  }

  @MainActor @Test("Observed runs can be interrupted and stopped with their exact run ID")
  func runControls() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    await store.open(fixture.thread)
    for _ in 0..<100 where !(await connection.hasSubscriber()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let runID = UUID()
    await connection.emit(
      RunEvent(
        threadID: fixture.thread.id,
        sequence: 1,
        kind: .runStarted,
        content: RunEventContent(runID: runID, state: .working)
      ))
    for _ in 0..<100 where store.activeRunID == nil {
      try await Task.sleep(for: .milliseconds(5))
    }

    await store.interruptActiveRun()
    await store.stopActiveRun()

    #expect(
      await connection.controls() == [
        .init(method: .runInterrupt, threadID: fixture.thread.id, runID: runID),
        .init(method: .runStop, threadID: fixture.thread.id, runID: runID),
      ])
  }

  @MainActor @Test("Approval cards respond online with the exact request and are never queued")
  func approvalResponse() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    await store.open(fixture.thread)
    for _ in 0..<100 where !(await connection.hasSubscriber()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let request = MobileApprovalRequest(
      requestID: UUID(),
      threadID: fixture.thread.id,
      runID: UUID(),
      reason: "Bash: publish the release tag",
      nonce: UUID().uuidString,
      requestedAt: fixture.timestamp
    )
    await connection.emit(
      RunEvent(
        threadID: fixture.thread.id,
        sequence: 1,
        kind: .approvalRequested,
        content: RunEventContent(
          runID: request.runID,
          state: .approvalRequired,
          approval: request,
          notification: .approval
        )
      ))
    for _ in 0..<100 where store.pendingApproval == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.pendingApproval == request)

    await store.respondToPendingApproval(.approveOnce)

    #expect(store.pendingApproval == nil)
    #expect(
      await connection.approvalInputs() == [
        ApprovalRespondInput(
          threadID: request.threadID,
          requestID: request.requestID,
          nonce: request.nonce,
          decision: .approveOnce
        )
      ])
  }

  @MainActor @Test("Text attachments upload in chunks and download to a shareable local file")
  func attachmentRoundTrip() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    await store.open(fixture.thread)

    await store.uploadTextAttachment(
      displayName: "Train notes",
      body: "Review the relay reconnect evidence."
    )

    let attachment = try #require(store.attachments.first)
    #expect(attachment.displayName == "Train notes.txt")
    #expect(store.attachmentTransferMessage == "Attached Train notes.txt")
    #expect(await connection.uploadedBytes() == Data("Review the relay reconnect evidence.".utf8))

    await store.downloadAttachment(attachment)

    #expect(store.downloadedAttachmentID == attachment.id)
    let downloaded = try #require(store.downloadedAttachmentURL)
    #expect(try Data(contentsOf: downloaded) == Data("Review the relay reconnect evidence.".utf8))
    #expect(store.attachmentTransferMessage == "Downloaded Train notes.txt")
  }

  @MainActor @Test("Attachment downloads fail closed when the host digest does not match")
  func attachmentDownloadRejectsDigestMismatch() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    await store.open(fixture.thread)
    await store.uploadTextAttachment(displayName: "Tamper check", body: "trusted bytes")
    let attachment = try #require(store.attachments.first)

    await connection.setCorruptDownloadDigest(true)
    await store.downloadAttachment(attachment)

    #expect(store.downloadedAttachmentID == nil)
    #expect(store.downloadedAttachmentURL == nil)
  }

  @MainActor @Test("Mac health is privacy validated and support export requires explicit consent")
  func diagnosticsConsentAndExport() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)

    await store.loadDiagnostics()
    let diagnostics = try #require(store.diagnostics)
    #expect(diagnostics.previousSessionAbnormal)
    #expect(diagnostics.toolSuccessCount == 3)

    await store.prepareDiagnosticExport(consent: false)
    #expect(store.diagnosticExportURL == nil)
    #expect(store.diagnosticsMessage?.contains("Agree") == true)

    await store.prepareDiagnosticExport(consent: true)
    let url = try #require(store.diagnosticExportURL)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let exported = try decoder.decode(MobileDiagnosticsSupportReport.self, from: data)
    #expect(exported.eventCounts == diagnostics.eventCounts)
    let text = String(decoding: data, as: UTF8.self)
    for forbidden in [
      "recentEvents", "prompt", "/Users/", "secret.swift", "https://", "transcript",
    ] {
      #expect(!text.contains(forbidden))
    }
  }

  @MainActor @Test("Mac health rejects values outside the privacy allowlist")
  func diagnosticsRejectUnsafeSnapshot() async {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    await connection.setUnsafeDiagnostics(true)
    let store = OttoMobileStore(connection: connection)

    await store.loadDiagnostics()

    #expect(store.diagnostics == nil)
    #expect(store.diagnosticsMessage?.contains("privacy allowlist") == true)
  }

  @MainActor @Test("Notification-classified events emit one deep-linkable delivery intent")
  func notificationIntent() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let notifications = RecordingNotificationDelivery()
    let store = OttoMobileStore(connection: connection, notifications: notifications)
    await store.start()
    await store.open(fixture.thread)
    for _ in 0..<100 where !(await connection.hasSubscriber()) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let event = RunEvent(
      threadID: fixture.thread.id,
      sequence: 1,
      kind: .runCompleted,
      content: RunEventContent(
        state: .done,
        detail: "The field report is ready.",
        notification: .completion
      )
    )
    await connection.emit(event)
    await connection.emit(event)
    for _ in 0..<100 where await notifications.values().isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(
      await notifications.values() == [
        OttoMobileNotificationDelivery(
          eventID: event.id,
          threadID: fixture.thread.id,
          kind: .completion,
          title: "Ada finished",
          body: "The field report is ready."
        )
      ])
  }

  @MainActor @Test("Bot roster starts its canonical session and opens the thread")
  func startsBotSession() async throws {
    let fixture = MobileClientFixture()
    let connection = FakeMobileConnection(fixture: fixture)
    let store = OttoMobileStore(connection: connection)
    await store.start()
    #expect(store.bots == [fixture.bot])

    await store.start(fixture.bot)

    #expect(store.selectedThread?.id == fixture.thread.id)
    #expect(store.bots.first?.hasSession == true)
    #expect(await connection.startedBotIDs() == [fixture.bot.id])
  }

  @MainActor @Test("Cold offline launch restores cached home and thread without claiming live")
  func offlineColdLaunch() async throws {
    let fixture = MobileClientFixture()
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-client-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    var cache = OttoMobileDiskCache(directory: root)
    try await cache.replace(
      home: OttoMobileCachedHome(
        environment: fixture.environment,
        threads: [fixture.thread],
        bots: [fixture.bot],
        teams: [],
        savedAt: fixture.timestamp
      ))
    let message = ThreadMessage(
      role: .assistant,
      text: "Cached result",
      author: RunEventAuthor(role: .assistant, displayName: "Ada"),
      createdAt: fixture.timestamp
    )
    try await cache.replace(
      thread: ThreadSnapshot(
        thread: fixture.thread,
        messages: [message],
        lastEventSequence: 4
      ))
    cache = OttoMobileDiskCache(directory: root)
    let store = OttoMobileStore(connection: OfflineMobileConnection(), cache: cache)

    await store.start()
    #expect(store.threads == [fixture.thread])
    #expect(store.bots == [fixture.bot])
    if case .offline = store.connectionState {} else { Issue.record("Expected offline state") }

    await store.open(fixture.thread)
    #expect(store.messages == [message])
    if case .offline = store.connectionState {} else { Issue.record("Expected offline thread") }
  }

  @MainActor @Test("Thread scene renders at an iPhone-sized canvas")
  func visualFixture() throws {
    let fixture = MobileClientFixture()
    let messages = [
      ThreadMessage(
        role: .user,
        text: "Can you check the reconnect path?",
        createdAt: fixture.timestamp
      ),
      ThreadMessage(
        role: .activity,
        kind: .notice,
        text: "Read 3 files · reconnect cursor 42",
        createdAt: fixture.timestamp
      ),
      ThreadMessage(
        role: .assistant,
        text:
          "Yes. The phone catches up from the last confirmed sequence, then opens the live stream. Replayed event IDs are ignored.",
        author: RunEventAuthor(role: .assistant, displayName: "Ada"),
        createdAt: fixture.timestamp
      ),
    ]
    let view = OttoMobileThreadVisualFixture(
      thread: fixture.thread,
      messages: messages,
      connectionState: .live
    )
    .frame(width: 390, height: 844)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/otto-mobile-thread.png"), options: .atomic)
    #expect(png.count > 10_000)
  }
}

@Suite("Otto managed mobile pairing", .serialized)
struct OttoManagedMobilePairingClientTests {
  @Test("QR round trip and exchange save only a verified device-bound credential")
  func exchangeAndPersist() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let controlPlaneURL = try #require(URL(string: "https://relay.otto.test/"))
    let payload = try OttoManagedMobilePairingPayload(
      controlPlaneURL: controlPlaneURL,
      offerID: UUID(),
      secret: String(repeating: "s", count: 64),
      expiresAt: now.addingTimeInterval(300)
    )
    let qr = try payload.qrString()
    #expect(qr.hasPrefix("otto://remote?"))
    #expect(try OttoManagedMobilePairingPayload(qrString: qr) == payload)
    let legacy = "muse://" + qr.dropFirst("otto://".count)
    #expect(try OttoManagedMobilePairingPayload(qrString: legacy) == payload)
    #expect(!qr.contains(payload.secret))

    let accountID = UUID()
    let deviceID = UUID()
    let credential = String(repeating: "c", count: 64)
    ManagedPairingStubURLProtocol.handler = { request in
      switch request.url?.path {
      case "/v1/managed/pairing-offers/exchange":
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let input = try JSONDecoder.commercial.decode(
          ManagedPairingExchangeRequest.self,
          from: requestBody(request)
        )
        #expect(input.offerID == payload.offerID)
        #expect(input.secret == payload.secret)
        #expect(input.deviceName == "Test iPhone")
        #expect(Data(base64Encoded: input.devicePublicKey)?.count == 32)
        return (
          200,
          try JSONEncoder.commercial.encode(
            ManagedDeviceRegistration(
              device: ManagedRemoteDevice(
                id: deviceID,
                accountID: accountID,
                name: input.deviceName,
                kind: .iPhone,
                publicKey: input.devicePublicKey,
                createdAt: now
              ),
              credential: credential
            ))
        )
      case "/v1/managed/environments":
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential)")
        let url = try #require(request.url)
        let components = try #require(
          URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
          ))
        #expect(
          components.queryItems?.first(where: { $0.name == "device_id" })?.value
            == deviceID.uuidString)
        return (200, try JSONEncoder.commercial.encode([ManagedEnvironmentPresence]()))
      default:
        throw OttoManagedMobilePairingError.invalidResponse
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManagedPairingStubURLProtocol.self]
    let store = InMemoryManagedPairingRecordStore()
    let client = OttoManagedMobilePairingClient(
      session: URLSession(configuration: configuration),
      store: store
    )

    let record = try await client.pair(
      payload: payload,
      deviceName: "Test iPhone",
      now: now
    )

    #expect(record.accountID == accountID)
    #expect(record.deviceID == deviceID)
    #expect(record.credential == credential)
    #expect(record.devicePrivateKey.count == 32)
    #expect(await store.records() == [record])
  }

  @Test("Expired managed offer is rejected before network or Keychain access")
  func expiredOffer() async throws {
    let payload = try OttoManagedMobilePairingPayload(
      controlPlaneURL: try #require(URL(string: "https://relay.otto.test/")),
      offerID: UUID(),
      secret: String(repeating: "x", count: 64),
      expiresAt: Date(timeIntervalSince1970: 10)
    )
    ManagedPairingStubURLProtocol.handler = { _ in
      Issue.record("Expired pairing must not make a network request")
      return (500, Data())
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManagedPairingStubURLProtocol.self]
    let store = InMemoryManagedPairingRecordStore()
    let client = OttoManagedMobilePairingClient(
      session: URLSession(configuration: configuration),
      store: store
    )

    await #expect(throws: OttoManagedMobilePairingError.expired) {
      try await client.pair(
        payload: payload,
        deviceName: "Test iPhone",
        now: Date(timeIntervalSince1970: 11)
      )
    }
    #expect(await store.records().isEmpty)
  }

  @Test("Hosted subscription denial is actionable and never persists a device credential")
  func subscriptionRequired() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = try OttoManagedMobilePairingPayload(
      controlPlaneURL: try #require(URL(string: "https://relay.otto.test/")),
      offerID: UUID(),
      secret: String(repeating: "s", count: 64),
      expiresAt: now.addingTimeInterval(300)
    )
    ManagedPairingStubURLProtocol.handler = { request in
      #expect(request.url?.path == "/v1/managed/pairing-offers/exchange")
      return (402, Data())
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManagedPairingStubURLProtocol.self]
    let store = InMemoryManagedPairingRecordStore()
    let client = OttoManagedMobilePairingClient(
      session: URLSession(configuration: configuration),
      store: store
    )

    await #expect(throws: OttoManagedMobilePairingError.subscriptionRequired) {
      try await client.pair(payload: payload, deviceName: "Test iPhone", now: now)
    }
    #expect(await store.records().isEmpty)
  }
}

@Suite("Otto mobile pairing client", .serialized)
struct OttoMobilePairingClientTests {
  @Test("Exchange creates a device key and saves only a validated paired environment")
  func exchangeAndPersist() async throws {
    let environmentID = UUID()
    let offerID = UUID()
    let baseURL = try #require(URL(string: "https://paired-mac.example/"))
    let payload = OttoMobilePairingPayload(
      offerID: offerID,
      environmentID: environmentID,
      environmentName: "Paired Mac",
      fingerprint: String(repeating: "b", count: 64),
      baseURL: baseURL,
      code: "384201",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
      scopes: [.environmentRead, .threadRead, .messageWrite, .runControl]
    )
    let deviceID = UUID()
    PairingStubURLProtocol.handler = { request in
      switch request.url?.path {
      case "/v1/pairing/exchange":
        #expect(request.httpMethod == "POST")
        let input = try OttoRPCCodec.decoder.decode(
          OttoMobilePairingExchangeInput.self,
          from: requestBody(request)
        )
        #expect(input.offerID == offerID)
        #expect(input.code == payload.code)
        #expect(input.deviceName == "Test iPhone")
        #expect(Data(base64Encoded: input.devicePublicKey)?.count == 32)
        let output = OttoMobilePairingExchangeOutput(
          deviceID: deviceID,
          credential: String(repeating: "c", count: 64),
          environmentID: environmentID,
          environmentName: payload.environmentName,
          baseURL: baseURL,
          fingerprint: payload.fingerprint,
          scopes: payload.scopes
        )
        return (200, try OttoRPCCodec.encoder.encode(output))
      case "/v1/rpc":
        #expect(
          request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(String(repeating: "c", count: 64))")
        #expect(request.value(forHTTPHeaderField: "X-Muse-Device-ID") == deviceID.uuidString)
        let rpc = try OttoRPCCodec.decoder.decode(OttoRPCRequest.self, from: requestBody(request))
        #expect(rpc.method == .environmentGetCapabilities)
        let environment = ExecutionEnvironment(
          id: environmentID,
          name: payload.environmentName,
          kind: .macHost,
          status: .online,
          capabilities: [.conversations],
          protocolVersion: OttoRPCProtocol.currentVersion
        )
        let response = try OttoRPCResponse(
          id: rpc.id,
          result: EnvironmentCapabilitiesOutput(
            environment: environment,
            supportedProtocolVersions: [OttoRPCProtocol.currentVersion]
          )
        )
        return (200, try OttoRPCCodec.encoder.encode(response))
      default:
        throw OttoMobilePairingError.invalidResponse
      }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PairingStubURLProtocol.self]
    let recordStore = InMemoryPairingRecordStore()
    let client = OttoMobilePairingClient(
      session: URLSession(configuration: configuration),
      store: recordStore
    )

    let record = try await client.pair(
      payload: payload,
      deviceName: "Test iPhone",
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )

    #expect(record.environmentID == environmentID)
    #expect(record.deviceID == deviceID)
    #expect(record.devicePrivateKey.count == 32)
    #expect(record.connectionConfiguration.token == String(repeating: "c", count: 64))
    #expect(await recordStore.records() == [record])
  }

  @Test("Expired QR is rejected before making a network request")
  func expiredOffer() async throws {
    let store = InMemoryPairingRecordStore()
    let client = OttoMobilePairingClient(store: store)
    let payload = OttoMobilePairingPayload(
      offerID: UUID(),
      environmentID: UUID(),
      environmentName: "Expired Mac",
      fingerprint: String(repeating: "d", count: 64),
      baseURL: try #require(URL(string: "https://expired.example/")),
      code: "000000",
      expiresAt: Date(timeIntervalSince1970: 10),
      scopes: [.threadRead]
    )
    await #expect(throws: OttoMobilePairingError.expired) {
      try await client.pair(
        payload: payload,
        deviceName: "Test iPhone",
        now: Date(timeIntervalSince1970: 11)
      )
    }
    #expect(await store.records().isEmpty)
  }

  @Test("Plaintext non-loopback pairing is rejected before credential exchange")
  func insecureEndpoint() async throws {
    let store = InMemoryPairingRecordStore()
    let client = OttoMobilePairingClient(store: store)
    let payload = OttoMobilePairingPayload(
      offerID: UUID(),
      environmentID: UUID(),
      environmentName: "Unsafe Mac",
      fingerprint: String(repeating: "e", count: 64),
      baseURL: try #require(URL(string: "http://192.168.0.88:7338/")),
      code: "123456",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
      scopes: [.environmentRead]
    )
    await #expect(throws: OttoMobilePairingError.insecureEndpoint) {
      try await client.pair(
        payload: payload,
        deviceName: "Test iPhone",
        now: Date(timeIntervalSince1970: 1_800_000_000)
      )
    }
    #expect(await store.records().isEmpty)
  }

  @Test("Credential is not saved when the advertised authenticated endpoint fails verification")
  func failedEndpointVerification() async throws {
    let environmentID = UUID()
    let deviceID = UUID()
    let baseURL = try #require(URL(string: "https://unreachable-mac.example/"))
    let payload = OttoMobilePairingPayload(
      offerID: UUID(),
      environmentID: environmentID,
      environmentName: "Unreachable Mac",
      fingerprint: String(repeating: "f", count: 64),
      baseURL: baseURL,
      code: "654321",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
      scopes: [.environmentRead, .threadRead]
    )
    PairingStubURLProtocol.handler = { request in
      if request.url?.path == "/v1/rpc" { return (503, Data()) }
      let output = OttoMobilePairingExchangeOutput(
        deviceID: deviceID,
        credential: String(repeating: "g", count: 64),
        environmentID: environmentID,
        environmentName: payload.environmentName,
        baseURL: baseURL,
        fingerprint: payload.fingerprint,
        scopes: payload.scopes
      )
      return (200, try OttoRPCCodec.encoder.encode(output))
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PairingStubURLProtocol.self]
    let store = InMemoryPairingRecordStore()
    let client = OttoMobilePairingClient(
      session: URLSession(configuration: configuration),
      store: store
    )

    await #expect(throws: OttoMobilePairingError.hostVerificationFailed) {
      try await client.pair(
        payload: payload,
        deviceName: "Test iPhone",
        now: Date(timeIntervalSince1970: 1_800_000_000)
      )
    }
    #expect(await store.records().isEmpty)
  }
}

private actor InMemoryPairingRecordStore: OttoMobilePairingRecordStoring {
  private var values: [UUID: OttoMobilePairingRecord] = [:]

  func save(_ record: OttoMobilePairingRecord) {
    values[record.environmentID] = record
  }

  func records() -> [OttoMobilePairingRecord] {
    values.values.sorted { $0.pairedAt > $1.pairedAt }
  }

  func delete(environmentID: UUID) {
    values[environmentID] = nil
  }
}

private actor InMemoryManagedPairingRecordStore: OttoManagedMobileDeviceRecordStoring {
  private var values: [UUID: OttoManagedMobileDeviceRecord] = [:]

  func save(_ record: OttoManagedMobileDeviceRecord) {
    values[record.deviceID] = record
  }

  func records() -> [OttoManagedMobileDeviceRecord] {
    values.values.sorted { $0.registeredAt > $1.registeredAt }
  }

  func delete(deviceID: UUID) {
    values[deviceID] = nil
  }
}

private actor RecordingNotificationDelivery: OttoMobileNotificationDelivering {
  private var delivered: [OttoMobileNotificationDelivery] = []

  func deliver(_ notification: OttoMobileNotificationDelivery) {
    delivered.append(notification)
  }

  func values() -> [OttoMobileNotificationDelivery] { delivered }
}

private final class PairingStubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (status: Int, data: Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let result = try handler(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url,
          statusCode: result.status,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        )
      )
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private final class ManagedPairingStubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (status: Int, data: Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let result = try handler(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url,
          statusCode: result.status,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? OttoMobilePairingError.invalidResponse }
    if count == 0 { break }
    data.append(buffer, count: count)
  }
  return data
}

private actor FakeMobileConnection: OttoMobileConnecting {
  var rosterDeleted = false
  var rejectRoster = false
  func deleteRosterEntries() { rosterDeleted = true }
  func failRosterRefresh() { rejectRoster = true }
  struct Control: Equatable, Sendable {
    var method: OttoRPCMethod
    var threadID: UUID
    var runID: UUID
  }
  let fixture: MobileClientFixture
  var continuation: AsyncThrowingStream<RunEvent, Error>.Continuation?
  var recordedControls: [Control] = []
  var startedBots: [UUID] = []
  var approvals: [ApprovalRespondInput] = []
  var attachmentPrepare: AttachmentPrepareUploadInput?
  var attachmentUploadID: UUID?
  var attachmentBytes = Data()
  var uploadedAttachment: OttoAttachment?
  var corruptDownloadDigest = false
  var unsafeDiagnostics = false
  var rejectNextSend = false
  var uncertainNextSend = false
  func makeNextSendUncertain() { uncertainNextSend = true }
  var rejectEvents = false
  var sentIDs: [UUID] = []
  func failNextSend() { rejectNextSend = true }
  func failEventRefresh() { rejectEvents = true }

  init(fixture: MobileClientFixture) { self.fixture = fixture }

  func capabilities() async throws -> EnvironmentCapabilitiesOutput {
    EnvironmentCapabilitiesOutput(
      environment: fixture.environment,
      supportedProtocolVersions: [OttoRPCProtocol.currentVersion]
    )
  }
  func listBots() async throws -> MobileRosterOutput {
    if rejectRoster { throw OttoMobileConnectionError.invalidResponse }
    return MobileRosterOutput(bots: rosterDeleted ? [] : [fixture.bot], teams: [])
  }
  func listThreads() async throws -> ThreadListOutput {
    ThreadListOutput(threads: rosterDeleted ? [] : [fixture.thread])
  }
  func startThread(botProfileID: UUID, initialMessage _: String?) async throws
    -> ThreadStartOutput
  {
    startedBots.append(botProfileID)
    return ThreadStartOutput(thread: fixture.thread, openedExisting: false)
  }
  func registerPush(token _: String, environment _: OttoPushEnvironment) async throws
    -> AcceptedOutput
  { AcceptedOutput(accepted: true) }
  func snapshot(threadID _: UUID) async throws -> ThreadSnapshot {
    ThreadSnapshot(thread: fixture.thread, messages: [], lastEventSequence: 0)
  }
  func events(threadID: UUID, afterSequence: Int64) async throws -> ThreadEventPage {
    if rejectEvents { throw URLError(.networkConnectionLost) }
    return ThreadEventPage(
      threadID: threadID, events: [], latestSequence: afterSequence, hasMore: false)
  }
  func send(threadID: UUID, clientMessageID: UUID, body: String) async throws
    -> MessageSendOutput
  {
    sentIDs.append(clientMessageID)
    if uncertainNextSend {
      uncertainNextSend = false
      throw OttoRPCContractError.remote(
        OttoRPCFailure(
          code: "command_uncertain", message: "The earlier send could not be confirmed."))
    }
    if rejectNextSend {
      rejectNextSend = false
      throw URLError(.networkConnectionLost)
    }
    let message = ThreadMessage(role: .user, text: body, clientMessageID: clientMessageID)
    let event = RunEvent(
      threadID: threadID,
      sequence: 1,
      kind: .messageAdded,
      correlationID: clientMessageID,
      content: RunEventContent(message: message)
    )
    return MessageSendOutput(accepted: true, event: event, duplicate: false)
  }
  func interrupt(threadID: UUID, runID: UUID) async throws -> AcceptedOutput {
    recordedControls.append(Control(method: .runInterrupt, threadID: threadID, runID: runID))
    return AcceptedOutput(accepted: true)
  }
  func stop(threadID: UUID, runID: UUID) async throws -> AcceptedOutput {
    recordedControls.append(Control(method: .runStop, threadID: threadID, runID: runID))
    return AcceptedOutput(accepted: true)
  }
  func respondToApproval(_ input: ApprovalRespondInput) async throws -> ApprovalRespondOutput {
    approvals.append(input)
    return ApprovalRespondOutput(
      accepted: true,
      requestID: input.requestID,
      decision: input.decision
    )
  }
  func listAttachments(threadID _: UUID) async throws -> AttachmentListOutput {
    AttachmentListOutput(attachments: uploadedAttachment.map { [$0] } ?? [])
  }
  func prepareAttachmentUpload(
    _ input: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    attachmentPrepare = input
    let id = UUID()
    attachmentUploadID = id
    attachmentBytes = Data()
    return AttachmentPrepareUploadOutput(
      uploadID: id,
      chunkSize: 8,
      expiresAt: .now.addingTimeInterval(300)
    )
  }
  func uploadAttachmentChunk(
    _ input: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    guard input.uploadID == attachmentUploadID,
      input.offset == Int64(attachmentBytes.count),
      let prepared = attachmentPrepare
    else { throw OttoMobileConnectionError.invalidResponse }
    attachmentBytes.append(input.data)
    let complete = attachmentBytes.count == Int(prepared.byteCount)
    if complete {
      uploadedAttachment = OttoAttachment(
        displayName: prepared.displayName,
        relativePath: ".otto/attachments/test/\(prepared.displayName)",
        mimeType: prepared.mimeType,
        byteCount: prepared.byteCount
      )
    }
    return AttachmentUploadChunkOutput(
      receivedBytes: Int64(attachmentBytes.count),
      complete: complete,
      attachment: complete ? uploadedAttachment : nil
    )
  }
  func downloadAttachmentChunk(
    _ input: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    guard let attachment = uploadedAttachment,
      input.attachmentID == attachment.id,
      input.offset >= 0,
      input.offset < Int64(attachmentBytes.count)
    else { throw OttoMobileConnectionError.invalidResponse }
    let start = Int(input.offset)
    let end = min(start + input.limit, attachmentBytes.count)
    return AttachmentDownloadChunkOutput(
      attachment: attachment,
      offset: input.offset,
      data: attachmentBytes.subdata(in: start..<end),
      hasMore: end < attachmentBytes.count,
      sha256: end == attachmentBytes.count
        ? (corruptDownloadDigest
          ? String(repeating: "0", count: 64)
          : SHA256.hash(data: attachmentBytes).map { String(format: "%02x", $0) }.joined())
        : nil
    )
  }
  func diagnostics() async throws -> MobileDiagnosticsOutput {
    MobileDiagnosticsOutput(
      appVersion: unsafeDiagnostics ? "/Users/alice/secret.swift" : "0.1.0",
      operatingSystemVersion: "26.2",
      previousSessionAbnormal: true,
      eventCounts: [
        MobileDiagnosticEventKind.previousSessionAbnormal.rawValue: 1,
        MobileDiagnosticEventKind.toolCall.rawValue: 3,
      ],
      toolSuccessCount: 3,
      toolFailureCount: 0,
      toolLatencyMedianMilliseconds: 44.9,
      providerFailureCount: 0,
      recentEvents: [
        MobileDiagnosticEvent(kind: .previousSessionAbnormal),
        MobileDiagnosticEvent(
          kind: .toolCall,
          toolName: "canvas.list",
          durationMilliseconds: 44.9,
          succeeded: true
        ),
      ]
    )
  }
  func eventStream(threadID _: UUID, afterSequence _: Int64) async throws
    -> AsyncThrowingStream<RunEvent, Error>
  {
    AsyncThrowingStream { continuation = $0 }
  }
  func emit(_ event: RunEvent) { continuation?.yield(event) }
  func hasSubscriber() -> Bool { continuation != nil }
  func controls() -> [Control] { recordedControls }
  func startedBotIDs() -> [UUID] { startedBots }
  func approvalInputs() -> [ApprovalRespondInput] { approvals }
  func uploadedBytes() -> Data { attachmentBytes }
  func setCorruptDownloadDigest(_ value: Bool) { corruptDownloadDigest = value }
  func setUnsafeDiagnostics(_ value: Bool) { unsafeDiagnostics = value }
}

private actor OfflineMobileConnection: OttoMobileConnecting {
  enum Unavailable: Error { case host }

  func capabilities() async throws -> EnvironmentCapabilitiesOutput { throw Unavailable.host }
  func listBots() async throws -> MobileRosterOutput { throw Unavailable.host }
  func listThreads() async throws -> ThreadListOutput { throw Unavailable.host }
  func startThread(botProfileID _: UUID, initialMessage _: String?) async throws
    -> ThreadStartOutput
  { throw Unavailable.host }
  func registerPush(token _: String, environment _: OttoPushEnvironment) async throws
    -> AcceptedOutput
  { throw Unavailable.host }
  func snapshot(threadID _: UUID) async throws -> ThreadSnapshot { throw Unavailable.host }
  func events(threadID _: UUID, afterSequence _: Int64) async throws -> ThreadEventPage {
    throw Unavailable.host
  }
  func send(threadID _: UUID, clientMessageID _: UUID, body _: String) async throws
    -> MessageSendOutput
  { throw Unavailable.host }
  func interrupt(threadID _: UUID, runID _: UUID) async throws -> AcceptedOutput {
    throw Unavailable.host
  }
  func stop(threadID _: UUID, runID _: UUID) async throws -> AcceptedOutput {
    throw Unavailable.host
  }
  func eventStream(threadID _: UUID, afterSequence _: Int64) async throws
    -> AsyncThrowingStream<RunEvent, Error>
  { throw Unavailable.host }
}

private struct MobileClientFixture: Sendable {
  let timestamp = Date(timeIntervalSince1970: 1_800_000_000.123)
  let environment: ExecutionEnvironment
  let thread: OttoModels.Thread
  let bot: MobileBotSummary

  init() {
    let environmentID = UUID()
    environment = ExecutionEnvironment(
      id: environmentID,
      name: "Max’s MacBook",
      kind: .macHost,
      status: .online,
      capabilities: [.conversations],
      protocolVersion: OttoRPCProtocol.currentVersion
    )
    let profileID = UUID()
    thread = OttoModels.Thread(
      id: UUID(),
      kind: .botChannel,
      title: "Ada",
      botProfileIDs: [profileID],
      executionEnvironmentID: environmentID,
      state: .working,
      createdAt: timestamp,
      updatedAt: timestamp
    )
    bot = MobileBotSummary(
      id: profileID,
      name: "Ada",
      jobTitle: "Research partner",
      provider: .codex,
      hasSession: false,
      updatedAt: timestamp
    )
  }
}

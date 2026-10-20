import Foundation
import OttoModels
import OttoRPCContracts
import Testing

@Suite("Otto mobile RPC contract")
struct OttoRPCContractTests {
  @Test("Environment, thread, and event fixtures round-trip as platform-neutral JSON")
  func modelRoundTrip() throws {
    let environmentID = UUID()
    let threadID = UUID()
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000.123)
    let environment = ExecutionEnvironment(
      id: environmentID,
      name: "This Mac",
      kind: .macHost,
      status: .online,
      capabilities: [.conversations, .notifications],
      protocolVersion: OttoRPCProtocol.currentVersion,
      hostVersion: "0.1.18"
    )
    let thread = OttoModels.Thread(
      id: threadID,
      kind: .botChannel,
      title: "Ada",
      botProfileIDs: [UUID()],
      executionEnvironmentID: environmentID,
      state: .working,
      lastEventSequence: 7,
      createdAt: timestamp,
      updatedAt: timestamp
    )
    let message = ThreadMessage(
      role: .assistant,
      text: "Done",
      author: RunEventAuthor(role: .assistant, botProfileID: thread.botProfileIDs[0]),
      createdAt: timestamp
    )
    let event = RunEvent(
      threadID: threadID,
      sequence: 7,
      timestamp: timestamp,
      kind: .runCompleted,
      author: message.author,
      content: RunEventContent(
        message: message,
        state: .done,
        notification: .completion
      )
    )
    let fixture = ThreadSnapshot(
      thread: thread,
      messages: [message],
      lastEventSequence: event.sequence
    )

    #expect(try roundTrip(environment) == environment)
    #expect(try roundTrip(fixture) == fixture)
    #expect(try roundTrip(event) == event)
  }

  @Test("Typed request payloads survive the versioned envelope")
  func typedEnvelope() throws {
    let input = MessageSendInput(
      threadID: UUID(),
      clientMessageID: UUID(),
      body: "Continue"
    )
    let request = try OttoRPCRequest(method: .messageSend, parameters: input)
    let data = try OttoRPCCodec.encoder.encode(request)
    let decoded = try OttoRPCCodec.decoder.decode(OttoRPCRequest.self, from: data)

    #expect(decoded.protocolVersion == OttoRPCProtocol.currentVersion)
    #expect(decoded.method == .messageSend)
    #expect(try decoded.decodeParameters(MessageSendInput.self) == input)
    #expect(decoded.method.requiredScope == .messageWrite)
  }

  @Test("Attachment methods preserve least-privilege scopes")
  func attachmentScopes() {
    #expect(OttoRPCMethod.attachmentList.requiredScope == .threadRead)
    #expect(OttoRPCMethod.attachmentPrepareUpload.requiredScope == .messageWrite)
    #expect(OttoRPCMethod.attachmentUploadChunk.requiredScope == .messageWrite)
    #expect(OttoRPCMethod.attachmentDownloadChunk.requiredScope == .threadRead)
    #expect(OttoRPCMethod.diagnosticsGet.requiredScope == .environmentRead)
  }

  @Test("Mobile diagnostics reject content-shaped values and export aggregates only")
  func diagnosticsPrivacyBoundary() throws {
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    let safe = MobileDiagnosticsOutput(
      generatedAt: timestamp,
      appVersion: "0.1.0",
      operatingSystemVersion: "26.2",
      previousSessionAbnormal: false,
      eventCounts: [MobileDiagnosticEventKind.toolCall.rawValue: 1],
      toolSuccessCount: 1,
      toolFailureCount: 0,
      toolLatencyMedianMilliseconds: 8.5,
      providerFailureCount: 0,
      recentEvents: [
        MobileDiagnosticEvent(
          timestamp: timestamp,
          kind: .toolCall,
          toolName: "canvas.list",
          durationMilliseconds: 8.5,
          succeeded: true
        )
      ]
    )
    #expect(safe.isPrivacySafe)
    #expect(safe.supportExport.eventCounts == safe.eventCounts)
    #expect(try roundTrip(safe) == safe)

    var unsafe = safe
    unsafe.recentEvents[0].toolName = "/Users/alice/secret.swift"
    #expect(!unsafe.isPrivacySafe)
    unsafe = safe
    unsafe.eventCounts["prompt.body"] = 1
    #expect(!unsafe.isPrivacySafe)
  }

  @Test("Completion events retain APNs routing classification without an APNs payload")
  func completionNotificationClassification() throws {
    let event = RunEvent(
      threadID: UUID(),
      sequence: 1,
      kind: .runCompleted,
      content: RunEventContent(state: .done, notification: .completion)
    )
    let value = try OttoRPCCodec.value(event)
    let restored = try OttoRPCCodec.decode(RunEvent.self, from: value)
    #expect(restored.content.notification == .completion)
    #expect(restored.kind == .runCompleted)
  }

  @Test("Pairing QR contains a short-lived offer but no durable credential")
  func pairingQRRoundTrip() throws {
    let payload = OttoMobilePairingPayload(
      offerID: UUID(),
      environmentID: UUID(),
      environmentName: "Studio Mac",
      fingerprint: String(repeating: "a", count: 64),
      baseURL: try #require(URL(string: "https://studio-mac.example.test/")),
      code: "204813",
      expiresAt: Date(timeIntervalSince1970: 1_800_000_300),
      scopes: [.environmentRead, .threadRead, .messageWrite, .runControl]
    )

    let qrString = try payload.qrString()
    #expect(qrString.hasPrefix("otto://pair?"))
    #expect(!qrString.contains("credential"))
    #expect(try OttoMobilePairingPayload(qrString: qrString) == payload)
    // Codes printed before the rename use muse:// and must still pair.
    let legacy = "muse://" + qrString.dropFirst("otto://".count)
    #expect(try OttoMobilePairingPayload(qrString: legacy) == payload)
    #expect(throws: OttoMobilePairingContractError.invalidPayload) {
      try OttoMobilePairingPayload(qrString: "https://example.com/not-a-pairing")
    }
  }

  private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try OttoRPCCodec.encoder.encode(value)
    return try OttoRPCCodec.decoder.decode(Value.self, from: data)
  }
}

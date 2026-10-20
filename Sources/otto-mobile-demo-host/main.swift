import CryptoKit
import Foundation
import OttoHostRuntime
import OttoHostTransport
import OttoModels
import OttoRPCContracts
import OttoRemote

private let environmentID = UUID(uuidString: "338DFEA0-6511-41E8-80B7-DC71A956A73C")!
private let threadID = UUID(uuidString: "1A98ACB6-7FEA-4B54-A61B-A9FB04411D27")!
private let botID = UUID(uuidString: "8108CB17-A315-4C32-8EC4-F9F0EA65AE60")!
private let novaBotID = UUID(uuidString: "20C05A55-731A-45EA-B452-779FB43F691E")!
private let novaThreadID = UUID(uuidString: "F90A6E6E-10DD-4A61-A966-6AF74B66CB17")!
private let demoTeamID = UUID(uuidString: "68E75FF3-3D08-47A0-860A-5551AA0DB2C6")!

private enum DemoPairingError: Error {
  case rejected
}

private actor DemoPairingHandler: OttoHostPairingHandling {
  private let baseURL: URL
  private let offerID = UUID()
  private let code = String(Int.random(in: 100_000...999_999))
  // The e2e script starts this host before xcodebuild compiles the iPhone app and UI tests. A cold
  // CI build takes longer than five minutes, so the demo offer must outlive it.
  private let expiresAt = Date.now.addingTimeInterval(30 * 60)
  private let fingerprint = String(repeating: "d", count: 64)
  private let scopes = Set(OttoRPCScope.allCases)
  private var exchanged = false
  private var devices: [UUID: (credential: String, scopes: Set<OttoRPCScope>)] = [:]

  init(baseURL: URL) {
    self.baseURL = baseURL
  }

  func createPayload() -> OttoMobilePairingPayload {
    return OttoMobilePairingPayload(
      offerID: offerID,
      environmentID: environmentID,
      environmentName: "Otto Mobile Demo Mac",
      fingerprint: fingerprint,
      baseURL: baseURL,
      code: code,
      expiresAt: expiresAt,
      scopes: scopes
    )
  }

  func exchange(
    _ input: OttoMobilePairingExchangeInput
  ) async throws -> OttoMobilePairingExchangeOutput {
    guard !exchanged,
      input.offerID == offerID,
      input.code == code,
      expiresAt > .now,
      !input.deviceName.isEmpty,
      !input.devicePublicKey.isEmpty
    else { throw DemoPairingError.rejected }
    exchanged = true
    let deviceID = UUID()
    let credential = UUID().uuidString + UUID().uuidString
    devices[deviceID] = (credential, scopes)
    return OttoMobilePairingExchangeOutput(
      deviceID: deviceID,
      credential: credential,
      environmentID: environmentID,
      environmentName: "Otto Mobile Demo Mac",
      baseURL: baseURL,
      fingerprint: fingerprint,
      scopes: scopes
    )
  }

  func authenticate(
    deviceID: UUID,
    credential: String,
    requiredScope: OttoRPCScope
  ) async throws -> OttoHostClientContext {
    guard let device = devices[deviceID],
      device.credential == credential,
      device.scopes.contains(requiredScope)
    else { throw DemoPairingError.rejected }
    return OttoHostClientContext(
      deviceID: deviceID,
      scopes: device.scopes
    )
  }
}

private actor DemoDataSource: OttoHostDataSource {
  private var messages: [ThreadMessage] = [
    ThreadMessage(
      id: UUID(uuidString: "6B392760-AF1D-42D6-8A38-69EC1E8A0AD0")!,
      role: .user,
      text: "Can I keep this session going from my phone?",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    ),
    ThreadMessage(
      id: UUID(uuidString: "742936CC-74F3-4A7E-8146-63702CD4D625")!,
      role: .assistant,
      text:
        "Yes. The provider, repository, and credentials stay on this Mac. I only stream the canonical conversation state to your phone.",
      author: RunEventAuthor(role: .assistant, botProfileID: botID, displayName: "Ada"),
      createdAt: Date(timeIntervalSince1970: 1_800_000_001)
    ),
  ]
  private var replyHandler: (@Sendable (ThreadMessage) -> Void)?
  private var approvalHandler: (@Sendable (ApprovalRespondInput) -> Void)?
  private var approval: MobileApprovalRequest?
  private var threadState: ThreadState = .idle
  private struct DemoUpload {
    var input: AttachmentPrepareUploadInput
    var data: Data
  }
  private var uploads: [UUID: DemoUpload] = [:]
  private var completedUploads: [UUID: OttoAttachment] = [:]
  private var attachments: [OttoAttachment] = []
  private var attachmentData: [UUID: Data] = [:]
  private var novaStarted = false
  private var teamMessages: [ThreadMessage] = [
    ThreadMessage(
      role: .assistant, text: "Shared team plan: review the launch together.",
      author: RunEventAuthor(role: .assistant, botProfileID: novaBotID, displayName: "Nova"))
  ]

  func setReplyHandler(_ handler: @escaping @Sendable (ThreadMessage) -> Void) {
    replyHandler = handler
  }

  func setApprovalHandler(_ handler: @escaping @Sendable (ApprovalRespondInput) -> Void) {
    approvalHandler = handler
  }

  func requestApproval(reason: String) -> MobileApprovalRequest {
    let request = MobileApprovalRequest(
      requestID: UUID(),
      threadID: threadID,
      runID: UUID(),
      reason: reason,
      nonce: UUID().uuidString.lowercased(),
      requestedAt: .now
    )
    approval = request
    threadState = .approvalRequired
    return request
  }

  func append(_ message: ThreadMessage) {
    messages.append(message)
  }

  func environment() async -> ExecutionEnvironment {
    ExecutionEnvironment(
      id: environmentID,
      name: "Otto Mobile Demo Mac",
      kind: .macHost,
      status: .online,
      capabilities: [.conversations, .approvals, .attachments, .diagnostics],
      protocolVersion: OttoRPCProtocol.currentVersion,
      hostVersion: "phase-0-demo",
      lastSeenAt: .now
    )
  }

  func listThreads() async throws -> [OttoModels.Thread] {
    (novaStarted ? [makeThread(), makeNovaThread()] : [makeThread()]) + [makeTeamThread()]
  }

  func listBots() async throws -> MobileRosterOutput {
    MobileRosterOutput(
      bots: [
        MobileBotSummary(
          id: botID, name: "Ada", jobTitle: "Research partner", provider: .codex,
          hasSession: true, updatedAt: .now),
        MobileBotSummary(
          id: novaBotID, name: "Nova", jobTitle: "Launch planner", provider: .claudeCode,
          hasSession: novaStarted, updatedAt: .now),
      ],
      teams: [
        MobileTeamSummary(
          id: demoTeamID, name: "Studio Launch Team", memberProfileIDs: [botID, novaBotID],
          orchestratorProfileID: botID, updatedAt: .now)
      ]
    )
  }

  func startThread(_ input: ThreadStartInput) async throws -> ThreadStartOutput {
    if input.botProfileID == botID {
      return ThreadStartOutput(thread: makeThread(), openedExisting: true)
    }
    guard input.botProfileID == novaBotID else {
      throw OttoHostError.botNotFound(input.botProfileID)
    }
    let openedExisting = novaStarted
    novaStarted = true
    return ThreadStartOutput(thread: makeNovaThread(), openedExisting: openedExisting)
  }

  func snapshot(threadID requestedID: UUID) async throws -> ThreadSnapshot {
    if requestedID == demoTeamID {
      return ThreadSnapshot(thread: makeTeamThread(), messages: teamMessages, lastEventSequence: 0)
    }
    if requestedID == novaThreadID, novaStarted {
      return ThreadSnapshot(thread: makeNovaThread(), messages: [], lastEventSequence: 0)
    }
    guard requestedID == threadID else { throw OttoHostError.threadNotFound(requestedID) }
    return ThreadSnapshot(thread: makeThread(), messages: messages, lastEventSequence: 0)
  }

  func sendMessage(threadID requestedID: UUID, body: String) async throws -> ThreadMessage {
    if requestedID == demoTeamID {
      let message = ThreadMessage(role: .user, text: body)
      teamMessages.append(message)
      return message
    }
    guard requestedID == threadID else { throw OttoHostError.threadNotFound(requestedID) }
    let message = ThreadMessage(
      role: .user,
      text: body,
      author: RunEventAuthor(role: .user),
      createdAt: .now
    )
    messages.append(message)
    replyHandler?(message)
    return message
  }

  func interrupt(threadID _: UUID, runID _: UUID) async throws {}
  func stop(threadID _: UUID, runID _: UUID) async throws {}

  func pendingApproval(threadID requestedID: UUID) async throws -> MobileApprovalRequest? {
    guard requestedID == threadID else { throw OttoHostError.threadNotFound(requestedID) }
    return approval
  }

  func respondToApproval(_ input: ApprovalRespondInput) async throws {
    guard let current = approval,
      input.threadID == current.threadID,
      input.requestID == current.requestID,
      input.nonce == current.nonce
    else { throw OttoHostError.approvalUnavailable }
    approval = nil
    threadState = .working
    approvalHandler?(input)
  }

  func listAttachments(threadID requestedID: UUID) async throws -> [OttoAttachment] {
    guard requestedID == threadID else { throw OttoHostError.threadNotFound(requestedID) }
    return attachments
  }

  func prepareAttachmentUpload(
    _ input: AttachmentPrepareUploadInput
  ) async throws -> AttachmentPrepareUploadOutput {
    guard input.threadID == threadID,
      (1...(20 * 1_048_576)).contains(input.byteCount),
      !input.displayName.isEmpty,
      input.sha256.count == 64
    else { throw OttoHostError.invalidAttachment("The demo upload metadata is invalid.") }
    let uploadID = UUID()
    uploads[uploadID] = DemoUpload(input: input, data: Data())
    return AttachmentPrepareUploadOutput(
      uploadID: uploadID,
      chunkSize: 256 * 1_024,
      expiresAt: .now.addingTimeInterval(15 * 60)
    )
  }

  func uploadAttachmentChunk(
    _ input: AttachmentUploadChunkInput
  ) async throws -> AttachmentUploadChunkOutput {
    if let attachment = completedUploads[input.uploadID] {
      return AttachmentUploadChunkOutput(
        receivedBytes: attachment.byteCount,
        complete: true,
        attachment: attachment
      )
    }
    guard var upload = uploads[input.uploadID],
      upload.input.threadID == input.threadID,
      input.offset == Int64(upload.data.count),
      !input.data.isEmpty,
      input.data.count <= 256 * 1_024,
      upload.data.count + input.data.count <= Int(upload.input.byteCount)
    else { throw OttoHostError.attachmentTransferUnavailable }
    upload.data.append(input.data)
    uploads[input.uploadID] = upload
    guard upload.data.count == Int(upload.input.byteCount) else {
      return AttachmentUploadChunkOutput(
        receivedBytes: Int64(upload.data.count),
        complete: false
      )
    }
    let digest = SHA256.hash(data: upload.data).map { String(format: "%02x", $0) }.joined()
    guard digest == upload.input.sha256.lowercased() else {
      uploads[input.uploadID] = nil
      throw OttoHostError.invalidAttachment("The attachment digest does not match.")
    }
    let attachment = OttoAttachment(
      displayName: upload.input.displayName,
      relativePath: ".otto/attachments/demo/\(upload.input.displayName)",
      mimeType: upload.input.mimeType,
      byteCount: upload.input.byteCount
    )
    attachments.append(attachment)
    attachmentData[attachment.id] = upload.data
    completedUploads[input.uploadID] = attachment
    uploads[input.uploadID] = nil
    return AttachmentUploadChunkOutput(
      receivedBytes: attachment.byteCount,
      complete: true,
      attachment: attachment
    )
  }

  func downloadAttachmentChunk(
    _ input: AttachmentDownloadChunkInput
  ) async throws -> AttachmentDownloadChunkOutput {
    guard input.threadID == threadID,
      let attachment = attachments.first(where: { $0.id == input.attachmentID }),
      let data = attachmentData[attachment.id],
      input.offset >= 0,
      input.offset < Int64(data.count),
      (1...(256 * 1_024)).contains(input.limit)
    else { throw OttoHostError.attachmentTransferUnavailable }
    let start = Int(input.offset)
    let end = min(start + input.limit, data.count)
    return AttachmentDownloadChunkOutput(
      attachment: attachment,
      offset: input.offset,
      data: data.subdata(in: start..<end),
      hasMore: end < data.count,
      sha256: end == data.count
        ? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        : nil
    )
  }

  func diagnostics() async throws -> MobileDiagnosticsOutput {
    MobileDiagnosticsOutput(
      appVersion: "0.1.0",
      operatingSystemVersion: "26.2",
      previousSessionAbnormal: true,
      eventCounts: [
        MobileDiagnosticEventKind.previousSessionAbnormal.rawValue: 1,
        MobileDiagnosticEventKind.sessionStarted.rawValue: 1,
        MobileDiagnosticEventKind.toolCall.rawValue: 3,
      ],
      toolSuccessCount: 3,
      toolFailureCount: 0,
      toolLatencyMedianMilliseconds: 44.9,
      providerFailureCount: 0,
      recentEvents: [
        MobileDiagnosticEvent(kind: .previousSessionAbnormal),
        MobileDiagnosticEvent(kind: .sessionStarted),
        MobileDiagnosticEvent(
          kind: .toolCall,
          toolName: "canvas.list",
          durationMilliseconds: 44.9,
          succeeded: true
        ),
      ]
    )
  }

  private func makeTeamThread() -> OttoModels.Thread {
    OttoModels.Thread(
      id: demoTeamID, kind: .group, title: "Studio Launch Team",
      botProfileIDs: [botID, novaBotID], channelID: demoTeamID,
      executionEnvironmentID: environmentID)
  }

  private func makeThread() -> OttoModels.Thread {
    OttoModels.Thread(
      id: threadID,
      kind: .botChannel,
      title: "Ada",
      botProfileIDs: [botID],
      executionEnvironmentID: environmentID,
      state: threadState,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: .now
    )
  }

  private func makeNovaThread() -> OttoModels.Thread {
    OttoModels.Thread(
      id: novaThreadID,
      kind: .botChannel,
      title: "Nova",
      botProfileIDs: [novaBotID],
      executionEnvironmentID: environmentID,
      state: .idle,
      createdAt: Date(timeIntervalSince1970: 1_800_000_000),
      updatedAt: .now
    )
  }
}

@main
private enum OttoMobileDemoHost {
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    let token =
      OttoEnvironment.value("MOBILE_HOST_TOKEN", in: environment)
      ?? "otto-mobile-demo-token-2026-local-only"
    let port = Int(OttoEnvironment.value("MOBILE_HOST_PORT", in: environment) ?? "7338") ?? 7338
    let stateDirectory = FileManager.default.temporaryDirectory
      .appending(path: "otto-mobile-demo-host", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let dataSource = DemoDataSource()
    let journal = try RunEventJournal(directory: stateDirectory)
    let host = OttoHostRuntime(dataSource: dataSource, journal: journal)

    await dataSource.setReplyHandler { userMessage in
      Task {
        if userMessage.text.hasPrefix("APPROVAL RELAY E2E") {
          let approval = await dataSource.requestApproval(
            reason: "Bash: publish the signed release tag from this Mac"
          )
          _ = try? await host.publish(
            RunEventDraft(
              threadID: threadID,
              kind: .approvalRequested,
              content: RunEventContent(
                runID: approval.runID,
                state: .approvalRequired,
                approval: approval,
                notification: .approval
              )
            )
          )
          return
        }
        try? await Task.sleep(for: .milliseconds(350))
        let runID = UUID()
        _ = try? await host.publish(
          RunEventDraft(
            threadID: threadID,
            kind: .runStarted,
            content: RunEventContent(runID: runID, state: .working)
          ))
        // Keep the run in flight long enough for a slow CI simulator to find and tap its
        // Interrupt control; the UI tests still allow ten seconds for the reply.
        try? await Task.sleep(for: .seconds(8))
        let reply = ThreadMessage(
          role: .assistant,
          text:
            "Received ‘\(userMessage.text)’. This reply was produced by the local demo host and streamed over the same reconnect-safe event journal.",
          author: RunEventAuthor(role: .assistant, botProfileID: botID, displayName: "Ada"),
          createdAt: .now
        )
        await dataSource.append(reply)
        _ = try? await host.publish(
          RunEventDraft(
            threadID: threadID,
            kind: .messageAdded,
            author: reply.author,
            content: RunEventContent(message: reply)
          ))
        _ = try? await host.publish(
          RunEventDraft(
            threadID: threadID,
            kind: .runCompleted,
            content: RunEventContent(
              runID: runID,
              state: .done,
              notification: .completion
            )
          ))
      }
    }
    await dataSource.setApprovalHandler { input in
      Task {
        let verb = input.decision == .approveOnce ? "Approved once" : "Denied"
        let reply = ThreadMessage(
          role: .assistant,
          text:
            "\(verb) on iPhone. The exact pending action was resolved on this Mac; replay is rejected.",
          author: RunEventAuthor(role: .assistant, botProfileID: botID, displayName: "Ada"),
          createdAt: .now
        )
        await dataSource.append(reply)
        _ = try? await host.publish(
          RunEventDraft(
            threadID: threadID,
            kind: .messageAdded,
            author: reply.author,
            content: RunEventContent(message: reply)
          )
        )
        _ = try? await host.publish(
          RunEventDraft(
            threadID: threadID,
            kind: .runStateChanged,
            content: RunEventContent(
              runID: nil,
              state: input.decision == .approveOnce ? .working : .stopped
            )
          )
        )
      }
    }

    let configuration = try OttoHostTransportConfiguration(
      hostname: "127.0.0.1",
      port: port,
      token: token
    )
    let baseURL = URL(string: "http://127.0.0.1:\(port)/")!
    let pairing = DemoPairingHandler(baseURL: baseURL)
    let payload = await pairing.createPayload()
    let pairingQR = try payload.qrString()
    if let pairingFile = OttoEnvironment.value("MOBILE_PAIRING_QR_FILE", in: environment) {
      try pairingQR.write(
        to: URL(fileURLWithPath: pairingFile),
        atomically: true,
        encoding: .utf8
      )
    }
    let app = try OttoHostHTTPApplication.make(
      host: host,
      configuration: configuration,
      pairing: pairing
    )
    let managedConnector = try makeManagedConnector(
      environment: environment,
      host: host
    )
    print("Otto Mobile demo host: http://127.0.0.1:\(port)/")
    print("Developer token: \(token)")
    print("Pairing code: \(pairingQR)")
    if managedConnector != nil { print("Managed relay connector: configured") }
    print("Open the Ada thread, send a reply, then relaunch to exercise catch-up.")
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await app.run() }
      if let managedConnector {
        group.addTask { await managedConnector.run() }
      }
      _ = try await group.next()
      group.cancelAll()
    }
  }

  private static func makeManagedConnector(
    environment: [String: String],
    host: OttoHostRuntime
  ) throws -> ManagedRemoteHostConnector? {
    let controlPlane = OttoEnvironment.value("REMOTE_CONTROL_PLANE_URL", in: environment)
    let connectorCredential = OttoEnvironment.value("REMOTE_CONNECTOR_CREDENTIAL", in: environment)
    let signingKeyID = OttoEnvironment.value("REMOTE_SIGNING_KEY_ID", in: environment)
    let signingPublicKey = OttoEnvironment.value("REMOTE_SIGNING_PUBLIC_KEY", in: environment)
    let values = [controlPlane, connectorCredential, signingKeyID, signingPublicKey]
    guard values.contains(where: { $0?.isEmpty == false }) else { return nil }
    guard let controlPlane,
      let controlPlaneURL = URL(string: controlPlane),
      let connectorCredential, !connectorCredential.isEmpty,
      let signingKeyID, !signingKeyID.isEmpty,
      let signingPublicKey,
      let publicKey = Data(base64Encoded: signingPublicKey),
      publicKey.count == 32
    else { throw ManagedRemoteHostConnectorError.invalidConfiguration }
    let connector = ManagedRemoteHostConnector(
      configuration: try ManagedRemoteHostConnectorConfiguration(
        controlPlaneURL: controlPlaneURL,
        environmentID: environmentID,
        connectorCredential: connectorCredential,
        trustedTicketKeys: [signingKeyID: publicKey],
        hostVersion: "phase-2b-demo",
        capabilities: ["threads", "runs", "approvals", "attachments"]
      )
    ) { request, claims in
      let scopes = Set(claims.scopes.compactMap(OttoRPCScope.init(rawValue:)))
      return await host.handle(
        request,
        client: OttoHostClientContext(deviceID: claims.deviceID, scopes: scopes)
      )
    }
    return connector
  }
}

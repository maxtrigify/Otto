import Foundation

#if canImport(CryptoKit) && canImport(Observation) && canImport(UniformTypeIdentifiers)
  import CryptoKit
  import OttoModels
  import OttoRPCContracts
  import Observation
  import UniformTypeIdentifiers

  public enum OttoMobileConnectionState: Equatable, Sendable {
    case connecting
    case live
    case reconnecting(attempt: Int)
    case offline(String)
  }

  public enum OttoMobileDiagnosticsError: Error, LocalizedError, Equatable, Sendable {
    case consentRequired
    case invalidSnapshot

    public var errorDescription: String? {
      switch self {
      case .consentRequired: "Agree to share aggregate diagnostics before preparing a report."
      case .invalidSnapshot: "The Mac returned diagnostics outside Otto's privacy allowlist."
      }
    }
  }

  @MainActor @Observable
  public final class OttoMobileStore {
    public private(set) var environment: ExecutionEnvironment?
    public private(set) var threads: [OttoModels.Thread] = []
    public private(set) var bots: [MobileBotSummary] = []
    public private(set) var teams: [MobileTeamSummary] = []
    public private(set) var selectedThread: OttoModels.Thread?
    public private(set) var messages: [ThreadMessage] = []
    public private(set) var connectionState: OttoMobileConnectionState = .connecting
    public private(set) var isSending = false
    public private(set) var sendError: String?
    public private(set) var sendMayHaveBeenAccepted = false
    public private(set) var activeRunID: UUID?
    public private(set) var isControllingRun = false
    public private(set) var pendingApproval: MobileApprovalRequest?
    public private(set) var isRespondingToApproval = false
    public private(set) var attachments: [OttoAttachment] = []
    public private(set) var isTransferringAttachment = false
    public private(set) var attachmentTransferMessage: String?
    public private(set) var downloadedAttachmentID: UUID?
    public private(set) var downloadedAttachmentURL: URL?
    public private(set) var startingBotID: UUID?
    public private(set) var diagnostics: MobileDiagnosticsOutput?
    public private(set) var isLoadingDiagnostics = false
    public private(set) var diagnosticsMessage: String?
    public private(set) var diagnosticExportURL: URL?
    public var composerText = ""

    @ObservationIgnored private let connection: any OttoMobileConnecting
    @ObservationIgnored private let cache: any OttoMobileCaching
    @ObservationIgnored private let notifications: any OttoMobileNotificationDelivering
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var appliedEventIDs: Set<UUID> = []
    @ObservationIgnored private var cursor: Int64 = 0
    @ObservationIgnored private var hasLoadedHome = false
    @ObservationIgnored private var isRefreshingHome = false
    @ObservationIgnored private var homeMutationRevision = 0

    public init(
      connection: any OttoMobileConnecting,
      cache: any OttoMobileCaching = OttoMobileDiskCache(),
      notifications: any OttoMobileNotificationDelivering = OttoMobileNoopNotificationDelivery()
    ) {
      self.connection = connection
      self.cache = cache
      self.notifications = notifications
    }

    public func secureLogin(_ input: SecureLoginInput) async throws -> SecureLoginOutput {
      try await connection.secureLogin(input)
    }

    public func start() async {
      if !hasLoadedHome, let cached = await cache.home() {
        environment = cached.environment
        threads = cached.threads
        bots = cached.bots
        teams = cached.teams
      }
      hasLoadedHome = true
      if selectedThread == nil { connectionState = .connecting }
      await refreshHome()
    }

    /// A successful host response replaces the roster; a failed refresh preserves offline data.
    public func refreshHome() async {
      guard !isRefreshingHome, startingBotID == nil else { return }
      isRefreshingHome = true
      let revision = homeMutationRevision
      defer { isRefreshingHome = false }
      do {
        async let capabilities = connection.capabilities()
        async let threadList = connection.listThreads()
        async let roster = connection.listBots()
        let hostEnvironment = try await capabilities.environment
        let hostThreads = try await threadList.threads
        let rosterOutput = try await roster
        try Task.checkCancellation()
        guard revision == homeMutationRevision, startingBotID == nil else { return }
        environment = hostEnvironment
        threads = hostThreads
        bots = rosterOutput.bots
        teams = rosterOutput.teams
        if let selectedThread, !threads.contains(where: { $0.id == selectedThread.id }) {
          closeThread()
        }
        if selectedThread == nil { connectionState = .live }
        try? await cache.replace(home: cachedHome())
      } catch is CancellationError {
        return
      } catch {
        if selectedThread == nil { connectionState = .offline(error.localizedDescription) }
      }
    }

    /// Owned by the foreground view task, so polling stops when the app leaves the foreground.
    public func syncHome() async {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        await refreshHome()
      }
    }

    public func open(_ thread: OttoModels.Thread) async {
      streamTask?.cancel()
      selectedThread = thread
      sendError = nil
      sendMayHaveBeenAccepted = false
      messages = []
      cursor = 0
      let pendingDraft = await cache.pendingMessage(threadID: thread.id)?.body ?? ""
      guard selectedThread?.id == thread.id else { return }
      composerText = pendingDraft
      connectionState = .connecting
      appliedEventIDs.removeAll(keepingCapacity: true)
      activeRunID = nil
      pendingApproval = nil
      attachments = []
      downloadedAttachmentID = nil
      downloadedAttachmentURL = nil
      attachmentTransferMessage = nil
      if let cached = await cache.thread(id: thread.id) {
        guard selectedThread?.id == thread.id else { return }
        selectedThread = cached.thread
        messages = cached.messages
        cursor = cached.lastEventSequence
      }
      do {
        let snapshot = try await connection.snapshot(threadID: thread.id)
        guard selectedThread?.id == thread.id else { return }
        activeRunID = snapshot.activeRunID
        selectedThread = snapshot.thread
        messages = snapshot.messages
        cursor = snapshot.lastEventSequence
        connectionState = .live
        try? await cache.replace(thread: snapshot)
        pendingApproval = try? await connection.pendingApproval(threadID: thread.id).request
        attachments = (try? await connection.listAttachments(threadID: thread.id).attachments) ?? []
        beginSync(threadID: thread.id)
      } catch {
        connectionState = .offline(error.localizedDescription)
      }
    }

    public func open(threadID: UUID) async {
      if threads.isEmpty { await start() }
      guard let thread = threads.first(where: { $0.id == threadID }) else { return }
      await open(thread)
    }

    public func closeThread() {
      streamTask?.cancel()
      streamTask = nil
      selectedThread = nil
      messages = []
      cursor = 0
      activeRunID = nil
      pendingApproval = nil
      attachments = []
      downloadedAttachmentID = nil
      downloadedAttachmentURL = nil
      attachmentTransferMessage = nil
    }

    public func sendComposer(asNewMessage: Bool = false) async {
      guard let thread = selectedThread else { return }
      let body = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty, !isSending else { return }
      isSending = true
      sendError = nil
      sendMayHaveBeenAccepted = false
      let original = composerText
      var accepted = false
      do {
        let previous = asNewMessage ? nil : await cache.pendingMessage(threadID: thread.id)
        let command =
          previous?.body == body
          ? previous!
          : MessageSendInput(
            threadID: thread.id, clientMessageID: UUID(), body: body)
        try await cache.savePendingMessage(command)
        let output = try await connection.send(
          threadID: thread.id,
          clientMessageID: command.clientMessageID,
          body: body
        )
        guard output.accepted, output.event.threadID == thread.id else {
          throw OttoMobileConnectionError.invalidResponse
        }
        accepted = true
        if selectedThread?.id == thread.id, composerText == original { composerText = "" }
        // Acceptance clears the pending command even if event catch-up needs another attempt.
        try await cache.removePendingMessage(threadID: thread.id)
        if selectedThread?.id == thread.id {
          try await catchUp(threadID: thread.id)
          if output.event.sequence > cursor { try await apply(output.event) }
        }
      } catch {
        if selectedThread?.id == thread.id {
          sendError =
            accepted
            ? "Message sent, but the conversation could not refresh. \(error.localizedDescription)"
            : error.localizedDescription
          if case OttoRPCContractError.remote(let failure) = error,
            failure.code == "command_uncertain"
          {
            sendMayHaveBeenAccepted = true
          }
        }
      }
      isSending = false
    }

    public func start(_ bot: MobileBotSummary) async {
      guard startingBotID == nil else { return }
      startingBotID = bot.id
      defer { startingBotID = nil }
      do {
        let output = try await connection.startThread(botProfileID: bot.id, initialMessage: nil)
        homeMutationRevision += 1
        if let index = threads.firstIndex(where: { $0.id == output.thread.id }) {
          threads[index] = output.thread
        } else {
          threads.insert(output.thread, at: 0)
        }
        if let index = bots.firstIndex(where: { $0.id == bot.id }) {
          bots[index].hasSession = true
        }
        try? await cache.replace(home: cachedHome())
        await open(output.thread)
      } catch {
        connectionState = .offline(error.localizedDescription)
      }
    }

    public func registerPush(token: String, environment: OttoPushEnvironment) async {
      do {
        let output = try await connection.registerPush(token: token, environment: environment)
        guard output.accepted else { throw OttoMobileConnectionError.invalidResponse }
      } catch {
        // Push registration is additive; it must not make foreground conversations appear offline.
      }
    }

    public func loadDiagnostics() async {
      guard !isLoadingDiagnostics else { return }
      isLoadingDiagnostics = true
      diagnosticsMessage = nil
      diagnosticExportURL = nil
      defer { isLoadingDiagnostics = false }
      do {
        let output = try await connection.diagnostics()
        guard output.isPrivacySafe else { throw OttoMobileDiagnosticsError.invalidSnapshot }
        diagnostics = output
      } catch {
        diagnostics = nil
        diagnosticsMessage = error.localizedDescription
      }
    }

    public func prepareDiagnosticExport(consent: Bool) async {
      diagnosticExportURL = nil
      do {
        guard consent else { throw OttoMobileDiagnosticsError.consentRequired }
        guard let diagnostics, diagnostics.isPrivacySafe else {
          throw OttoMobileDiagnosticsError.invalidSnapshot
        }
        let directory = FileManager.default.temporaryDirectory
          .appending(path: "Otto Mobile Diagnostics", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "Otto Support Diagnostics.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(diagnostics.supportExport).write(to: destination, options: [.atomic])
        #if os(iOS)
          try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
          )
        #endif
        diagnosticExportURL = destination
        diagnosticsMessage = "Aggregate report ready. You choose where it goes."
      } catch {
        diagnosticsMessage = error.localizedDescription
      }
    }

    public func interruptActiveRun() async {
      await controlActiveRun(stopping: false)
    }

    public func stopActiveRun() async {
      await controlActiveRun(stopping: true)
    }

    public func respondToPendingApproval(_ decision: MobileApprovalDecision) async {
      guard let approval = pendingApproval, !isRespondingToApproval else { return }
      isRespondingToApproval = true
      defer { isRespondingToApproval = false }
      do {
        let output = try await connection.respondToApproval(
          ApprovalRespondInput(
            threadID: approval.threadID,
            requestID: approval.requestID,
            nonce: approval.nonce,
            decision: decision
          )
        )
        guard output.accepted, output.requestID == approval.requestID else {
          throw OttoMobileConnectionError.invalidResponse
        }
        pendingApproval = nil
        if var thread = selectedThread {
          thread.state = .working
          selectedThread = thread
        }
      } catch {
        connectionState = .offline(error.localizedDescription)
        pendingApproval = try? await connection.pendingApproval(threadID: approval.threadID).request
      }
    }

    public func uploadAttachment(from url: URL) async {
      guard let thread = selectedThread, !isTransferringAttachment else { return }
      isTransferringAttachment = true
      attachmentTransferMessage = "Preparing \(url.lastPathComponent)…"
      defer { isTransferringAttachment = false }
      let accessed = url.startAccessingSecurityScopedResource()
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      do {
        let values = try url.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey, .contentTypeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
          throw OttoMobileConnectionError.invalidResponse
        }
        let name = values.name ?? url.lastPathComponent
        let bytes = try await Task.detached(priority: .userInitiated) {
          try Data(contentsOf: url, options: [.mappedIfSafe])
        }.value
        guard !bytes.isEmpty, bytes.count <= 20 * 1_048_576 else {
          throw OttoMobileConnectionError.invalidResponse
        }
        try await performAttachmentUpload(
          bytes: bytes,
          name: name,
          mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream",
          threadID: thread.id
        )
      } catch {
        attachmentTransferMessage = error.localizedDescription
      }
    }

    public func uploadTextAttachment(displayName: String, body: String) async {
      guard let thread = selectedThread, !isTransferringAttachment else { return }
      let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty, !trimmedBody.isEmpty else {
        attachmentTransferMessage = "A note needs a file name and some text."
        return
      }
      let name =
        URL(fileURLWithPath: trimmedName).pathExtension.isEmpty
        ? "\(trimmedName).txt" : trimmedName
      let bytes = Data(trimmedBody.utf8)
      guard bytes.count <= 20 * 1_048_576 else {
        attachmentTransferMessage = "Attachments are limited to 20 MB."
        return
      }
      isTransferringAttachment = true
      attachmentTransferMessage = "Preparing \(name)…"
      defer { isTransferringAttachment = false }
      do {
        try await performAttachmentUpload(
          bytes: bytes,
          name: name,
          mimeType: "text/plain",
          threadID: thread.id
        )
      } catch {
        attachmentTransferMessage = error.localizedDescription
      }
    }

    public func downloadAttachment(_ attachment: OttoAttachment) async {
      guard let thread = selectedThread, !isTransferringAttachment else { return }
      isTransferringAttachment = true
      attachmentTransferMessage = "Downloading \(attachment.displayName)…"
      defer { isTransferringAttachment = false }
      do {
        guard (1...(20 * 1_048_576)).contains(attachment.byteCount) else {
          throw OttoMobileConnectionError.invalidResponse
        }
        var bytes = Data()
        var offset: Int64 = 0
        var expectedDigest: String?
        while offset < attachment.byteCount {
          let output = try await connection.downloadAttachmentChunk(
            AttachmentDownloadChunkInput(
              threadID: thread.id,
              attachmentID: attachment.id,
              offset: offset
            )
          )
          guard output.attachment.id == attachment.id,
            output.offset == offset,
            !output.data.isEmpty,
            bytes.count + output.data.count <= Int(attachment.byteCount)
          else { throw OttoMobileConnectionError.invalidResponse }
          bytes.append(output.data)
          offset += Int64(output.data.count)
          if !output.hasMore { expectedDigest = output.sha256 }
          attachmentTransferMessage =
            "Downloading \(attachment.displayName) · \(Int(Double(offset) / Double(attachment.byteCount) * 100))%"
          if !output.hasMore { break }
        }
        guard Int64(bytes.count) == attachment.byteCount else {
          throw OttoMobileConnectionError.invalidResponse
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard expectedDigest == digest else { throw OttoMobileConnectionError.invalidResponse }
        let safeName = URL(fileURLWithPath: attachment.displayName).lastPathComponent
        let directory = FileManager.default.temporaryDirectory
          .appending(path: "Otto Mobile Downloads", directoryHint: .isDirectory)
          .appending(path: attachment.id.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: safeName.isEmpty ? "attachment" : safeName)
        try bytes.write(to: destination, options: [.atomic])
        downloadedAttachmentID = attachment.id
        downloadedAttachmentURL = destination
        attachmentTransferMessage = "Downloaded \(attachment.displayName)"
      } catch {
        attachmentTransferMessage = error.localizedDescription
      }
    }

    private func performAttachmentUpload(
      bytes: Data,
      name: String,
      mimeType: String,
      threadID: UUID
    ) async throws {
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let prepared = try await connection.prepareAttachmentUpload(
        AttachmentPrepareUploadInput(
          threadID: threadID,
          displayName: name,
          mimeType: mimeType,
          byteCount: Int64(bytes.count),
          sha256: digest
        )
      )
      guard (1...(256 * 1_024)).contains(prepared.chunkSize), prepared.expiresAt > .now else {
        throw OttoMobileConnectionError.invalidResponse
      }
      var offset = 0
      var completed: OttoAttachment?
      while offset < bytes.count {
        let end = min(offset + prepared.chunkSize, bytes.count)
        attachmentTransferMessage =
          "Uploading \(name) · \(Int(Double(end) / Double(bytes.count) * 100))%"
        let output = try await connection.uploadAttachmentChunk(
          AttachmentUploadChunkInput(
            threadID: threadID,
            uploadID: prepared.uploadID,
            offset: Int64(offset),
            data: bytes.subdata(in: offset..<end)
          )
        )
        guard output.receivedBytes == Int64(end) else {
          throw OttoMobileConnectionError.invalidResponse
        }
        completed = output.attachment ?? completed
        offset = end
      }
      guard let completed, completed.byteCount == Int64(bytes.count) else {
        throw OttoMobileConnectionError.invalidResponse
      }
      if let index = attachments.firstIndex(where: { $0.id == completed.id }) {
        attachments[index] = completed
      } else {
        attachments.append(completed)
      }
      attachmentTransferMessage = "Attached \(completed.displayName)"
    }

    private func controlActiveRun(stopping: Bool) async {
      guard let thread = selectedThread, let runID = activeRunID, !isControllingRun else { return }
      isControllingRun = true
      do {
        let output =
          if stopping {
            try await connection.stop(threadID: thread.id, runID: runID)
          } else {
            try await connection.interrupt(threadID: thread.id, runID: runID)
          }
        guard output.accepted else { throw OttoMobileConnectionError.invalidResponse }
      } catch {
        connectionState = .offline(error.localizedDescription)
      }
      isControllingRun = false
    }

    private func beginSync(threadID: UUID) {
      streamTask = Task { [weak self] in
        guard let self else { return }
        var attempt = 0
        while !Task.isCancelled {
          do {
            try await catchUp(threadID: threadID)
            guard !Task.isCancelled, selectedThread?.id == threadID else { return }
            connectionState = .live
            attempt = 0
            let stream = try await connection.eventStream(
              threadID: threadID,
              afterSequence: cursor
            )
            for try await event in stream {
              try await apply(event)
            }
            throw OttoMobileConnectionError.invalidResponse
          } catch is CancellationError {
            return
          } catch {
            guard !Task.isCancelled, selectedThread?.id == threadID else { return }
            attempt += 1
            connectionState = .reconnecting(attempt: attempt)
            let base = min(pow(2.0, Double(attempt - 1)), 20)
            let delay = base + Double.random(in: 0...(base * 0.25))
            try? await Task.sleep(for: .seconds(delay))
          }
        }
      }
    }

    private func catchUp(threadID: UUID) async throws {
      while selectedThread?.id == threadID {
        let page = try await connection.events(threadID: threadID, afterSequence: cursor)
        guard selectedThread?.id == threadID else { return }
        for event in page.events { try await apply(event) }
        if !page.hasMore { return }
      }
    }

    private func apply(_ event: RunEvent) async throws {
      guard event.threadID == selectedThread?.id else { return }
      guard appliedEventIDs.insert(event.id).inserted else { return }
      guard event.sequence > cursor else { return }
      guard event.sequence == cursor + 1 else {
        appliedEventIDs.remove(event.id)
        throw OttoMobileConnectionError.eventGap(expected: cursor + 1, received: event.sequence)
      }
      cursor = event.sequence
      switch event.kind {
      case .approvalRequested:
        pendingApproval = event.content.approval
      case .runStarted:
        activeRunID = event.content.runID
      case .runCompleted, .runFailed:
        activeRunID = nil
      case .runStateChanged, .threadStateChanged:
        if event.content.state != .approvalRequired { pendingApproval = nil }
        if event.content.state == .idle || event.content.state == .stopped
          || event.content.state == .done
          || event.content.state == .failed
        {
          activeRunID = nil
        } else if let runID = event.content.runID {
          activeRunID = runID
        }
      default:
        break
      }
      if let message = event.content.message {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
          messages[index] = message
        } else {
          messages.append(message)
        }
      }
      if let state = event.content.state, var thread = selectedThread {
        thread.state = state
        thread.lastEventSequence = cursor
        thread.updatedAt = event.timestamp
        selectedThread = thread
        if let index = threads.firstIndex(where: { $0.id == thread.id }) { threads[index] = thread }
      }
      if let threadTitle = selectedThread?.title
        ?? threads.first(where: { $0.id == event.threadID })?.title,
        let notification = OttoMobileNotificationDelivery(
          event: event,
          threadTitle: threadTitle
        )
      {
        await notifications.deliver(notification)
      }
      await persistSelectedThread()
      try? await cache.replace(home: cachedHome())
    }

    private func cachedHome() -> OttoMobileCachedHome {
      OttoMobileCachedHome(
        environment: environment,
        threads: threads,
        bots: bots,
        teams: teams,
        savedAt: .now
      )
    }

    private func persistSelectedThread() async {
      guard let selectedThread else { return }
      try? await cache.replace(
        thread: ThreadSnapshot(
          thread: selectedThread,
          messages: messages,
          lastEventSequence: cursor
        ))
    }
  }
#endif

#if canImport(SwiftUI)
  import OttoModels
  import OttoRPCContracts
  import SwiftUI
  import UniformTypeIdentifiers

  public struct OttoMobileRootView: View {
    @Bindable private var store: OttoMobileStore
    @Binding private var requestedThreadID: UUID?
    private var notificationPermission: OttoMobileNotificationPermissionState
    private var enableNotifications: () -> Void
    @State private var isShowingDiagnostics = false
    @State private var isShowingSecureLogin = false
    @Environment(\.scenePhase) private var scenePhase

    public init(
      store: OttoMobileStore,
      requestedThreadID: Binding<UUID?> = .constant(nil),
      notificationPermission: OttoMobileNotificationPermissionState = .unavailable,
      enableNotifications: @escaping () -> Void = {}
    ) {
      self.store = store
      _requestedThreadID = requestedThreadID
      self.notificationPermission = notificationPermission
      self.enableNotifications = enableNotifications
    }

    public var body: some View {
      NavigationStack {
        OttoMobileHomeScene(
          environment: store.environment,
          threads: store.threads,
          bots: store.bots,
          teams: store.teams,
          startingBotID: store.startingBotID,
          connectionState: store.connectionState,
          notificationPermission: notificationPermission,
          openThread: { thread in
            Task { await store.open(thread) }
          },
          startBot: { bot in
            Task { await store.start(bot) }
          },
          enableNotifications: enableNotifications,
          openDiagnostics: { isShowingDiagnostics = true }
        )
        .navigationDestination(
          isPresented: Binding(
            get: { store.selectedThread != nil },
            set: { if !$0 { store.closeThread() } }
          )
        ) {
          if let thread = store.selectedThread {
            OttoMobileThreadScene(
              thread: thread,
              messages: store.messages,
              connectionState: store.connectionState,
              draft: $store.composerText,
              isSending: store.isSending,
              sendError: store.sendError,
              sendMayHaveBeenAccepted: store.sendMayHaveBeenAccepted,
              canControlRun: store.activeRunID != nil,
              isControllingRun: store.isControllingRun,
              pendingApproval: store.pendingApproval,
              isRespondingToApproval: store.isRespondingToApproval,
              attachments: store.attachments,
              isTransferringAttachment: store.isTransferringAttachment,
              attachmentTransferMessage: store.attachmentTransferMessage,
              downloadedAttachmentID: store.downloadedAttachmentID,
              downloadedAttachmentURL: store.downloadedAttachmentURL
            ) {
              Task { await store.sendComposer() }
            } sendAsNewMessage: {
              Task { await store.sendComposer(asNewMessage: true) }
            } interrupt: {
              Task { await store.interruptActiveRun() }
            } stop: {
              Task { await store.stopActiveRun() }
            } approve: {
              Task { await store.respondToPendingApproval(.approveOnce) }
            } deny: {
              Task { await store.respondToPendingApproval(.deny) }
            } uploadAttachment: { url in
              Task { await store.uploadAttachment(from: url) }
            } uploadTextAttachment: { name, body in
              Task { await store.uploadTextAttachment(displayName: name, body: body) }
            } downloadAttachment: { attachment in
              Task { await store.downloadAttachment(attachment) }
            }
          }
        }
      }
      .toolbar {
        Button("Secure Sign-in", systemImage: "lock.shield") { isShowingSecureLogin = true }
      }
      .sheet(isPresented: $isShowingSecureLogin) { OttoMobileSecureLoginView(store: store) }
      .tint(OttoMobilePalette.coral)
      .sheet(isPresented: $isShowingDiagnostics) {
        OttoMobileDiagnosticsScene(
          diagnostics: store.diagnostics,
          isLoading: store.isLoadingDiagnostics,
          message: store.diagnosticsMessage,
          exportURL: store.diagnosticExportURL,
          refresh: { Task { await store.loadDiagnostics() } },
          prepareExport: { consent in
            Task { await store.prepareDiagnosticExport(consent: consent) }
          }
        )
        .task { await store.loadDiagnostics() }
      }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        await store.start()
        await openRequestedThread()
        await store.syncHome()
      }
      .onChange(of: requestedThreadID) {
        Task { await openRequestedThread() }
      }
    }

    private func openRequestedThread() async {
      guard let requestedThreadID else { return }
      await store.open(threadID: requestedThreadID)
      self.requestedThreadID = nil
    }
  }

  public struct OttoMobileHomeScene: View {
    public var environment: ExecutionEnvironment?
    public var threads: [OttoModels.Thread]
    public var bots: [MobileBotSummary]
    public var teams: [MobileTeamSummary]
    public var startingBotID: UUID?
    public var connectionState: OttoMobileConnectionState
    public var notificationPermission: OttoMobileNotificationPermissionState
    public var openThread: (OttoModels.Thread) -> Void
    public var startBot: (MobileBotSummary) -> Void
    public var enableNotifications: () -> Void
    public var openDiagnostics: () -> Void

    public init(
      environment: ExecutionEnvironment?,
      threads: [OttoModels.Thread],
      bots: [MobileBotSummary] = [],
      teams: [MobileTeamSummary] = [],
      startingBotID: UUID? = nil,
      connectionState: OttoMobileConnectionState,
      notificationPermission: OttoMobileNotificationPermissionState = .unavailable,
      openThread: @escaping (OttoModels.Thread) -> Void,
      startBot: @escaping (MobileBotSummary) -> Void = { _ in },
      enableNotifications: @escaping () -> Void = {},
      openDiagnostics: @escaping () -> Void = {}
    ) {
      self.environment = environment
      self.threads = threads
      self.bots = bots
      self.teams = teams
      self.startingBotID = startingBotID
      self.connectionState = connectionState
      self.notificationPermission = notificationPermission
      self.openThread = openThread
      self.startBot = startBot
      self.enableNotifications = enableNotifications
      self.openDiagnostics = openDiagnostics
    }

    public var body: some View {
      ZStack {
        OttoPaperBackground()
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 18) {
            header
            if notificationPermission == .unknown || notificationPermission == .denied {
              notificationCard
            }
            Text("SESSIONS")
              .font(.system(.caption2, design: .monospaced, weight: .semibold))
              .tracking(1.8)
              .foregroundStyle(OttoMobilePalette.mutedInk)
              .padding(.top, 14)
            if threads.isEmpty {
              emptyState
            } else {
              ForEach(threads) { thread in
                Button {
                  openThread(thread)
                } label: {
                  threadRow(thread)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(thread.title)
                .accessibilityValue("\(stateLabel(thread.state)), runs on this Mac")
                .accessibilityHint("Open conversation")
              }
            }
            roster
          }
          .padding(.horizontal, 22)
          .padding(.vertical, 26)
        }
      }
      .mobileHomeNavigationStyle()
    }

    private var notificationCard: some View {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: notificationPermission == .denied ? "bell.slash" : "bell.badge")
          .font(.title3)
          .foregroundStyle(OttoMobilePalette.moss)
          .frame(width: 32)
        VStack(alignment: .leading, spacing: 3) {
          Text(notificationPermission == .denied ? "ALERTS ARE OFF" : "ALERTS FROM THIS MAC")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(1.1)
          Text(
            notificationPermission == .denied
              ? "Open Settings to allow run updates."
              : "Know when a run finishes or needs you."
          )
          .font(.system(.caption, design: .serif))
          .foregroundStyle(OttoMobilePalette.mutedInk)
        }
        Spacer(minLength: 8)
        Button(notificationPermission == .denied ? "SETTINGS" : "TURN ON") {
          enableNotifications()
        }
        .font(.system(.caption2, design: .monospaced, weight: .bold))
        .foregroundStyle(OttoMobilePalette.coral)
        .accessibilityLabel(
          notificationPermission == .denied ? "Open notification settings" : "Turn on notifications"
        )
      }
      .padding(16)
      .ottoMobileGlassSurface(cornerRadius: 20, tint: OttoMobilePalette.moss, interactive: true)
    }

    private var roster: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          Text("BOTS & TEAMS")
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .tracking(1.8)
          Spacer()
          Text("\(bots.count) BOTS · \(teams.count) TEAMS")
            .font(.system(.caption2, design: .monospaced))
        }
        .foregroundStyle(OttoMobilePalette.mutedInk)

        ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
          Button {
            startBot(bot)
          } label: {
            HStack(spacing: 14) {
              Text(String(format: "%02d", index + 1))
                .font(.system(.caption, design: .monospaced, weight: .bold))
                .foregroundStyle(OttoMobilePalette.coral)
              VStack(alignment: .leading, spacing: 3) {
                Text(bot.name)
                  .font(.system(.headline, design: .serif, weight: .semibold))
                Text(bot.jobTitle ?? bot.provider.rawValue.uppercased())
                  .font(.system(.caption2, design: .monospaced, weight: .medium))
                  .foregroundStyle(OttoMobilePalette.mutedInk)
              }
              Spacer()
              Text(startingBotID == bot.id ? "OPENING…" : (bot.hasSession ? "RESUME" : "START"))
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(OttoMobilePalette.coral)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(startingBotID != nil)
          .accessibilityLabel("\(bot.hasSession ? "Resume" : "Start") \(bot.name)")
          Divider().overlay(OttoMobilePalette.rule)
        }

        if !teams.isEmpty {
          Text("SAVED TEAMS")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(1.3)
            .foregroundStyle(OttoMobilePalette.mutedInk)
            .padding(.top, 6)
          ForEach(teams) { team in
            Button {
              if let thread = threads.first(where: { $0.channelID == team.id }) {
                openThread(thread)
              }
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "person.3.sequence.fill")
                  .foregroundStyle(OttoMobilePalette.moss)
                VStack(alignment: .leading, spacing: 2) {
                  Text(team.name).font(.system(.subheadline, design: .serif, weight: .semibold))
                  Text("\(team.memberProfileIDs.count) MEMBERS")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(OttoMobilePalette.mutedInk)
                }
              }
              .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .disabled(!threads.contains { $0.channelID == team.id })
            .accessibilityLabel("Open \(team.name)")
          }
        }
      }
      .padding(18)
      .ottoMobileGlassSurface(cornerRadius: 26)
      .padding(.top, 10)
    }

    private var header: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("OTTO")
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(1.4)
          Spacer()
          ConnectionMark(state: connectionState)
        }
        Text("Your workspace.\nWithin reach.")
          .font(.system(.largeTitle, design: .serif, weight: .medium))
          .tracking(-1.2)
          .foregroundStyle(OttoMobilePalette.ink)
        HStack(spacing: 12) {
          Text(environment?.name ?? "Looking for this Mac…")
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(OttoMobilePalette.mutedInk)
          Spacer()
          if environment?.capabilities.contains(.diagnostics) == true {
            Button(action: openDiagnostics) {
              Label("MAC HEALTH", systemImage: "stethoscope")
                .font(.system(.caption2, design: .monospaced, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(OttoMobilePalette.coral)
            .accessibilityLabel("Mac health and diagnostics")
          }
        }
      }
    }

    private var emptyState: some View {
      VStack(alignment: .leading, spacing: 10) {
        Text("No open sessions yet")
          .font(.system(.title3, design: .serif, weight: .semibold))
        Text(
          bots.isEmpty
            ? "Create a bot in Otto on your Mac to get started."
            : "Choose a bot below to start a conversation. Your Mac keeps the work running."
        )
        .font(.system(.body, design: .rounded))
        .foregroundStyle(OttoMobilePalette.mutedInk)
      }
      .padding(20)
      .ottoMobileGlassSurface(cornerRadius: 24)
    }

    private func threadRow(_ thread: OttoModels.Thread) -> some View {
      HStack(alignment: .top, spacing: 15) {
        ZStack {
          Circle().fill(OttoMobilePalette.coral.opacity(0.14)).frame(width: 48, height: 48)
          Text(String(thread.title.prefix(1)).uppercased())
            .font(.system(.title3, design: .serif, weight: .bold))
            .foregroundStyle(OttoMobilePalette.coral)
        }
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(thread.title)
              .font(.system(.title3, design: .serif, weight: .semibold))
              .foregroundStyle(OttoMobilePalette.ink)
            Spacer()
            Text(thread.updatedAt, style: .relative)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(OttoMobilePalette.mutedInk)
          }
          HStack(spacing: 7) {
            Circle().fill(stateColor(thread.state)).frame(width: 7, height: 7)
            Text(stateLabel(thread.state))
            Text("·")
            Text("THIS MAC")
          }
          .font(.system(.caption, design: .monospaced, weight: .medium))
          .foregroundStyle(OttoMobilePalette.mutedInk)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(OttoMobilePalette.coral)
      }
      .padding(18)
      .ottoMobileGlassSurface(cornerRadius: 24, interactive: true)
    }
  }

  public struct OttoMobileDiagnosticsScene: View {
    @Environment(\.dismiss) private var dismiss
    public var diagnostics: MobileDiagnosticsOutput?
    public var isLoading: Bool
    public var message: String?
    public var exportURL: URL?
    public var refresh: () -> Void
    public var prepareExport: (Bool) -> Void
    @State private var consent = false

    public init(
      diagnostics: MobileDiagnosticsOutput?,
      isLoading: Bool,
      message: String?,
      exportURL: URL?,
      refresh: @escaping () -> Void,
      prepareExport: @escaping (Bool) -> Void
    ) {
      self.diagnostics = diagnostics
      self.isLoading = isLoading
      self.message = message
      self.exportURL = exportURL
      self.refresh = refresh
      self.prepareExport = prepareExport
    }

    public var body: some View {
      NavigationStack {
        ZStack {
          OttoPaperBackground()
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              intro
              if let diagnostics {
                crashCard(diagnostics)
                metricGrid(diagnostics)
                timeline(diagnostics)
                supportExport
              } else if isLoading {
                ProgressView("Reading privacy-safe Mac health…")
                  .font(.system(.caption, design: .monospaced))
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 24)
              } else {
                Button("TRY AGAIN", action: refresh)
                  .font(.system(.caption, design: .monospaced, weight: .bold))
              }
              if let message {
                Text(message)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(
                    exportURL == nil ? OttoMobilePalette.coral : OttoMobilePalette.moss
                  )
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            .padding(22)
          }
        }
        .navigationTitle("Mac health")
        .mobileInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
    }

    private var intro: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("LOCAL HEALTH / PRIVATE BY DEFAULT")
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .tracking(1.3)
          .foregroundStyle(OttoMobilePalette.coral)
        Text("What your Mac can safely tell you.")
          .font(.system(.title, design: .serif, weight: .semibold))
        Text(
          "No prompts, code, terminal output, paths, filenames, browser URLs, or voice transcripts are included."
        )
        .font(.system(.body, design: .default))
        .foregroundStyle(OttoMobilePalette.mutedInk)
        .fixedSize(horizontal: false, vertical: true)
      }
    }

    private func crashCard(_ value: MobileDiagnosticsOutput) -> some View {
      HStack(alignment: .top, spacing: 14) {
        Image(
          systemName: value.previousSessionAbnormal
            ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.seal.fill"
        )
        .font(.title2)
        .foregroundStyle(
          value.previousSessionAbnormal ? OttoMobilePalette.amber : OttoMobilePalette.moss)
        VStack(alignment: .leading, spacing: 5) {
          Text(
            value.previousSessionAbnormal
              ? "RECOVERED AFTER AN UNCLEAN EXIT" : "LAST SESSION CLOSED CLEANLY"
          )
          .font(.system(.caption, design: .monospaced, weight: .bold))
          Text(
            value.previousSessionAbnormal
              ? "Otto found the previous session marker and restored its local state."
              : "No abnormal previous session was detected on this Mac."
          )
          .font(.system(.caption, design: .rounded))
          .foregroundStyle(OttoMobilePalette.mutedInk)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .ottoMobileGlassSurface(
        cornerRadius: 20,
        tint: value.previousSessionAbnormal ? OttoMobilePalette.amber : OttoMobilePalette.moss
      )
    }

    private func metricGrid(_ value: MobileDiagnosticsOutput) -> some View {
      let latency = value.toolLatencyMedianMilliseconds.map { "\(Int($0.rounded())) MS" } ?? "—"
      return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
        metric("TOOL OK", String(value.toolSuccessCount), OttoMobilePalette.moss)
        metric("TOOL ERR", String(value.toolFailureCount), OttoMobilePalette.coral)
        metric("MEDIAN TOOL", latency, OttoMobilePalette.ink)
        metric("PROVIDER ERR", String(value.providerFailureCount), OttoMobilePalette.coral)
      }
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
      VStack(alignment: .leading, spacing: 5) {
        Text(label)
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .foregroundStyle(OttoMobilePalette.mutedInk)
        Text(value)
          .font(.system(.title2, design: .serif, weight: .semibold))
          .foregroundStyle(color)
      }
      .padding(15)
      .frame(maxWidth: .infinity, alignment: .leading)
      .ottoMobileGlassSurface(cornerRadius: 18, tint: color)
    }

    private func timeline(_ value: MobileDiagnosticsOutput) -> some View {
      VStack(alignment: .leading, spacing: 10) {
        Text("RECENT LOCAL EVENTS")
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .tracking(1.3)
          .foregroundStyle(OttoMobilePalette.mutedInk)
        if value.recentEvents.isEmpty {
          Text("No diagnostic events yet.")
            .font(.system(.caption, design: .rounded))
            .foregroundStyle(OttoMobilePalette.mutedInk)
        } else {
          ForEach(value.recentEvents.reversed()) { event in
            HStack(alignment: .firstTextBaseline, spacing: 9) {
              Circle()
                .fill(event.succeeded == false ? OttoMobilePalette.coral : OttoMobilePalette.moss)
                .frame(width: 7, height: 7)
              Text(diagnosticLabel(event))
                .font(.system(.caption, design: .monospaced))
              Spacer(minLength: 6)
              if let duration = event.durationMilliseconds {
                Text("\(Int(duration.rounded())) ms")
                  .font(.system(.caption2, design: .monospaced))
                  .foregroundStyle(OttoMobilePalette.mutedInk)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
    }

    private var supportExport: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("SUPPORT REPORT")
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .tracking(1.3)
        Text(
          "The report contains aggregate counts, versions, latency, and the crash marker. The event rows above are not exported."
        )
        .font(.system(.caption, design: .serif))
        .foregroundStyle(OttoMobilePalette.mutedInk)
        Toggle("I agree to share aggregate diagnostics", isOn: $consent)
          .font(.system(.caption, design: .rounded, weight: .semibold))
          .accessibilityIdentifier("diagnostics.consent")
        if let exportURL {
          ShareLink(item: exportURL) {
            Label("SHARE SUPPORT REPORT", systemImage: "square.and.arrow.up")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MobileDiagnosticActionStyle(filled: true))
          .accessibilityLabel("Share support report")
        } else {
          Button {
            prepareExport(consent)
          } label: {
            Label("PREPARE AGGREGATE REPORT", systemImage: "doc.badge.gearshape")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(MobileDiagnosticActionStyle(filled: false))
          .disabled(!consent)
          .accessibilityLabel("Prepare aggregate report")
        }
      }
      .padding(16)
      .ottoMobileGlassSurface(cornerRadius: 20)
    }

    private func diagnosticLabel(_ event: MobileDiagnosticEvent) -> String {
      switch event.kind {
      case .sessionStarted: "Session started"
      case .sessionEnded: "Session ended"
      case .previousSessionAbnormal: "Previous session ended unexpectedly"
      case .toolCall: event.toolName.map { "Tool · \($0)" } ?? "Tool call"
      case .agentStateChanged:
        event.agentState.map { "Agent · \($0.rawValue)" } ?? "Agent state changed"
      case .providerFailure:
        event.provider.map { "\($0.rawValue) provider failure" } ?? "Provider failure"
      case .resultExtracted: "Agent result extracted"
      case .voiceStateChanged: "Voice state changed"
      case .notification: "Notification sent"
      }
    }
  }

  public struct OttoMobileThreadScene: View {
    public var thread: OttoModels.Thread
    public var messages: [ThreadMessage]
    public var connectionState: OttoMobileConnectionState
    @Binding public var draft: String
    public var isSending: Bool
    public var sendError: String?
    public var sendMayHaveBeenAccepted: Bool
    public var canControlRun: Bool
    public var isControllingRun: Bool
    public var pendingApproval: MobileApprovalRequest?
    public var isRespondingToApproval: Bool
    public var attachments: [OttoAttachment]
    public var isTransferringAttachment: Bool
    public var attachmentTransferMessage: String?
    public var downloadedAttachmentID: UUID?
    public var downloadedAttachmentURL: URL?
    public var send: () -> Void
    public var sendAsNewMessage: () -> Void
    public var interrupt: () -> Void
    public var stop: () -> Void
    public var approve: () -> Void
    public var deny: () -> Void
    public var uploadAttachment: (URL) -> Void
    public var uploadTextAttachment: (String, String) -> Void
    public var downloadAttachment: (OttoAttachment) -> Void
    @State private var isShowingAttachmentImporter = false
    @State private var isShowingNoteComposer = false
    @State private var isConfirmingNewSend = false
    @State private var noteName = "Field note"
    @State private var noteBody = ""

    public init(
      thread: OttoModels.Thread,
      messages: [ThreadMessage],
      connectionState: OttoMobileConnectionState,
      draft: Binding<String>,
      isSending: Bool,
      sendError: String? = nil,
      sendMayHaveBeenAccepted: Bool = false,
      canControlRun: Bool = false,
      isControllingRun: Bool = false,
      pendingApproval: MobileApprovalRequest? = nil,
      isRespondingToApproval: Bool = false,
      attachments: [OttoAttachment] = [],
      isTransferringAttachment: Bool = false,
      attachmentTransferMessage: String? = nil,
      downloadedAttachmentID: UUID? = nil,
      downloadedAttachmentURL: URL? = nil,
      send: @escaping () -> Void,
      sendAsNewMessage: @escaping () -> Void = {},
      interrupt: @escaping () -> Void = {},
      stop: @escaping () -> Void = {},
      approve: @escaping () -> Void = {},
      deny: @escaping () -> Void = {},
      uploadAttachment: @escaping (URL) -> Void = { _ in },
      uploadTextAttachment: @escaping (String, String) -> Void = { _, _ in },
      downloadAttachment: @escaping (OttoAttachment) -> Void = { _ in }
    ) {
      self.thread = thread
      self.messages = messages
      self.connectionState = connectionState
      self._draft = draft
      self.isSending = isSending
      self.sendError = sendError
      self.sendMayHaveBeenAccepted = sendMayHaveBeenAccepted
      self.canControlRun = canControlRun
      self.isControllingRun = isControllingRun
      self.pendingApproval = pendingApproval
      self.isRespondingToApproval = isRespondingToApproval
      self.attachments = attachments
      self.isTransferringAttachment = isTransferringAttachment
      self.attachmentTransferMessage = attachmentTransferMessage
      self.downloadedAttachmentID = downloadedAttachmentID
      self.downloadedAttachmentURL = downloadedAttachmentURL
      self.send = send
      self.sendAsNewMessage = sendAsNewMessage
      self.interrupt = interrupt
      self.stop = stop
      self.approve = approve
      self.deny = deny
      self.uploadAttachment = uploadAttachment
      self.uploadTextAttachment = uploadTextAttachment
      self.downloadAttachment = downloadAttachment
    }

    public var body: some View {
      ZStack {
        OttoPaperBackground()
        VStack(spacing: 0) {
          threadHeader
          if canControlRun { runControls }
          if let pendingApproval { approvalCard(pendingApproval) }
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 18) {
                if messages.isEmpty { emptyThreadState }
                ForEach(messages) { message in
                  MessageRow(message: message).id(message.id)
                }
              }
              .padding(.horizontal, 20)
              .padding(.vertical, 22)
            }
            .onChange(of: messages.count) {
              if let last = messages.last {
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
              }
            }
            .onChange(of: attachments.count) {
              guard let last = messages.last else { return }
              Task { @MainActor in
                await Task.yield()
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
              }
            }
          }
          if !attachments.isEmpty || attachmentTransferMessage != nil { attachmentStrip }
          if let sendError {
            VStack(alignment: .leading, spacing: 8) {
              Label(sendError, systemImage: "exclamationmark.circle")
                .font(.subheadline)
              if sendMayHaveBeenAccepted {
                Button("Send as a new message…") { isConfirmingNewSend = true }
                  .disabled(
                    isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }
            }
            .foregroundStyle(OttoMobilePalette.coral)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityIdentifier("mobile-send-error")
          }
          composer
        }
      }
      .mobileThreadNavigationStyle()
      .confirmationDialog(
        "Send another copy?", isPresented: $isConfirmingNewSend, titleVisibility: .visible
      ) {
        Button("Send as a new message", action: sendAsNewMessage)
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "The Mac could not confirm the earlier attempt. Check the conversation first. Sending again could create a duplicate."
        )
      }
      .fileImporter(
        isPresented: $isShowingAttachmentImporter,
        allowedContentTypes: [.item],
        allowsMultipleSelection: false
      ) { result in
        guard case .success(let urls) = result, let url = urls.first else { return }
        uploadAttachment(url)
      }
      .sheet(isPresented: $isShowingNoteComposer) { attachmentNoteSheet }
    }

    private var emptyThreadState: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("NEW FIELD NOTE")
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .tracking(1.5)
          .foregroundStyle(OttoMobilePalette.coral)
        Text("What should \(thread.title) pick up?")
          .font(.system(.title2, design: .serif, weight: .semibold))
          .foregroundStyle(OttoMobilePalette.ink)
        Text(
          "Send a brief below. The work will run on this Mac with its existing tools, files, and credentials."
        )
        .font(.system(.body, design: .default))
        .foregroundStyle(OttoMobilePalette.mutedInk)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
      .ottoMobileGlassSurface(cornerRadius: 24)
    }

    private var runControls: some View {
      HStack(spacing: 10) {
        Button(action: interrupt) {
          Label("Interrupt", systemImage: "pause.fill").frame(maxWidth: .infinity)
        }
        Button(role: .destructive, action: stop) {
          Label("Stop run", systemImage: "stop.fill").frame(maxWidth: .infinity)
        }
      }
      .font(.system(.caption, design: .monospaced, weight: .bold))
      .foregroundStyle(OttoMobilePalette.ink)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5) }
      .disabled(isControllingRun)
      .opacity(isControllingRun ? 0.55 : 1)
    }

    private func approvalCard(_ request: MobileApprovalRequest) -> some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: "checkmark.shield.fill")
          Text("APPROVAL NEEDED")
            .tracking(1.2)
          Spacer()
          Text("ON THIS MAC")
        }
        .font(.system(.caption2, design: .monospaced, weight: .bold))
        .foregroundStyle(OttoMobilePalette.coral)

        Text(request.reason)
          .font(.system(.body, design: .serif, weight: .semibold))
          .foregroundStyle(OttoMobilePalette.ink)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          "Approve once resumes only this waiting action. Nothing is queued while your Mac is offline."
        )
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(OttoMobilePalette.mutedInk)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 10) {
          Button("DENY", action: deny)
            .buttonStyle(MobileApprovalButtonStyle(filled: false))
            .accessibilityLabel("Deny approval")
          Button("APPROVE ONCE", action: approve)
            .buttonStyle(MobileApprovalButtonStyle(filled: true))
            .accessibilityLabel("Approve once")
        }
        .disabled(isRespondingToApproval)
        .opacity(isRespondingToApproval ? 0.55 : 1)
      }
      .padding(16)
      .background(.ultraThinMaterial)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5) }
    }

    private var threadHeader: some View {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(thread.title)
            .font(.system(.title2, design: .serif, weight: .semibold))
            .foregroundStyle(OttoMobilePalette.ink)
          Text("RUNS ON · THIS MAC")
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .tracking(1)
            .foregroundStyle(OttoMobilePalette.mutedInk)
        }
        Spacer()
        ConnectionMark(state: connectionState)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .background(.ultraThinMaterial)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5) }
    }

    private var composer: some View {
      HStack(alignment: .bottom, spacing: 10) {
        if thread.kind != .group {
          Menu {
            Button("Choose File", systemImage: "folder") {
              isShowingAttachmentImporter = true
            }
            Button("New Text Note", systemImage: "square.and.pencil") {
              noteName = "Field note"
              noteBody = ""
              isShowingNoteComposer = true
            }
          } label: {
            Image(systemName: "paperclip")
              .font(.headline.weight(.semibold))
              .foregroundStyle(OttoMobilePalette.coral)
              .frame(width: 42, height: 46)
              .ottoMobileGlassSurface(cornerRadius: 17, interactive: true)
          }
          .accessibilityLabel("Attach a file")
          .disabled(isTransferringAttachment || connectionState != .live)
        }
        composerInput
          .accessibilityLabel("Message \(thread.title)")
          .lineLimit(1...5)
          .font(.system(.body, design: .rounded))
          .padding(.horizontal, 16)
          .padding(.vertical, 13)
          .ottoMobileGlassSurface(cornerRadius: 20, interactive: true)
        Button(action: send) {
          Image(systemName: isSending ? "ellipsis" : "arrow.up")
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(OttoMobilePalette.coral.opacity(0.78), in: Circle())
            .ottoMobileGlassSurface(
              cornerRadius: 23, tint: OttoMobilePalette.coral, interactive: true)
        }
        .accessibilityLabel("Send message")
        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.regularMaterial)
    }

    @ViewBuilder private var composerInput: some View {
      #if os(iOS)
        ZStack(alignment: .topLeading) {
          if draft.isEmpty {
            Text("Reply to \(thread.title)…")
              .foregroundStyle(OttoMobilePalette.mutedInk)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
          OttoMobileComposer(text: $draft, label: "Message \(thread.title)", send: send)
        }
      #else
        TextField("Reply to \(thread.title)…", text: $draft, axis: .vertical)
          .submitLabel(.send)
          .onSubmit { send() }
      #endif
    }

    private var attachmentNoteSheet: some View {
      NavigationStack {
        ZStack {
          OttoPaperBackground()
          VStack(alignment: .leading, spacing: 16) {
            Text("ATTACH A TEXT NOTE")
              .font(.system(.caption, design: .monospaced, weight: .bold))
              .tracking(1.4)
              .foregroundStyle(OttoMobilePalette.coral)
            TextField("File name", text: $noteName)
              .accessibilityLabel("Attachment file name")
              .textFieldStyle(.roundedBorder)
            TextEditor(text: $noteBody)
              .accessibilityLabel("Attachment note text")
              .font(.system(.body, design: .rounded))
              .scrollContentBackground(.hidden)
              .padding(10)
              .ottoMobileGlassSurface(cornerRadius: 18, interactive: true)
            Text("The note is uploaded in verified chunks and stored with this Mac session.")
              .font(.system(.caption, design: .rounded))
              .foregroundStyle(OttoMobilePalette.mutedInk)
          }
          .padding(20)
        }
        .navigationTitle("New attachment")
        .mobileInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { isShowingNoteComposer = false }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Attach Note") {
              uploadTextAttachment(noteName, noteBody)
              isShowingNoteComposer = false
            }
            .disabled(
              noteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
          }
        }
      }
    }

    private var attachmentStrip: some View {
      VStack(alignment: .leading, spacing: 8) {
        if !attachments.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(attachments) { attachment in
                HStack(spacing: 7) {
                  Image(systemName: "doc.fill")
                  VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.displayName)
                      .lineLimit(1)
                    Text(
                      ByteCountFormatter.string(
                        fromByteCount: attachment.byteCount,
                        countStyle: .file
                      )
                    )
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(OttoMobilePalette.mutedInk)
                  }
                  if downloadedAttachmentID == attachment.id, let downloadedAttachmentURL {
                    ShareLink(item: downloadedAttachmentURL) {
                      Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share \(attachment.displayName)")
                  } else {
                    Button {
                      downloadAttachment(attachment)
                    } label: {
                      Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download \(attachment.displayName)")
                  }
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(OttoMobilePalette.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .ottoMobileGlassSurface(cornerRadius: 15, interactive: true)
              }
            }
            .padding(.horizontal, 16)
          }
        }
        if let attachmentTransferMessage {
          Text(attachmentTransferMessage)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(OttoMobilePalette.mutedInk)
            .padding(.horizontal, 18)
        }
      }
      .padding(.vertical, 8)
      .background(.regularMaterial)
      .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5) }
    }
  }

  /// A deterministic, non-interactive rendering of the thread scene for visual regression checks.
  /// It deliberately avoids native scrolling and text controls, whose macOS renderer differs from
  /// iPhone, while sharing the production message rows, palette, and connection treatment.
  public struct OttoMobileThreadVisualFixture: View {
    public var thread: OttoModels.Thread
    public var messages: [ThreadMessage]
    public var connectionState: OttoMobileConnectionState

    public init(
      thread: OttoModels.Thread,
      messages: [ThreadMessage],
      connectionState: OttoMobileConnectionState
    ) {
      self.thread = thread
      self.messages = messages
      self.connectionState = connectionState
    }

    public var body: some View {
      ZStack {
        OttoPaperBackground()
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text(thread.title)
                .font(.system(.title2, design: .serif, weight: .semibold))
              Text("RUNS ON · THIS MAC")
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .tracking(1)
                .foregroundStyle(OttoMobilePalette.mutedInk)
            }
            Spacer()
            ConnectionMark(state: connectionState)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 14)
          .background(.ultraThinMaterial)
          .overlay(alignment: .bottom) {
            Rectangle().fill(OttoMobilePalette.rule).frame(height: 1)
          }

          VStack(alignment: .leading, spacing: 18) {
            ForEach(messages) { MessageRow(message: $0) }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 22)

          HStack(spacing: 10) {
            Text("Reply from the train…")
              .font(.system(.body, design: .rounded))
              .foregroundStyle(OttoMobilePalette.mutedInk)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 16)
              .padding(.vertical, 13)
              .ottoMobileGlassSurface(cornerRadius: 20)
            Image(systemName: "arrow.up")
              .font(.headline.weight(.bold))
              .foregroundStyle(.white)
              .frame(width: 46, height: 46)
              .background(OttoMobilePalette.coral.opacity(0.78), in: Circle())
              .ottoMobileGlassSurface(cornerRadius: 23, tint: OttoMobilePalette.coral)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .background(.regularMaterial)
        }
      }
    }
  }

  private struct MessageRow: View {
    let message: ThreadMessage

    var body: some View {
      switch message.role {
      case .user:
        HStack {
          Spacer(minLength: 44)
          Text(message.text)
            .font(.system(.body, design: .rounded))
            .foregroundStyle(OttoMobilePalette.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .ottoMobileGlassSurface(
              cornerRadius: 20,
              tint: OttoMobilePalette.userBubble,
              interactive: true
            )
        }
      case .assistant:
        VStack(alignment: .leading, spacing: 8) {
          Text((message.author?.displayName ?? "OTTO").uppercased())
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(OttoMobilePalette.coral)
          Text(message.text)
            .font(.system(.body, design: .default))
            .foregroundStyle(OttoMobilePalette.ink)
            .textSelection(.enabled)
        }
        .padding(.trailing, 28)
      case .activity, .system:
        HStack(alignment: .top, spacing: 9) {
          Image(systemName: "sparkle")
            .font(.caption)
            .foregroundStyle(OttoMobilePalette.moss)
          Text(message.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(OttoMobilePalette.mutedInk)
        }
        .padding(.vertical, 4)
      }
    }
  }

  private struct MobileApprovalButtonStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(.system(.caption, design: .monospaced, weight: .bold))
        .foregroundStyle(filled ? Color.white : OttoMobilePalette.coral)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
          filled ? OttoMobilePalette.coral : OttoMobilePalette.coral.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .stroke(OttoMobilePalette.coral.opacity(filled ? 0 : 0.65), lineWidth: 1)
        }
        .opacity(configuration.isPressed ? 0.72 : 1)
    }
  }

  private struct MobileDiagnosticActionStyle: ButtonStyle {
    let filled: Bool

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(.system(.caption, design: .monospaced, weight: .bold))
        .foregroundStyle(filled ? Color.white : OttoMobilePalette.coral)
        .padding(.vertical, 12)
        .background(
          filled ? OttoMobilePalette.coral : OttoMobilePalette.coral.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 13)
            .stroke(OttoMobilePalette.coral.opacity(filled ? 0 : 0.65), lineWidth: 1)
        }
        .opacity(configuration.isPressed ? 0.72 : 1)
    }
  }

  private struct ConnectionMark: View {
    let state: OttoMobileConnectionState

    var body: some View {
      HStack(spacing: 6) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label)
          .font(.system(.caption2, design: .monospaced, weight: .bold))
          .tracking(0.8)
      }
      .foregroundStyle(OttoMobilePalette.mutedInk)
    }

    private var color: Color {
      switch state {
      case .live: OttoMobilePalette.moss
      case .connecting, .reconnecting: OttoMobilePalette.amber
      case .offline: OttoMobilePalette.coral
      }
    }

    private var label: String {
      switch state {
      case .live: "LIVE"
      case .connecting: "CONNECTING"
      case .reconnecting: "RECONNECTING"
      case .offline: "OFFLINE"
      }
    }
  }

  private struct OttoPaperBackground: View {
    var body: some View {
      OttoMobileGlassBackdrop()
    }
  }

  private enum OttoMobilePalette {
    static let paper = Color.clear
    static let card = Color.clear
    static let ink = Color.primary
    static let mutedInk = Color.secondary
    static let coral = OttoMobileGlassPalette.accent
    static let moss = OttoMobileGlassPalette.success
    static let amber = OttoMobileGlassPalette.warning
    static let rule = Color.primary.opacity(0.12)
    static let userBubble = OttoMobileGlassPalette.accent
  }

  private func stateColor(_ state: ThreadState) -> Color {
    switch state {
    case .working: OttoMobilePalette.amber
    case .waitingForUser, .approvalRequired, .failed: OttoMobilePalette.coral
    case .idle, .done: OttoMobilePalette.moss
    case .stopped, .hostOffline: OttoMobilePalette.mutedInk
    }
  }

  private func stateLabel(_ state: ThreadState) -> String {
    switch state {
    case .idle: "IDLE"
    case .working: "WORKING"
    case .waitingForUser: "NEEDS YOU"
    case .approvalRequired: "APPROVAL"
    case .failed: "FAILED"
    case .done: "DONE"
    case .stopped: "STOPPED"
    case .hostOffline: "OFFLINE"
    }
  }

  extension View {
    @ViewBuilder fileprivate func mobileHomeNavigationStyle() -> some View {
      #if os(iOS)
        navigationBarHidden(true)
      #else
        self
      #endif
    }

    @ViewBuilder fileprivate func mobileThreadNavigationStyle() -> some View {
      #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
          .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      #else
        self
      #endif
    }

    @ViewBuilder fileprivate func mobileInlineNavigationTitle() -> some View {
      #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
      #else
        self
      #endif
    }
  }
#endif

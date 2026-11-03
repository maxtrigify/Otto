import Foundation
import OttoApplicationTools
import OttoBrowser
import OttoCore
import OttoDocuments
import OttoMemory
import OttoModels
import OttoRPCContracts
import OttoRuntime
import OttoServices
import OttoTools
import OttoVoice

/// Desktop-only surfaces (Home and Documents) for the owner's own Otto Desktop. These are kept
/// out of the shared host RPC so paired phones can never reach them. Each stdin line of the form
/// `{"token": "...", "desktop": {"id": "...", "method": "...", "params": {...}}}` is answered with
/// `{"id": "...", "result": ...}` or `{"id": "...", "error": {"code", "message"}}`.
@MainActor
struct DesktopAPI {
  let services: ApplicationServices
  /// The workspace's canvas store, which owns the shared theme.
  let store: CanvasStore
  /// Talk to Otto; nil when the engine runs without a desktop (tests, headless).
  var voice: DesktopVoice? = nil

  struct Call: Decodable {
    var id: String
    var method: String
    var params: OpaqueCodableValue?
  }

  struct Reply<Result: Encodable>: Encodable {
    var id: String
    var result: Result
  }

  struct Failure: Encodable {
    struct Detail: Encodable {
      var code: String
      var message: String
    }
    var id: String
    var error: Detail
  }

  enum APIError: Error, LocalizedError {
    case unknownMethod(String)
    case notFound(String)
    case invalid(String)

    var errorDescription: String? {
      switch self {
      case .unknownMethod(let method): "Unknown desktop method \(method)."
      case .notFound(let what): "\(what) was not found."
      case .invalid(let reason): reason
      }
    }
  }

  /// Runs one call and returns the encoded reply line.
  func handle(_ call: Call) async -> Data {
    let encoder = OttoRPCCodec.encoder
    do {
      return try await dispatch(call, encoder: encoder)
    } catch {
      let code =
        if case APIError.unknownMethod = error { "unknown_method" } else { "failed" }
      return
        (try? encoder.encode(
          Failure(id: call.id, error: .init(code: code, message: error.localizedDescription))))
        ?? Data()
    }
  }

  private func dispatch(_ call: Call, encoder: JSONEncoder) async throws -> Data {
    func reply<Result: Encodable>(_ result: Result) throws -> Data {
      try encoder.encode(Reply(id: call.id, result: result))
    }
    func params<Value: Decodable>(_ type: Value.Type) throws -> Value {
      try OttoRPCCodec.decode(type, from: call.params ?? .object([:]))
    }
    switch call.method {
    // ---- Home ----------------------------------------------------------------------------
    case "home.snapshot":
      return try reply(homeSnapshot())
    case "brief.addTodo":
      let input = try params(TitleInput.self)
      _ = try services.dailyBrief.addTodo(
        title: input.title, profileID: services.dailyBrief.selectedProfile.id)
      return try reply(homeSnapshot())
    case "brief.complete":
      let input = try params(BriefCompleteInput.self)
      try services.dailyBrief.setCompleted(input.id, input.completed)
      return try reply(homeSnapshot())
    case "brief.dismiss":
      let input = try params(IDInput.self)
      try services.dailyBrief.dismiss(input.id)
      return try reply(homeSnapshot())
    case "review.approve":
      let input = try params(ReviewInput.self)
      try await services.approveReview(id: try uuid(input.id), editedDraft: input.text)
      return try reply(homeSnapshot())
    case "review.reject":
      let input = try params(ReviewInput.self)
      try services.rejectReview(id: try uuid(input.id), reason: input.text)
      return try reply(homeSnapshot())
    case "review.comment":
      let input = try params(ReviewInput.self)
      try await services.commentOnReview(id: try uuid(input.id), text: input.text ?? "")
      return try reply(homeSnapshot())

    // ---- Automations ---------------------------------------------------------------------
    case "automations.list":
      return try reply(automations())
    case "automations.setEnabled":
      let input = try params(EnableInput.self)
      guard var routine = services.routines.routine(id: try uuid(input.id)) else {
        throw APIError.notFound("Automation")
      }
      routine.enabled = input.enabled
      _ = try await services.saveRoutine(routine)
      return try reply(automations())
    case "automations.create":
      let input = try params(AutomationCreateInput.self)
      let trigger: RoutineTrigger =
        if let cron = input.cron, !cron.isEmpty {
          .schedule(cron: cron, intervalSeconds: nil)
        } else {
          .schedule(cron: nil, intervalSeconds: max(60, (input.everyMinutes ?? 60) * 60))
        }
      let target: RoutineTarget =
        if let botID = input.botID { .spawnProfile(profileID: try uuid(botID)) } else {
          .spawnProvider(provider: input.provider ?? "Claude Code")
        }
      _ = try await services.saveRoutine(
        Routine(
          name: input.name, instruction: input.instruction, trigger: trigger, target: target,
          enabled: input.enabled ?? false))
      return try reply(automations())
    case "automations.delete":
      let input = try params(IDInput.self)
      try services.deleteRoutine(id: try uuid(input.id))
      return try reply(automations())
    case "automations.runNow":
      let input = try params(IDInput.self)
      _ = try await services.testRoutine(id: try uuid(input.id))
      return try reply(automations())

    // ---- Dashboards and cards --------------------------------------------------------------
    case "dashboards.snapshot":
      return try reply(dashboards())
    case "dashboards.create":
      let input = try params(NameInput.self)
      _ = try services.homeCards.createDashboard(name: input.name)
      return try reply(dashboards())
    case "dashboards.rename":
      let input = try params(RenameInput.self)
      try services.homeCards.renameDashboard(id: try uuid(input.id), to: input.name)
      return try reply(dashboards())
    case "dashboards.delete":
      let input = try params(IDInput.self)
      _ = try services.homeCards.deleteDashboard(id: try uuid(input.id))
      return try reply(dashboards())
    case "dashboards.setLook":
      let input = try params(DashboardLookInput.self)
      try services.homeCards.updateDashboard(id: try uuid(input.id)) { dashboard in
        if let accent = input.accent { dashboard.accent = HomeCardColor(rawValue: accent) }
        if let style = input.cardStyle { dashboard.cardStyle = Dashboard.CardStyle(rawValue: style) }
      }
      return try reply(dashboards())
    case "cards.add":
      let input = try params(CardAddInput.self)
      guard let style = HomeCard.Style(rawValue: input.style ?? "list") else {
        throw APIError.invalid("Unknown card style")
      }
      _ = try services.homeCards.add(
        HomeCard(
          title: input.title, style: style, rows: (input.rows ?? []).map(\.row), text: input.text,
          updatedBy: "You", dashboardID: try input.dashboardID.map(uuid)))
      return try reply(dashboards())
    case "cards.setLook":
      let input = try params(CardLookInput.self)
      _ = try services.homeCards.update(id: try uuid(input.id)) { card in
        if let width = input.width { card.width = HomeCard.Width(rawValue: width) }
        if let color = input.color { card.color = HomeCardColor(rawValue: color) }
      }
      return try reply(dashboards())
    case "cards.move":
      let input = try params(CardMoveInput.self)
      try services.homeCards.move(id: try uuid(input.id), by: input.offset)
      return try reply(dashboards())
    case "cards.remove":
      let input = try params(IDInput.self)
      _ = try services.homeCards.remove(id: try uuid(input.id))
      return try reply(dashboards())

    // ---- Browser -------------------------------------------------------------------------
    // The same browser nodes bots use (browser.* tools); the desktop renders them through
    // DesktopBrowserBridge and reports page loads back here.
    case "browser.list":
      return try reply(await browsers())
    case "browser.open":
      let input = try params(BrowserURLInput.self)
      if let nodeID = input.nodeID.flatMap(UUID.init(uuidString:)) ?? browserNodes().last?.id {
        try await tool("browser.open_tab", BrowserOpenTabInput(url: input.url, nodeID: nodeID))
      } else {
        try await tool("browser.open", BrowserOpenInput(url: input.url, x: 0, y: 0))
      }
      return try reply(await browsers())
    case "browser.navigate":
      let input = try params(BrowserURLInput.self)
      guard let nodeID = input.nodeID else { throw APIError.invalid("nodeID is required") }
      try await tool("browser.navigate", BrowserNavigateInput(nodeID: try uuid(nodeID), url: input.url))
      return try reply(await browsers())
    case "browser.back", "browser.forward", "browser.refresh":
      let input = try params(IDInput.self)
      try await tool(call.method, BrowserNodeInput(nodeID: try uuid(input.id)))
      return try reply(await browsers())
    case "browser.selectTab":
      let input = try params(BrowserTabInput.self)
      try await selectTab(nodeID: try uuid(input.nodeID), tabID: try uuid(input.tabID))
      return try reply(await browsers())
    case "browser.closeTab":
      let input = try params(BrowserTabInput.self)
      try await closeTab(nodeID: try uuid(input.nodeID), tabID: try uuid(input.tabID))
      return try reply(await browsers())
    case "browser.close":
      let input = try params(IDInput.self)
      try await services.closeNode(nodeID: try uuid(input.id))
      return try reply(await browsers())
    case "browser.inspect":
      // What a bot sees with browser.inspect, for the desktop's own checks.
      let input = try params(IDInput.self)
      return try reply(
        try await services.registry.call(
          name: "browser.inspect", input: try JSONValue.encode(BrowserNodeInput(nodeID: try uuid(input.id))),
          context: desktopContext))
    // The bot tools themselves, so the desktop's checks drive a page exactly as a bot does.
    case "browser.click":
      let input = try params(BrowserElementCall.self)
      return try reply(
        try await services.registry.call(
          name: "browser.click",
          input: try JSONValue.encode(
            BrowserElementInput(nodeID: try uuid(input.id), elementID: input.element)),
          context: desktopContext))
    case "browser.type":
      let input = try params(BrowserElementCall.self)
      return try reply(
        try await services.registry.call(
          name: "browser.type",
          input: try JSONValue.encode(
            BrowserTypeInput(
              nodeID: try uuid(input.id), elementID: input.element, text: input.text ?? "")),
          context: desktopContext))
    case "browser.screenshot":
      let input = try params(IDInput.self)
      return try reply(
        try await services.registry.call(
          name: "browser.screenshot",
          input: try JSONValue.encode(BrowserNodeInput(nodeID: try uuid(input.id))),
          context: desktopContext))
    case "browser.reportLoaded":
      let input = try params(BrowserLoadReport.self)
      try await reportLoaded(input)
      return try reply(true)

    // ---- Teams ---------------------------------------------------------------------------
    // Group rooms of bots. Their chats are ordinary threads (kind "group") on the host RPC;
    // these methods cover what the Mac's Create/Edit team sheet does.
    case "teams.roster":
      return try reply(
        services.botRoster().map {
          TeamMemberOption(
            id: $0.profile.id, name: $0.profile.name, handle: $0.profile.handle,
            jobTitle: $0.profile.jobTitle, provider: $0.profile.provider.rawValue)
        })
    case "teams.get":
      let input = try params(IDInput.self)
      return try reply(TeamDetails(try team(try uuid(input.id))))
    case "teams.create":
      let input = try params(TeamInput.self)
      let channel = try services.createTeam(
        memberProfileIDs: try input.memberProfileIDs.map(uuid), name: input.name,
        instructions: input.instructions,
        orchestratorProfileID: try input.orchestratorProfileID.map(uuid),
        permissionMode: input.permission)
      return try reply(TeamDetails(channel))
    case "teams.update":
      let input = try params(TeamInput.self)
      guard let id = input.id else { throw APIError.invalid("id is required") }
      let channel = try services.updateTeam(
        channelID: try uuid(id), name: input.name, instructions: input.instructions,
        memberProfileIDs: try input.memberProfileIDs.map(uuid),
        orchestratorProfileID: try input.orchestratorProfileID.map(uuid),
        permissionMode: input.permission)
      return try reply(TeamDetails(channel))
    case "teams.delete":
      let input = try params(IDInput.self)
      _ = try team(try uuid(input.id))
      try services.deleteTeam(channelID: try uuid(input.id))
      return try reply(true)

    // ---- Voice ---------------------------------------------------------------------------
    case "voice.status":
      return try reply(try requireVoice().status())
    case "voice.configure":
      let input = try params(VoiceConfigureInput.self)
      let voice = try requireVoice()
      voice.configure(provider: try input.kind(), voice: input.voice)
      return try reply(voice.status())
    case "voice.setKey":
      let input = try params(VoiceKeyInput.self)
      let voice = try requireVoice()
      try await voice.setKey(input.key, for: try input.kind())
      return try reply(voice.status())
    case "voice.talk":
      let voice = try requireVoice()
      await voice.talk()
      return try reply(voice.status())
    case "voice.sleep":
      let voice = try requireVoice()
      await voice.sleep()
      return try reply(voice.status())
    case "voice.interrupt":
      let voice = try requireVoice()
      await voice.interrupt()
      return try reply(voice.status())

    // ---- Activity ------------------------------------------------------------------------
    case "activity.snapshot":
      return try reply(
        ActivitySnapshot(
          needsYou: services.botActivity.needsUser, active: services.botActivity.active))

    // ---- Files & notes -------------------------------------------------------------------
    case "files.list":
      return try reply(noteFiles())
    case "files.read":
      let input = try params(PathInput.self)
      return try reply(NoteContent(path: input.path, text: try await services.documents.read(relativePath: input.path)))
    case "files.save":
      let input = try params(DocumentSaveInput.self)
      try await services.documents.replace(relativePath: input.path, text: input.text)
      return try reply(NoteContent(path: input.path, text: input.text))

    // ---- Appearance ----------------------------------------------------------------------
    // The workspace's theme, shared with the Mac app (the active canvas's themeID).
    case "appearance.get":
      return try reply(appearance())
    case "appearance.set":
      let input = try params(ThemeInput.self)
      store.dispatch(.setTheme(input.themeID))
      return try reply(appearance())

    // ---- Memory --------------------------------------------------------------------------
    case "memory.snapshot":
      return try reply(await memorySnapshot())
    case "memory.addPersonal":
      let input = try params(TextInput.self)
      let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw APIError.notFound("Memory text") }
      _ = try await services.personalMemory.add(
        CompactMemoryEntry(id: "desktop-\(UUID().uuidString.prefix(8).lowercased())", text: text, source: "user"))
      return try reply(await memorySnapshot())
    case "memory.removePersonal":
      let input = try params(IDInput.self)
      _ = try await services.personalMemory.remove(id: input.id)
      return try reply(await memorySnapshot())
    case "memory.removeOperating":
      let input = try params(IDInput.self)
      _ = try await services.operatingMemory.remove(id: input.id)
      return try reply(await memorySnapshot())

    // ---- Documents -----------------------------------------------------------------------
    case "documents.list":
      services.office.refresh()
      return try reply(services.office.files.map(DocumentSummary.init))
    case "documents.create":
      let input = try params(DocumentCreateInput.self)
      guard let kind = OfficeKind(rawValue: input.kind) else {
        throw APIError.notFound("Document kind \(input.kind)")
      }
      let file = try services.office.create(kind, title: input.title)
      return try reply(DocumentSummary(file))
    case "documents.read":
      let input = try params(PathInput.self)
      guard let file = services.office.file(path: input.path) else {
        throw APIError.notFound(input.path)
      }
      switch file.kind {
      case .document:
        return try reply(
          DocumentContent(
            file: DocumentSummary(file), text: try services.office.documentText(path: file.path)))
      case .spreadsheet:
        return try reply(
          DocumentContent(
            file: DocumentSummary(file), sheet: try services.office.loadSheet(path: file.path)))
      case .presentation:
        return try reply(
          DocumentContent(
            file: DocumentSummary(file), deck: try services.office.loadDeck(path: file.path)))
      }
    case "documents.saveText":
      let input = try params(DocumentSaveInput.self)
      guard let file = services.office.file(path: input.path), file.kind == .document else {
        throw APIError.notFound(input.path)
      }
      try services.office.saveDocument(NSAttributedString(string: input.text), path: file.path)
      services.office.refresh()
      return try reply(DocumentSummary(services.office.file(path: file.path) ?? file))
    default:
      throw APIError.unknownMethod(call.method)
    }
  }

  private func homeSnapshot() -> HomeSnapshot {
    let now = Date.now
    let brief = services.dailyBrief.compose(
      derived: services.derivedBriefItems(now: now), legacyProjectID: services.legacyProjectID,
      now: now)
    return HomeSnapshot(
      profile: services.dailyBrief.selectedProfile.name,
      todos: brief.todos, updates: brief.updates, events: brief.events,
      completedTodayCount: brief.completedTodayCount,
      cards: services.homeCards.cards,
      reviews: services.homeReviews.open)
  }

  /// What Otto remembers: the person (About me), workspace habits, and the project brain.
  private func memorySnapshot() async -> MemorySnapshot {
    let records = ((try? await services.brain?.allRecords()) ?? [])
      .filter { $0.status == .active }
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(300)
    return MemorySnapshot(
      personal: await services.personalMemory.entries(),
      operating: await services.operatingMemory.entries(),
      brain: records.map(BrainRecordSummary.init))
  }

  private var desktopContext: ToolContext {
    ToolContext(
      actorID: "otto-desktop", scopes: Set(ToolScope.allCases), confirmed: true,
      source: .userInterface)
  }

  private func tool<Input: Encodable & Sendable>(_ name: String, _ input: Input) async throws {
    _ = try await services.registry.call(
      name: name, input: try JSONValue.encode(input), context: desktopContext)
  }

  private func browserNodes() -> [OttoNode] {
    store.snapshot.canvases.flatMap(\.nodes).filter { $0.kind == .browser }
  }

  private func browsers() async -> [BrowserSummary] {
    var summaries: [BrowserSummary] = []
    for node in browserNodes() {
      let session = node.browserSession ?? BrowserSession(url: BrowserDefaults.blankURL)
      let state =
        await services.browserRuntime.state(nodeID: node.id)
        ?? BrowserRuntimeState(
          nodeID: node.id, url: session.activeTab?.url ?? BrowserDefaults.blankURL,
          title: session.activeTab?.title,
          tabs: session.tabs.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) },
          activeTabID: session.activeTabID)
      summaries.append(BrowserSummary(nodeID: node.id, name: node.displayName, state: state))
    }
    return summaries
  }

  private func session(of nodeID: UUID) throws -> (BrowserSession, UUID) {
    guard let node = browserNodes().first(where: { $0.id == nodeID }),
      let canvasID = store.canvasID(containing: nodeID)
    else { throw APIError.notFound("Browser") }
    return (node.browserSession ?? BrowserSession(url: BrowserDefaults.blankURL), canvasID)
  }

  /// As the Mac's tab strip does: the session records the choice, the runtime shows the tab.
  private func selectTab(nodeID: UUID, tabID: UUID) async throws {
    var (session, canvasID) = try session(of: nodeID)
    guard let tab = session.tabs.first(where: { $0.id == tabID }) else {
      throw APIError.notFound("Tab")
    }
    session.activeTabID = tabID
    store.dispatch(.setBrowserSession(id: nodeID, session: session), targetCanvasID: canvasID)
    try await services.browserRuntime.activateTab(
      nodeID: nodeID, tab: BrowserRuntimeTab(id: tab.id, url: tab.url, title: tab.title))
  }

  private func closeTab(nodeID: UUID, tabID: UUID) async throws {
    var (session, canvasID) = try session(of: nodeID)
    guard let index = session.tabs.firstIndex(where: { $0.id == tabID }) else {
      throw APIError.notFound("Tab")
    }
    let wasActive = session.activeTabID == tabID
    session.tabs.remove(at: index)
    if session.tabs.isEmpty {
      let replacement = BrowserTab()
      session.tabs = [replacement]
      session.activeTabID = replacement.id
    } else if wasActive {
      session.activeTabID = session.tabs[min(index, session.tabs.count - 1)].id
    }
    store.dispatch(.setBrowserSession(id: nodeID, session: session), targetCanvasID: canvasID)
    let active = session.activeTab
    try await services.browserRuntime.closeTab(
      nodeID: nodeID, tabID: tabID,
      activating: wasActive
        ? active.map { BrowserRuntimeTab(id: $0.id, url: $0.url, title: $0.title) } : nil)
  }

  /// A tab finished (or failed) loading in the desktop: keep the runtime and the saved session
  /// in step so bots see the real URL and tabs reopen where they were.
  private func reportLoaded(_ report: BrowserLoadReport) async throws {
    let nodeID = try uuid(report.nodeID)
    let tabID = try uuid(report.tabID)
    let runtime = services.browserRuntime
    if let state = await runtime.state(nodeID: nodeID), state.activeTabID == tabID {
      try await runtime.reportLoaded(
        nodeID: nodeID, url: report.url, title: report.title, canGoBack: report.canGoBack,
        canGoForward: report.canGoForward, isLoading: report.isLoading,
        errorMessage: report.error, expectedRevision: report.revision)
    }
    guard !report.isLoading, let (saved, canvasID) = try? session(of: nodeID),
      let index = saved.tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    var session = saved
    let title = report.title?.isEmpty == false ? report.title! : session.tabs[index].title
    guard session.tabs[index].url != report.url || session.tabs[index].title != title else {
      return
    }
    session.tabs[index].url = report.url
    session.tabs[index].title = title
    store.dispatch(.setBrowserSession(id: nodeID, session: session), targetCanvasID: canvasID)
  }

  private func requireVoice() throws -> DesktopVoice {
    guard let voice else { throw APIError.invalid("Voice needs Otto Desktop") }
    return voice
  }

  private func team(_ channelID: UUID) throws -> BotChannel {
    guard let channel = services.botChannels.channel(id: channelID), channel.kind == .group,
      !channel.archived
    else { throw APIError.notFound("Team") }
    return channel
  }

  private func dashboards() -> DashboardsSnapshot {
    DashboardsSnapshot(
      dashboards: services.homeCards.dashboards,
      cards: services.homeCards.allCards.filter { $0.dashboardID != nil })
  }

  private func automations() -> AutomationsSnapshot {
    let routines = services.routines.routines.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    return AutomationsSnapshot(
      automations: routines.map(AutomationSummary.init),
      runs: services.routines.recentRuns(limit: 40))
  }

  /// Markdown and text notes in the workspace (what the Mac lists under Files & notes), skipping
  /// Otto's own state, version control and dependency folders.
  private func noteFiles() -> [NoteSummary] {
    let root = URL(fileURLWithPath: services.defaultWorkspacePath, isDirectory: true)
    let skipped: Set<String> = [".otto", ".muse", ".git", "node_modules", ".build", ".trash"]
    guard
      let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var notes: [NoteSummary] = []
    for case let url as URL in walker {
      if skipped.contains(url.lastPathComponent) {
        walker.skipDescendants()
        continue
      }
      guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { continue }
      let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      notes.append(
        NoteSummary(
          path: relative, title: url.deletingPathExtension().lastPathComponent, modifiedAt: modified))
      if notes.count >= 500 { break }
    }
    return notes.sorted { $0.modifiedAt > $1.modifiedAt }
  }

  private func appearance() -> Appearance {
    let theme = OttoThemeCatalog.theme(id: store.activeCanvas.themeID)
    return Appearance(
      theme: theme,
      material: theme.resolvedSurfaceMaterial.rawValue,
      isLight: theme.isLightAppearance,
      scrimFloor: theme.scrimFloorOpacity,
      scrimDeep: theme.scrimDeepOpacity,
      chromeBandOpacity: theme.chromeBandOpacity,
      themes: OttoThemeCatalog.all.map { ThemeChoice(id: $0.id, name: $0.displayName) })
  }

  private func uuid(_ text: String) throws -> UUID {
    guard let id = UUID(uuidString: text) else { throw APIError.notFound(text) }
    return id
  }
}

// MARK: - Payloads

struct TitleInput: Decodable { var title: String }
struct TextInput: Decodable { var text: String }
struct ThemeInput: Decodable { var themeID: String }
struct NameInput: Decodable { var name: String }
struct VoiceConfigureInput: Decodable {
  var provider: String
  var voice: String?

  func kind() throws -> VoiceProviderKind {
    guard let kind = VoiceProviderKind(rawValue: provider) else {
      throw DesktopAPI.APIError.invalid("Unknown voice provider")
    }
    return kind
  }
}
/// A null or empty key removes the saved one.
struct VoiceKeyInput: Decodable {
  var provider: String
  var key: String?

  func kind() throws -> VoiceProviderKind {
    try VoiceConfigureInput(provider: provider).kind()
  }
}
struct TeamMemberOption: Encodable {
  var id: UUID
  var name: String
  var handle: String
  var jobTitle: String?
  var provider: String
}
/// "unrestricted" (the Mac's default for teams), "workspaceWrite", "readOnly", or null for each
/// bot's own setting.
struct TeamInput: Decodable {
  var id: String?
  var name: String?
  var instructions: String?
  var memberProfileIDs: [String]
  var orchestratorProfileID: String?
  var permissionMode: String?

  var permission: AgentPermissionMode? { permissionMode.flatMap(AgentPermissionMode.init(rawValue:)) }
}
struct TeamDetails: Encodable {
  var id: UUID
  var threadID: UUID
  var name: String?
  var instructions: String?
  var memberProfileIDs: [UUID]
  var orchestratorProfileID: UUID?
  var permissionMode: String?

  init(_ channel: BotChannel) {
    id = channel.id
    threadID = channel.conversationID
    name = channel.name
    instructions = channel.instructions
    memberProfileIDs = channel.memberProfileIDs
    orchestratorProfileID = channel.orchestratorProfileID
    permissionMode = channel.permissionMode
  }
}
struct BrowserURLInput: Decodable {
  var url: String
  var nodeID: String?
}
struct BrowserElementCall: Decodable {
  var id: String
  var element: String
  var text: String?
}
struct BrowserTabInput: Decodable {
  var nodeID: String
  var tabID: String
}
struct BrowserLoadReport: Decodable {
  var nodeID: String
  var tabID: String
  var url: String
  var title: String?
  var canGoBack: Bool
  var canGoForward: Bool
  var isLoading: Bool
  var error: String?
  var revision: Int?
}
struct BrowserSummary: Encodable {
  var nodeID: UUID
  var name: String
  var state: BrowserRuntimeState
}
struct RenameInput: Decodable {
  var id: String
  var name: String
}
/// Empty strings clear a colour or style back to the default.
struct DashboardLookInput: Decodable {
  var id: String
  var accent: String?
  var cardStyle: String?
}
struct CardAddInput: Decodable {
  var dashboardID: String?
  var title: String
  var style: String?
  var rows: [CardRowInput]?
  var text: String?
}
struct CardRowInput: Decodable {
  var label: String
  var value: String?
  var detail: String?
  var url: String?
  var history: [Double]?

  var row: HomeCardRow {
    HomeCardRow(label: label, value: value, detail: detail, url: url, history: history ?? [])
  }
}
struct CardLookInput: Decodable {
  var id: String
  var width: String?
  var color: String?
}
struct CardMoveInput: Decodable {
  var id: String
  var offset: Int
}
struct DashboardsSnapshot: Encodable {
  var dashboards: [Dashboard]
  var cards: [HomeCard]
}

struct AutomationCreateInput: Decodable {
  var name: String
  var instruction: String
  var everyMinutes: Int?
  var cron: String?
  var botID: String?
  var provider: String?
  var enabled: Bool?
}
struct EnableInput: Decodable {
  var id: String
  var enabled: Bool
}

struct AutomationSummary: Encodable {
  var id: UUID
  var name: String
  var instruction: String
  var trigger: String
  var enabled: Bool
  var lastFiredAt: Date?
  var fireCount: Int
  var lastError: String?

  init(_ routine: Routine) {
    id = routine.id
    name = routine.name
    instruction = routine.instruction
    trigger = Self.scheduleLabel(routine)
    enabled = routine.enabled
    lastFiredAt = routine.lastFiredAt
    fireCount = routine.fireCount
    lastError = routine.lastError
  }
}

extension AutomationSummary {
  /// The Mac's wording (AutomationsView.scheduleLabel), so both apps describe a schedule alike.
  static func scheduleLabel(_ routine: Routine) -> String {
    if routine.runAfter != nil { return "After another automation" }
    switch routine.trigger {
    case .schedule(let cron?, _): return cronLabel(cron) ?? "Custom schedule"
    case .schedule(nil, let seconds?):
      return seconds % 3600 == 0 ? "Every \(seconds / 3600)h" : "Every \(max(1, seconds / 60)) min"
    case .schedule: return "On a schedule"
    case .webhook: return "When a webhook arrives"
    case .agentEvent: return "When an agent event happens"
    case .slackMessage: return "On a Slack message"
    case .discordMessage: return "On a Discord message"
    case .gitEvent: return "On a git change"
    }
  }

  static func cronLabel(_ cron: String) -> String? {
    let parts = cron.split(separator: " ").map(String.init)
    guard parts.count == 5, parts[2] == "*", parts[3] == "*", let minute = Int(parts[0]) else {
      return nil
    }
    if parts[1] == "*" { return "Every hour" }
    guard let hour = Int(parts[1]) else { return nil }
    let clock = String(format: "%02d:%02d", hour, minute)
    switch parts[4] {
    case "*": return "Every day at \(clock)"
    case "1-5": return "Weekdays at \(clock)"
    default:
      guard let day = Int(parts[4]), (0...6).contains(day) else { return nil }
      return "\(Calendar.current.weekdaySymbols[day])s at \(clock)"
    }
  }
}

struct AutomationsSnapshot: Encodable {
  var automations: [AutomationSummary]
  var runs: [RoutineRunRecord]
}

struct ActivitySnapshot: Encodable {
  var needsYou: [BotActivityItem]
  var active: [BotActivityItem]
}

struct NoteSummary: Encodable {
  var path: String
  var title: String
  var modifiedAt: Date
}

struct NoteContent: Encodable {
  var path: String
  var text: String
}

struct ThemeChoice: Encodable {
  var id: String
  var name: String
}

/// The theme as the Mac draws it: the definition plus the derived readability values.
struct Appearance: Encodable {
  var theme: OttoThemeDefinition
  var material: String
  var isLight: Bool
  var scrimFloor: Double
  var scrimDeep: Double
  var chromeBandOpacity: Double
  var themes: [ThemeChoice]
}
struct IDInput: Decodable { var id: String }
struct PathInput: Decodable { var path: String }
struct BriefCompleteInput: Decodable {
  var id: String
  var completed: Bool
}
struct ReviewInput: Decodable {
  var id: String
  /// The edited draft when approving, the reason when rejecting, the comment when commenting.
  var text: String?
}
struct DocumentCreateInput: Decodable {
  var kind: String
  var title: String
}
struct DocumentSaveInput: Decodable {
  var path: String
  var text: String
}

struct HomeSnapshot: Encodable {
  var profile: String
  var todos: [BriefItem]
  var updates: [BriefItem]
  var events: [BriefItem]
  var completedTodayCount: Int
  var cards: [HomeCard]
  var reviews: [HomeReview]
}

struct DocumentSummary: Encodable {
  var path: String
  var kind: String
  var title: String
  var modifiedAt: Date

  init(_ file: OfficeFile) {
    path = file.path
    kind = file.kind.rawValue
    title = file.title
    modifiedAt = file.modifiedAt
  }
}

struct DocumentContent: Encodable {
  var file: DocumentSummary
  var text: String?
  var sheet: Spreadsheet?
  var deck: Presentation?
}

struct MemorySnapshot: Encodable {
  var personal: [CompactMemoryEntry]
  var operating: [CompactMemoryEntry]
  var brain: [BrainRecordSummary]
}

struct BrainRecordSummary: Encodable {
  var id: String
  var type: String
  var title: String
  var body: String
  var updatedAt: Date
  var tags: [String]

  init(_ record: MemoryRecord) {
    id = record.id
    type = record.type.rawValue
    title = record.title
    body = record.body
    updatedAt = record.updatedAt
    tags = record.tags
  }
}

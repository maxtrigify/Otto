import Foundation
import OttoCore
import OttoDocuments
import OttoMemory
import OttoModels
import OttoRPCContracts
import OttoServices

/// Desktop-only surfaces (Home and Documents) for the owner's own Otto Desktop. These are kept
/// out of the shared host RPC so paired phones can never reach them. Each stdin line of the form
/// `{"token": "...", "desktop": {"id": "...", "method": "...", "params": {...}}}` is answered with
/// `{"id": "...", "result": ...}` or `{"id": "...", "error": {"code", "message"}}`.
@MainActor
struct DesktopAPI {
  let services: ApplicationServices
  /// The workspace's canvas store, which owns the shared theme.
  let store: CanvasStore

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

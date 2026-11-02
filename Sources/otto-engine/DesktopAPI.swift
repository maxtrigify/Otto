import Foundation
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

    var errorDescription: String? {
      switch self {
      case .unknownMethod(let method): "Unknown desktop method \(method)."
      case .notFound(let what): "\(what) was not found."
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

  private func uuid(_ text: String) throws -> UUID {
    guard let id = UUID(uuidString: text) else { throw APIError.notFound(text) }
    return id
  }
}

// MARK: - Payloads

struct TitleInput: Decodable { var title: String }
struct TextInput: Decodable { var text: String }
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

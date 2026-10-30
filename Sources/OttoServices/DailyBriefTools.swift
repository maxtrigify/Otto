#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
import OttoApplicationTools
import OttoModels
import OttoTools

public struct BriefAddInput: Codable, Sendable {
  public struct Item: Codable, Sendable {
    public var kind: String?
    public var title: String
    public var reason: String?
    public var source: String?
    public var people: [String]?
    public var time: String?
    public var end: String?
    public var needsYou: Bool?
    public var url: String?
    public init(
      kind: String? = nil, title: String, reason: String? = nil, source: String? = nil,
      people: [String]? = nil, time: String? = nil, end: String? = nil, needsYou: Bool? = nil,
      url: String? = nil
    ) {
      self.kind = kind
      self.title = title
      self.reason = reason
      self.source = source
      self.people = people
      self.time = time
      self.end = end
      self.needsYou = needsYou
      self.url = url
    }
  }
  public var items: [Item]
  public var profile: String?
  public init(items: [Item], profile: String? = nil) {
    self.items = items
    self.profile = profile
  }
}

public struct BriefAddOutput: Codable, Sendable, Equatable {
  public var added: Int
  public var profile: String?
  public var note: String
}

public struct BriefListInput: Codable, Sendable {
  public var profile: String?
  public init(profile: String? = nil) { self.profile = profile }
}

public struct BriefListOutput: Codable, Sendable, Equatable {
  public var profile: String
  public var profiles: [String]
  public var todos: [BriefItem]
  public var updates: [BriefItem]
  public var events: [BriefItem]
}

private let briefItemSchema = JSONValue.objectSchema(
  properties: [
    "kind": .stringSchema(description: "todo, update or event"),
    "title": .stringSchema(
      description: "Short, action-phrased headline, e.g. Reply to Jo on pricing"),
    "reason": .stringSchema(description: "One or two sentences on why this matters today"),
    "source": .stringSchema(description: "Where it came from, e.g. Google Calendar, Gmail, Slack"),
    "people": .object([
      "type": .string("array"), "items": .object(["type": .string("string")]),
    ]),
    "time": .stringSchema(description: "ISO 8601 start time for events or deadline for to-dos"),
    "end": .stringSchema(description: "ISO 8601 end time for events"),
    "needsYou": .object(["type": .string("boolean")]),
    "url": .stringSchema(description: "Optional https link to the original"),
  ], required: ["title"])

public struct BriefAddTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "brief.add",
    description:
      "Adds items to the user's daily brief on Otto Home. Only add things with real value today: a decision or reply the user owes, a meeting, a deadline, or an update they would want to know. Never add filler or confirmations that nothing happened. Re-adding the same title replaces the earlier item.",
    inputSchema: .objectSchema(
      properties: [
        "items": .object(["type": .string("array"), "items": briefItemSchema]),
        "profile": .stringSchema(
          description:
            "Optional Home profile name, e.g. Work or Personal. Omit to use your project."
        ),
      ], required: ["items"]),
    outputSchema: .objectSchema(), requiredScopes: [.canvasWrite], riskLevel: .reversible)
  private let handler: @Sendable (BriefAddInput, ToolContext) async throws -> BriefAddOutput
  public init(
    handler: @escaping @Sendable (BriefAddInput, ToolContext) async throws -> BriefAddOutput
  ) { self.handler = handler }
  public func call(_ input: BriefAddInput, context: ToolContext) async throws -> BriefAddOutput {
    try await handler(input, context)
  }
}

public struct BriefListTool: OttoTool {
  public static let definition = ToolDefinition(
    name: "brief.list",
    description:
      "Reads the user's current daily brief for a Home profile so you can avoid duplicates.",
    inputSchema: .objectSchema(
      properties: ["profile": .stringSchema(description: "Optional Home profile name")]),
    outputSchema: .objectSchema(), requiredScopes: [.agentRead], riskLevel: .read)
  private let handler: @Sendable (BriefListInput, ToolContext) async throws -> BriefListOutput
  public init(
    handler: @escaping @Sendable (BriefListInput, ToolContext) async throws -> BriefListOutput
  ) { self.handler = handler }
  public func call(_ input: BriefListInput, context: ToolContext) async throws -> BriefListOutput {
    try await handler(input, context)
  }
}

extension ApplicationServices {
  /// The default instruction for a profile's Otto-managed morning brief routine.
  public static func morningBriefInstruction(profileName: String) -> String {
    """
    Prepare the user's \(profileName) morning brief from the tools you can reach (calendar, \
    email, chat, tasks, CRM, analytics). Read only; do not send, reply, accept or change anything.

    Include only what has real value today:
    - event: today's meetings that have not ended yet, with start/end times and who is \
    attending. Leave out finished ones and never add notes like "(done)" to titles.
    - todo: replies or decisions the user owes, with the deadline if there is one.
    - update: news they would want, saying plainly when nothing is needed from them.
    Give each item a short action-phrased title and a one or two sentence reason.
    At most 5 todos, 5 updates and every event today.

    Reply with only a fenced JSON block:
    ```json
    {"items":[{"kind":"event","title":"Acme pricing call","reason":"Jo wants a decision on seats.","source":"Google Calendar","people":["Jo"],"time":"2026-01-01T11:00:00Z","end":"2026-01-01T11:30:00Z","needsYou":true}]}
    ```
    If none of your tools have anything worth the user's attention, reply exactly [SILENT].
    """
  }

  func registerBriefTools() async throws {
    try await registry.register(
      BriefAddTool { [weak self] input, context in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.addBriefItems(input, context: context)
      })
    try await registry.register(
      BriefListTool { [weak self] input, _ in
        guard let self else { throw ToolRegistryError.invalidInput("Otto unavailable") }
        return try await self.listBrief(input)
      })
  }

  @MainActor
  private func addBriefItems(_ input: BriefAddInput, context: ToolContext) throws -> BriefAddOutput
  {
    guard !input.items.isEmpty else {
      throw ToolRegistryError.invalidInput("Add at least one item")
    }
    guard input.items.count <= 20 else {
      throw ToolRegistryError.invalidInput("Add at most 20 items at a time")
    }
    var profileID: UUID?
    if let name = input.profile, !name.isEmpty {
      guard let profile = dailyBrief.profile(named: name) else {
        throw ToolRegistryError.invalidInput(
          "Unknown Home profile. Use one of: \(dailyBrief.profiles.map(\.name).joined(separator: ", "))"
        )
      }
      profileID = profile.id
    }
    let projectID =
      profileID == nil
      ? context.sourceNodeID.flatMap { projectChannel(nodeID: $0) }
        .map { conversationProjects.context(channelID: $0) }?.projectID
      : nil
    let originKey = context.sourceNodeID?.uuidString ?? context.actorID
    let items = input.items.compactMap { item -> BriefItem? in
      let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }
      let kind = BriefItemKind(rawValue: (item.kind ?? "update").lowercased()) ?? .update
      let time = item.time.flatMap(Self.briefDate)
      let digest = SHA256.hash(
        data: Data("\(kind.rawValue)|\(title.lowercased())|\(item.time ?? "")".utf8))
      let id = "agent:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
      var action: BriefAction?
      if let url = item.url, url.hasPrefix("https://") { action = .openURL(url) }
      return BriefItem(
        id: id, kind: kind, title: String(title.prefix(160)),
        reason: item.reason.map { String($0.prefix(600)) }, source: item.source,
        people: item.people ?? [], time: time, endTime: item.end.flatMap(Self.briefDate),
        needsYou: item.needsYou ?? false, projectID: projectID, profileID: profileID,
        origin: .agent(originKey), action: action)
    }
    try dailyBrief.add(items)
    return BriefAddOutput(
      added: items.count, profile: profileID.flatMap { dailyBrief.profile(id: $0)?.name },
      note: "Added to the brief on Otto Home.")
  }

  @MainActor
  private func listBrief(_ input: BriefListInput) throws -> BriefListOutput {
    var profile = dailyBrief.selectedProfile
    if let name = input.profile, !name.isEmpty {
      guard let named = dailyBrief.profile(named: name) else {
        throw ToolRegistryError.invalidInput("Unknown Home profile")
      }
      profile = named
    }
    let legacy = conversationProjects.projects.first { $0.isLegacyWorkspace }?.id
    let brief = dailyBrief.compose(derived: [], profile: profile, legacyProjectID: legacy)
    return BriefListOutput(
      profile: profile.name, profiles: dailyBrief.profiles.map(\.name), todos: brief.todos,
      updates: brief.updates, events: brief.events)
  }

  /// Routine results delivered to the brief replace that routine's earlier open items.
  @MainActor
  func deliverRoutineResultToBrief(_ routine: Routine, profileID: UUID?, result: String) throws {
    var items = BriefOutputParser.parse(
      result, origin: .routine(routine.id), profileID: profileID, sourceName: routine.name)
    guard !items.isEmpty else { return }
    if let account = briefAccountLabel(for: routine, profileID: profileID) {
      for index in items.indices {
        let source = items[index].source ?? "Morning brief"
        if !source.contains(account) { items[index].source = "\(source) · \(account)" }
      }
    }
    try dailyBrief.replace(origin: .routine(routine.id), with: items)
  }

  static func briefDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
  }
}

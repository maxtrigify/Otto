import Foundation
import Testing

@testable import OttoModels

@Suite("Daily brief composition")
struct DailyBriefTests {
  private let now = ISO8601DateFormatter().date(from: "2026-10-07T09:00:00Z")!
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func compose(
    _ items: [BriefItem], profile: HomeProfile = HomeProfile(name: "Home"),
    legacy: UUID? = nil, dismissed: Set<String> = []
  ) -> DailyBrief {
    DailyBriefComposer.compose(
      candidates: items, profile: profile, legacyProjectID: legacy, dismissedIDs: dismissed,
      now: now, calendar: calendar)
  }

  @Test("Profiles only see their projects; unattributed work belongs to the legacy project")
  func profileScoping() {
    let work = UUID()
    let personal = UUID()
    let legacy = UUID()
    let workProfile = HomeProfile(name: "Work", projectIDs: [work, legacy])
    let personalProfile = HomeProfile(name: "Personal", projectIDs: [personal])
    let items = [
      BriefItem(id: "w", kind: .todo, title: "Ship", projectID: work, origin: .otto),
      BriefItem(id: "p", kind: .todo, title: "Pay rent", projectID: personal, origin: .user),
      BriefItem(id: "u", kind: .todo, title: "Unfiled", origin: .otto),
      BriefItem(
        id: "owned", kind: .todo, title: "Owned", projectID: work, profileID: personalProfile.id,
        origin: .user),
    ]
    #expect(
      compose(items, profile: workProfile, legacy: legacy).todos.map(\.id).sorted() == ["u", "w"])
    #expect(
      compose(items, profile: personalProfile, legacy: legacy).todos.map(\.id).sorted()
        == ["owned", "p"])
    #expect(compose(items, legacy: legacy).todos.count == 3)
  }

  @Test("Stale updates, finished meetings, dismissed and completed items are not shown")
  func valueGate() {
    let items = [
      BriefItem(
        id: "old", kind: .update, title: "Old", origin: .otto,
        createdAt: now.addingTimeInterval(-30 * 60 * 60)),
      BriefItem(
        id: "fresh", kind: .update, title: "Fresh", origin: .otto,
        createdAt: now.addingTimeInterval(-60 * 60)),
      BriefItem(
        id: "past", kind: .event, title: "Standup", time: now.addingTimeInterval(-2 * 3600),
        endTime: now.addingTimeInterval(-3600), origin: .user),
      BriefItem(
        id: "later", kind: .event, title: "Pricing call", time: now.addingTimeInterval(2 * 3600),
        origin: .user),
      BriefItem(
        id: "tomorrow", kind: .event, title: "Tomorrow", time: now.addingTimeInterval(26 * 3600),
        origin: .user),
      BriefItem(id: "gone", kind: .todo, title: "Dismissed", origin: .otto),
      BriefItem(
        id: "done", kind: .todo, title: "Done", origin: .user,
        completedAt: now.addingTimeInterval(-60)),
    ]
    let brief = compose(items, dismissed: ["gone"])
    #expect(brief.updates.map(\.id) == ["fresh"])
    #expect(brief.events.map(\.id) == ["later"])
    #expect(brief.todos.isEmpty)
    #expect(brief.completedTodayCount == 1)
    #expect(compose([]).isEmpty)
    #expect(compose([]).headline == nil)
  }

  @Test("Decisions lead, then deadlines, and the headline counts what matters")
  func ordering() {
    let items = [
      BriefItem(id: "plain", kind: .todo, title: "Plain", origin: .user, createdAt: now),
      BriefItem(
        id: "deadline", kind: .todo, title: "Deadline", time: now.addingTimeInterval(3600),
        origin: .user),
      BriefItem(id: "decide", kind: .todo, title: "Decide", needsYou: true, origin: .otto),
      BriefItem(id: "u", kind: .update, title: "News", origin: .otto, createdAt: now),
    ]
    let brief = compose(items)
    #expect(brief.todos.map(\.id) == ["decide", "deadline", "plain"])
    #expect(brief.headline == "1 needs you · 2 to-dos · 1 update")
    let flagged = compose(
      items + [
        BriefItem(
          id: "broken", kind: .update, title: "Run failed", needsYou: true, origin: .otto,
          createdAt: now)
      ])
    #expect(flagged.headline == "2 need you · 2 to-dos · 1 update")
    #expect(flagged.updates.first?.id == "broken")
  }

  @Test("Agent output parses fenced JSON, stays silent, and keeps plain text as one update")
  func parsing() throws {
    let profile = UUID()
    let routine = UUID()
    let json = """
      Here is the brief.
      ```json
      {"items":[{"kind":"event","title":"Acme call","reason":"Seats decision","time":"2026-10-07T11:00:00Z","end":"2026-10-07T11:30:00Z","people":["Jo"],"needsYou":true,"url":"https://cal.example/1"},
                {"kind":"bogus","title":"  "},{"title":"Invoice paid"}]}
      ```
      """
    let items = BriefOutputParser.parse(
      json, origin: .routine(routine), profileID: profile, sourceName: "Morning brief", now: now)
    #expect(items.count == 2)
    let event = try #require(items.first)
    #expect(event.kind == .event)
    #expect(event.people == ["Jo"])
    #expect(event.needsYou)
    #expect(event.profileID == profile)
    #expect(event.action == .openURL("https://cal.example/1"))
    #expect(event.endTime == ISO8601DateFormatter().date(from: "2026-10-07T11:30:00Z"))
    #expect(items[1].kind == .update)
    #expect(items[1].source == "Morning brief")

    #expect(BriefOutputParser.parse("[SILENT]", origin: .user, profileID: nil).isEmpty)
    let plain = BriefOutputParser.parse(
      "## Stripe check\n- **2** failed payments\n- retry tonight", origin: .user, profileID: nil)
    #expect(plain.map(\.title) == ["Stripe check"])
    #expect(plain.first?.reason == "2 failed payments retry tonight")
  }

  @Test("Saved items decode when optional fields are missing")
  func decoding() throws {
    let data = Data(
      """
      {"id":"a","kind":"todo","title":"T","origin":{"user":{}},"createdAt":0}
      """.utf8)
    let item = try JSONDecoder().decode(BriefItem.self, from: data)
    #expect(item.people.isEmpty)
    #expect(!item.needsYou)
    let encoded = try JSONEncoder().encode(item)
    #expect(try JSONDecoder().decode(BriefItem.self, from: encoded) == item)
  }

  @Test("Repeated headlines collapse and only the latest updates are shown")
  func updatesStayShort() {
    var items = (0..<15).map { index in
      BriefItem(
        id: "u\(index)", kind: .update, title: "Update \(index)", origin: .otto,
        createdAt: now.addingTimeInterval(Double(-index * 60)))
    }
    items.append(
      BriefItem(
        id: "dup", kind: .update, title: "update 0", origin: .otto,
        createdAt: now.addingTimeInterval(-30)))
    let brief = compose(items)
    #expect(brief.updates.count == DailyBriefComposer.maxUpdates)
    #expect(brief.updates.filter { $0.title.lowercased() == "update 0" }.count == 1)
    #expect(brief.updates.first?.id == "u0")
  }
}

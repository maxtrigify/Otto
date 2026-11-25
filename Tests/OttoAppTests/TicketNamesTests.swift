import Foundation
import Testing

@testable import OttoApp

@Suite("Ticket wording")
struct TicketNamesTests {
  @Test("A permission request reads without the harness's internal tool names")
  func plainRequest() {
    #expect(
      TicketNames.plainRequest("Wants to use mcp__otto__bot_list") == "Use Otto’s bot.list tool")
    #expect(
      TicketNames.plainRequest("Wants to use mcp__otto__calendar_create_event")
        == "Use Otto’s calendar.create_event tool")
    #expect(TicketNames.plainRequest("Run `rm -rf build`") == "Run `rm -rf build`")
    #expect(TicketNames.plainRequest("") == "")
  }

  @Test("Ages are short and never negative")
  func ago() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(TicketNames.ago(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(TicketNames.ago(now.addingTimeInterval(-600), now: now) == "10 min")
    #expect(TicketNames.ago(now.addingTimeInterval(-7_200), now: now) == "2 h")
    #expect(TicketNames.ago(now.addingTimeInterval(-200_000), now: now) == "2 d")
    #expect(TicketNames.ago(now.addingTimeInterval(60), now: now) == "just now")
  }
}

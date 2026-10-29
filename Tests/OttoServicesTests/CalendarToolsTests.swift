import Foundation
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

private actor CalendarRequests {
  var requests: [URLRequest] = []
  func call(_ request: URLRequest) -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (
      Data("{\"items\": []}".utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
  func last() -> URLRequest? { requests.last }
}

@MainActor
@Suite("Google Calendar connection", .serialized)
struct CalendarToolsTests {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-calendar-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func account(scopes: Set<String>) -> GmailConnection {
    GmailConnection(
      id: UUID(), email: "fixture@example.com", scopes: scopes,
      needsReconnect: false, shared: true, createdAt: .now)
  }

  private func credential() -> GoogleCredential {
    GoogleCredential(
      accessToken: UUID().uuidString, refreshToken: UUID().uuidString,
      expiresAt: .now.addingTimeInterval(3600),
      clientID: "fixture.apps.googleusercontent.com")
  }

  @Test("Calendar requests go to the Calendar API with the caller's time range")
  func calendarRequestURL() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = CalendarRequests()
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await calls.call($0) }))
    let connected = account(scopes: [AppConnectionsStore.calendarReadScope])
    try await apps.install(connected, credential: credential())

    _ = try await apps.request(
      account: connected, path: "calendars/primary/events",
      query: [URLQueryItem(name: "timeMin", value: "2026-10-29T00:00:00Z")],
      base: AppConnectionsStore.calendarBaseURL)

    let url = try #require(await calls.last()?.url?.absoluteString)
    #expect(url.hasPrefix("https://www.googleapis.com/calendar/v3/calendars/primary/events"))
    #expect(url.contains("timeMin=2026-10-29T00:00:00Z"))
  }

  @Test("Calendar tools need an account granted calendar scopes; Gmail-only accounts are skipped")
  func calendarScopeGate() async throws {
    let root = try root()
    defer { try? FileManager.default.removeItem(at: root) }
    let apps = AppConnectionsStore(
      workspacePath: root.path, secrets: InMemorySecretStore(),
      http: GoogleHTTP(execute: { await CalendarRequests().call($0) }))
    let gmailOnly = account(scopes: [AppConnectionsStore.readScope])
    try await apps.install(gmailOnly, credential: credential())
    #expect(throws: AppConnectionError.unavailable) {
      try apps.resolve(nil, scope: AppConnectionsStore.calendarReadScope)
    }
    #expect(!apps.available(provider: .claudeCode, scope: AppConnectionsStore.calendarReadScope))
  }

  @Test("Event times must carry an explicit offset")
  func timestampValidation() throws {
    #expect(
      try CalendarValidation.timestamp("2026-10-29T09:00:00+01:00", field: "start")
        == "2026-10-29T09:00:00+01:00")
    #expect(throws: ToolRegistryError.self) {
      try CalendarValidation.timestamp("2026-10-29 09:00", field: "start")
    }
    #expect(throws: ToolRegistryError.self) {
      try CalendarValidation.timestamp("2026-10-29T09:00:00", field: "start")
    }
  }

  @Test("Event text is bounded")
  func textBounds() throws {
    #expect(try CalendarValidation.text(nil, field: "location", required: false) == nil)
    #expect(throws: ToolRegistryError.self) {
      try CalendarValidation.text(nil, field: "summary", required: true)
    }
    #expect(throws: ToolRegistryError.self) {
      try CalendarValidation.text(
        String(repeating: "a", count: CalendarValidation.maxTextBytes + 1),
        field: "description", required: false)
    }
  }
}

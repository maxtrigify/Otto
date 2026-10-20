import Foundation
import OttoBrowser
import SQLite3
import Testing

@Suite("Chromium cookie importer")
struct ChromiumCookieImporterTests {
  private let key = ChromiumCookieImporter.derivedKey(password: "peanuts")

  @Test("Decrypts values with and without the version 24 host digest")
  func roundTrip() throws {
    for version in [23, 24] {
      let encrypted = try #require(
        ChromiumCookieImporter.encrypt(
          "session-123", key: key, hostKey: ".example.com", databaseVersion: version))
      #expect(encrypted.prefix(3) == Data("v10".utf8))
      #expect(
        ChromiumCookieImporter.decrypt(
          encrypted, key: key, hostKey: ".example.com", databaseVersion: version)
          == "session-123")
    }
  }

  @Test("Rejects a value encrypted for another host or with the wrong key")
  func rejectsMismatches() throws {
    let encrypted = try #require(
      ChromiumCookieImporter.encrypt(
        "secret", key: key, hostKey: "a.example", databaseVersion: 24))
    #expect(
      ChromiumCookieImporter.decrypt(
        encrypted, key: key, hostKey: "b.example", databaseVersion: 24) == nil)
    let otherKey = ChromiumCookieImporter.derivedKey(password: "other")
    #expect(
      ChromiumCookieImporter.decrypt(
        encrypted, key: otherKey, hostKey: "a.example", databaseVersion: 24) == nil)
  }

  @Test("Reads a cookie database, skipping expired cookies")
  func readsDatabase() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-cookie-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appending(path: "Cookies")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let future = chromiumTime(now.addingTimeInterval(86_400))
    let past = chromiumTime(now.addingTimeInterval(-86_400))

    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    exec(database, "CREATE TABLE meta(key TEXT, value TEXT)")
    exec(database, "INSERT INTO meta VALUES ('version', '24')")
    exec(
      database,
      """
      CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
        expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, has_expires INTEGER,
        samesite INTEGER)
      """)
    let rows: [(String, String, Int64, Int32, Int32)] = [
      (".github.com", "user_session", future, 1, 2),
      ("old.example", "stale", past, 1, 1),
      ("app.example", "sid", 0, 0, -1),
    ]
    for (host, name, expires, hasExpires, sameSite) in rows {
      let encrypted = try #require(
        ChromiumCookieImporter.encrypt(
          "\(name)-value", key: key, hostKey: host, databaseVersion: 24))
      var statement: OpaquePointer?
      sqlite3_prepare_v2(
        database, "INSERT INTO cookies VALUES (?, ?, '', ?, '/', ?, 1, 1, ?, ?)", -1, &statement,
        nil)
      let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      sqlite3_bind_text(statement, 1, host, -1, transient)
      sqlite3_bind_text(statement, 2, name, -1, transient)
      _ = encrypted.withUnsafeBytes {
        sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(encrypted.count), transient)
      }
      sqlite3_bind_int64(statement, 4, expires)
      sqlite3_bind_int(statement, 5, hasExpires)
      sqlite3_bind_int(statement, 6, sameSite)
      #expect(sqlite3_step(statement) == SQLITE_DONE)
      sqlite3_finalize(statement)
    }

    let cookies = try ChromiumCookieImporter.readCookies(
      databaseURL: databaseURL, password: "peanuts", browser: "Dia", now: now)
    #expect(cookies.map(\.name) == ["user_session", "sid"])
    let session = try #require(cookies.first)
    #expect(session.value == "user_session-value")
    #expect(session.domain == ".github.com")
    #expect(session.sameSite == .strict)
    #expect(session.isSecure && session.isHTTPOnly)

    let httpCookie = try #require(cookies.last?.httpCookie(now: now))
    #expect(httpCookie.value == "sid-value")
    #expect(httpCookie.isHTTPOnly)
    // Session cookies are kept long enough to survive relaunching Otto.
    #expect(httpCookie.expiresDate.map { $0 > now.addingTimeInterval(86_400) } == true)
  }

  @Test("Discovers sign-in-only Chromium profiles with their display names")
  func discoversProfiles() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "otto-cookie-discover-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appending(path: "Library/Application Support/Dia/User Data")
    for profile in ["Default", "Profile 1", "Profile 2"] {
      let directory = root.appending(path: profile)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data().write(to: directory.appending(path: "Cookies"))
    }
    let localState: [String: Any] = [
      "profile": [
        "info_cache": [
          "Default": ["name": "Work"], "Profile 1": ["name": "Max"], "Profile 2": ["name": "Max"],
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: localState).write(
      to: root.appending(path: "Local State"))

    let sources = BrowserProfileImporter.discover(homeDirectory: home)
    #expect(sources.map(\.profileName) == ["Max · Profile 1", "Max · Profile 2", "Work"])
    let allSignIns = sources.allSatisfy(\.canImportSignIns)
    #expect(allSignIns)
    let bookmarks = try BrowserProfileImporter.importBookmarks(from: sources[0])
    #expect(bookmarks.isEmpty)
  }

  private func chromiumTime(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
  }

  private func exec(_ database: OpaquePointer?, _ sql: String) {
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
  }
}

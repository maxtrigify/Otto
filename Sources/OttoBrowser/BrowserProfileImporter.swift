import Foundation
import OttoModels
import SQLite3

public struct BrowserImportSource: Identifiable, Equatable, Sendable {
  public enum Browser: String, Sendable {
    case dia = "Dia"
    case chrome = "Chrome"
    case arc = "Arc"
    case comet = "Comet"
    case brave = "Brave"
    case edge = "Edge"
    case vivaldi = "Vivaldi"
    case firefox = "Firefox"
    case safari = "Safari"

    public var isChromium: Bool { self != .firefox && self != .safari }

    /// The login Keychain item Chromium uses to encrypt this browser's cookies.
    public var safeStorageService: String? {
      switch self {
      case .dia: "Dia Safe Storage"
      case .chrome: "Chrome Safe Storage"
      case .arc: "Arc Safe Storage"
      case .comet: "Comet Safe Storage"
      case .brave: "Brave Safe Storage"
      case .edge: "Microsoft Edge Safe Storage"
      case .vivaldi: "Vivaldi Safe Storage"
      case .firefox, .safari: nil
      }
    }

    public var applicationPath: String {
      switch self {
      case .dia: "/Applications/Dia.app"
      case .chrome: "/Applications/Google Chrome.app"
      case .arc: "/Applications/Arc.app"
      case .comet: "/Applications/Comet.app"
      case .brave: "/Applications/Brave Browser.app"
      case .edge: "/Applications/Microsoft Edge.app"
      case .vivaldi: "/Applications/Vivaldi.app"
      case .firefox: "/Applications/Firefox.app"
      case .safari: "/Applications/Safari.app"
      }
    }
  }

  public var id: String { "\(browser.rawValue):\(profileURL.path)" }
  public let browser: Browser
  public let profileName: String
  /// The bookmarks file. For Chromium profiles it may not exist when only sign-ins are present.
  public let profileURL: URL
  /// The Chromium cookie database, when the profile has one.
  public let cookiesURL: URL?

  public var canImportSignIns: Bool { cookiesURL != nil && browser.safeStorageService != nil }

  public init(browser: Browser, profileName: String, profileURL: URL, cookiesURL: URL? = nil) {
    self.browser = browser
    self.profileName = profileName
    self.profileURL = profileURL
    self.cookiesURL = cookiesURL
  }
}

public enum BrowserProfileImportError: Error, LocalizedError {
  case unreadable(String)
  case invalidFormat(String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let browser): "Otto could not read the \(browser) profile."
    case .invalidFormat(let browser): "The \(browser) bookmark format was not recognized."
    }
  }
}

public enum BrowserProfileImporter {
  public static func discover(
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [BrowserImportSource] {
    var sources: [BrowserImportSource] = []
    let applicationSupport = homeDirectory.appending(path: "Library/Application Support")
    let chromiumRoots: [(BrowserImportSource.Browser, String)] = [
      (.dia, "Dia/User Data"),
      (.chrome, "Google/Chrome"),
      (.arc, "Arc/User Data"),
      (.comet, "Comet"),
      (.brave, "BraveSoftware/Brave-Browser"),
      (.edge, "Microsoft Edge"),
      (.vivaldi, "Vivaldi"),
    ]
    for (browser, path) in chromiumRoots {
      sources += chromiumSources(
        browser: browser,
        root: applicationSupport.appending(path: path),
        fileManager: fileManager
      )
    }

    let firefoxRoot = applicationSupport.appending(path: "Firefox/Profiles")
    if let profiles = try? fileManager.contentsOfDirectory(
      at: firefoxRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) {
      for profile in profiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let database = profile.appending(path: "places.sqlite")
        if fileManager.fileExists(atPath: database.path) {
          sources.append(
            BrowserImportSource(
              browser: .firefox,
              profileName: friendlyProfileName(profile.lastPathComponent),
              profileURL: database
            ))
        }
      }
    }

    let safariBookmarks = homeDirectory.appending(path: "Library/Safari/Bookmarks.plist")
    if fileManager.fileExists(atPath: safariBookmarks.path) {
      sources.append(
        BrowserImportSource(
          browser: .safari,
          profileName: "Default",
          profileURL: safariBookmarks
        ))
    }
    return sources
  }

  public static func importBookmarks(from source: BrowserImportSource) throws -> [BrowserBookmark] {
    let bookmarks: [BrowserBookmark]
    switch source.browser {
    case .dia, .chrome, .arc, .comet, .brave, .edge, .vivaldi:
      guard FileManager.default.fileExists(atPath: source.profileURL.path) else { return [] }
      bookmarks = try chromiumBookmarks(at: source.profileURL, browser: source.browser.rawValue)
    case .firefox:
      bookmarks = try firefoxBookmarks(at: source.profileURL)
    case .safari:
      bookmarks = try safariBookmarks(at: source.profileURL)
    }
    return deduplicated(bookmarks)
  }

  private static func chromiumSources(
    browser: BrowserImportSource.Browser,
    root: URL,
    fileManager: FileManager
  ) -> [BrowserImportSource] {
    guard
      let profiles = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }
    let names = chromiumProfileNames(root: root)
    let found: [(directory: String, name: String, bookmarks: URL, cookies: URL?)] =
      profiles.compactMap { profile in
        let directory = profile.lastPathComponent
        guard directory != "Guest Profile", directory != "System Profile" else { return nil }
        let bookmarks = profile.appending(path: "Bookmarks")
        // Chromium moved the cookie store into Network/ in version 96; Dia still uses the root.
        let cookies = [profile.appending(path: "Network/Cookies"), profile.appending(path: "Cookies")]
          .first { fileManager.fileExists(atPath: $0.path) }
        guard fileManager.fileExists(atPath: bookmarks.path) || cookies != nil else { return nil }
        let name = names[directory].flatMap { $0.isEmpty ? nil : $0 }
          ?? friendlyProfileName(directory)
        return (directory, name, bookmarks, cookies)
      }
    let duplicateNames = Dictionary(grouping: found, by: \.name).filter { $0.value.count > 1 }.keys
    return found.map { profile in
      BrowserImportSource(
        browser: browser,
        profileName: duplicateNames.contains(profile.name)
          ? "\(profile.name) · \(profile.directory)" : profile.name,
        profileURL: profile.bookmarks,
        cookiesURL: profile.cookies
      )
    }
    .sorted { $0.profileName.localizedCaseInsensitiveCompare($1.profileName) == .orderedAscending }
  }

  /// Profile names as the user sees them in the browser, from `Local State`.
  private static func chromiumProfileNames(root: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: root.appending(path: "Local State")),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let profile = document["profile"] as? [String: Any],
      let cache = profile["info_cache"] as? [String: Any]
    else { return [:] }
    return cache.compactMapValues { ($0 as? [String: Any])?["name"] as? String }
  }

  private static func friendlyProfileName(_ value: String) -> String {
    if value == "Default" { return "Default" }
    if value.hasPrefix("Profile ") { return value }
    if let separator = value.firstIndex(of: ".") {
      let suffix = value[value.index(after: separator)...]
      if !suffix.isEmpty { return String(suffix) }
    }
    return value
  }

  private static func chromiumBookmarks(at url: URL, browser: String) throws -> [BrowserBookmark] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      throw BrowserProfileImportError.unreadable(browser)
    }
    guard
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let roots = document["roots"] as? [String: Any]
    else { throw BrowserProfileImportError.invalidFormat(browser) }
    var result: [BrowserBookmark] = []
    for root in roots.values {
      collectChromiumBookmarks(root, into: &result)
    }
    return result
  }

  private static func collectChromiumBookmarks(_ value: Any, into result: inout [BrowserBookmark]) {
    guard let item = value as? [String: Any] else { return }
    if item["type"] as? String == "url",
      let title = item["name"] as? String,
      let url = item["url"] as? String,
      isImportableURL(url)
    {
      result.append(BrowserBookmark(title: title.isEmpty ? url : title, url: url))
    }
    for child in item["children"] as? [Any] ?? [] {
      collectChromiumBookmarks(child, into: &result)
    }
  }

  private static func safariBookmarks(at url: URL) throws -> [BrowserBookmark] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
      throw BrowserProfileImportError.unreadable("Safari")
    }
    guard let document = try? PropertyListSerialization.propertyList(from: data, format: nil)
    else { throw BrowserProfileImportError.invalidFormat("Safari") }
    var result: [BrowserBookmark] = []
    collectSafariBookmarks(document, into: &result)
    return result
  }

  private static func collectSafariBookmarks(_ value: Any, into result: inout [BrowserBookmark]) {
    guard let item = value as? [String: Any] else { return }
    if let url = item["URLString"] as? String, isImportableURL(url) {
      let dictionary = item["URIDictionary"] as? [String: Any]
      let title = dictionary?["title"] as? String ?? item["Title"] as? String ?? url
      result.append(BrowserBookmark(title: title, url: url))
    }
    for child in item["Children"] as? [Any] ?? [] {
      collectSafariBookmarks(child, into: &result)
    }
  }

  private static func firefoxBookmarks(at url: URL) throws -> [BrowserBookmark] {
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
      ) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw BrowserProfileImportError.unreadable("Firefox")
    }
    defer { sqlite3_close(database) }

    let sql = """
      SELECT COALESCE(NULLIF(b.title, ''), p.url), p.url
      FROM moz_bookmarks b
      JOIN moz_places p ON p.id = b.fk
      WHERE b.type = 1 AND (p.url LIKE 'https://%' OR p.url LIKE 'http://%')
      ORDER BY b.lastModified DESC
      LIMIT 2000
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw BrowserProfileImportError.invalidFormat("Firefox")
    }
    defer { sqlite3_finalize(statement) }

    var result: [BrowserBookmark] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let titleText = sqlite3_column_text(statement, 0),
        let urlText = sqlite3_column_text(statement, 1)
      else { continue }
      result.append(
        BrowserBookmark(title: String(cString: titleText), url: String(cString: urlText)))
    }
    return result
  }

  private static func deduplicated(_ values: [BrowserBookmark]) -> [BrowserBookmark] {
    var seen: Set<String> = []
    return values.filter { bookmark in
      guard seen.insert(bookmark.url).inserted else { return false }
      return true
    }
  }

  private static func isImportableURL(_ value: String) -> Bool {
    guard let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }
}

import Foundation
import OttoBrowser
import Testing

@Suite("Browser profile importer")
struct BrowserProfileImporterTests {
  @Test("Discovers Dia profiles and imports nested bookmarks without duplicates")
  func diaBookmarks() throws {
    let home = FileManager.default.temporaryDirectory.appending(
      path: "otto-browser-import-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: home) }
    let profile = home.appending(
      path: "Library/Application Support/Dia/User Data/Profile 1",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let payload: [String: Any] = [
      "roots": [
        "bookmark_bar": [
          "type": "folder",
          "children": [
            ["type": "url", "name": "Otto", "url": "https://otto.example"],
            [
              "type": "folder",
              "children": [
                ["type": "url", "name": "Docs", "url": "https://docs.example"],
                ["type": "url", "name": "Otto again", "url": "https://otto.example"],
              ],
            ],
          ],
        ]
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try data.write(to: profile.appending(path: "Bookmarks"))

    let sources = BrowserProfileImporter.discover(homeDirectory: home)
    let source = try #require(sources.first)
    #expect(source.browser == .dia)
    #expect(source.profileName == "Profile 1")

    let bookmarks = try BrowserProfileImporter.importBookmarks(from: source)
    #expect(bookmarks.map(\.title) == ["Otto", "Docs"])
    #expect(bookmarks.map(\.url) == ["https://otto.example", "https://docs.example"])
  }
}

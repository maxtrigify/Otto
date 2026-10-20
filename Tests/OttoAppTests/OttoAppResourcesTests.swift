import Foundation
import Testing

@testable import OttoApp

@Suite("Otto app resource bundle")
struct OttoAppResourcesTests {
  @Test("Packaged layout is found under Contents/Resources")
  func packagedLayout() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-app-resources-\(UUID().uuidString)", directoryHint: .isDirectory)
    let resources = root.appending(path: "Contents/Resources/Otto_OttoApp.bundle")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.muse.resource-test</string></dict></plist>
      """.utf8
    ).write(to: root.appending(path: "Contents/Info.plist"))
    defer { try? FileManager.default.removeItem(at: root) }

    let found = try #require(OttoAppResources.locateBundle(main: Bundle(url: root)!))
    #expect(found.bundleURL.standardizedFileURL == resources.standardizedFileURL)
  }

  @Test("A missing bundle does not crash")
  func missingBundle() {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-app-resources-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(OttoAppResources.locateBundle(main: Bundle(url: root)!) == nil)
  }
}

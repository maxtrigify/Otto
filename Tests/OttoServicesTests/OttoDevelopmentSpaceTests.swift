import Foundation
import OttoModels
import Testing

@testable import OttoServices

@MainActor
@Suite("Otto Dev keeps its own spaces")
struct OttoDevelopmentSpaceTests {
  @Test("Only Otto Dev is separate, and it can be pointed back at the real spaces")
  func whoIsSeparate() {
    let dev = OttoNames.developmentBundleIdentifier
    #expect(
      OttoDevelopmentSpace.isSeparate(
        bundleIdentifier: dev, environment: [:], realSpacesDefault: false))
    #expect(
      !OttoDevelopmentSpace.isSeparate(
        bundleIdentifier: OttoNames.releaseBundleIdentifier, environment: [:],
        realSpacesDefault: false))
    #expect(
      !OttoDevelopmentSpace.isSeparate(
        bundleIdentifier: nil, environment: [:], realSpacesDefault: false))
    #expect(
      !OttoDevelopmentSpace.isSeparate(
        bundleIdentifier: dev, environment: [:], realSpacesDefault: true))
    #expect(
      !OttoDevelopmentSpace.isSeparate(
        bundleIdentifier: dev, environment: ["OTTO_DEV_REAL_SPACES": "1"],
        realSpacesDefault: false))
  }

  @Test("Otto Dev's space list, sessions and folder sit apart from the released app's")
  func separateLocations() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dev-space-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let support = root.appending(path: "Application Support")
    let documents = root.appending(path: "Documents")

    let released = OttoProfileRegistry(
      applicationSupport: support,
      originalWorkspacePath: documents.appending(path: "Otto Workspace").path)
    let development = OttoProfileRegistry(
      applicationSupport: OttoDevelopmentSpace.applicationSupport(in: support),
      originalWorkspacePath: OttoDevelopmentSpace.workspace(in: documents).path,
      originalName: "Otto Dev")

    let real = try #require(released.active)
    let dev = try #require(development.active)
    #expect(dev.id != real.id)
    #expect(dev.workspacePath != real.workspacePath)
    #expect(dev.workspacePath.hasSuffix("Otto Dev Workspace"))
    let realPlaces = released.locations(for: real)
    let devPlaces = development.locations(for: dev)
    #expect(devPlaces.databasePath != realPlaces.databasePath)
    #expect(devPlaces.personalMemoryPath != realPlaces.personalMemoryPath)
    #expect(devPlaces.databasePath.contains("/Otto Dev/"))

    // A space made in Otto Dev never appears in the released app's list.
    _ = try development.create(
      name: "Scratch", symbol: "hammer", folder: documents.appending(path: "Scratch"))
    let reopened = OttoProfileRegistry(
      applicationSupport: support,
      originalWorkspacePath: documents.appending(path: "Otto Workspace").path)
    #expect(reopened.profiles.map(\.name) == ["Work"])
  }
}

import Foundation
import OttoCore
import OttoMemory
import OttoModels
import OttoTools
import Testing

@testable import OttoServices

@MainActor
@Suite("Profiles as separate places")
struct OttoProfileTests {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID())")
  }

  @Test("The existing workspace becomes the original profile without moving anything")
  func originalProfile() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = OttoProfileRegistry(
      applicationSupport: root.appending(path: "support"),
      originalWorkspacePath: root.appending(path: "Muse Workspace").path)
    let original = try #require(registry.active)
    #expect(original.isOriginal)
    #expect(original.name == "Work")
    let locations = registry.locations(for: original)
    #expect(locations.databasePath.hasSuffix("Otto/workspace.sqlite"))
    #expect(locations.personalMemoryPath.hasSuffix("Otto/Memory/user.md"))

    let personal = try registry.create(
      name: "Personal", symbol: "heart", folder: root.appending(path: "Personal"))
    #expect(!personal.isOriginal)
    #expect(!personal.crossProfileAccess)
    let personalLocations = registry.locations(for: personal)
    #expect(personalLocations.databasePath.contains("Profiles/\(personal.id.uuidString)"))
    #expect(personalLocations.personalMemoryPath.hasPrefix(personal.workspacePath))
    #expect(FileManager.default.fileExists(atPath: personal.workspacePath + "/.otto"))
    #expect(throws: OttoProfileRegistry.RegistryError.self) {
      try registry.create(name: "personal", symbol: "heart")
    }
    #expect(throws: OttoProfileRegistry.RegistryError.self) {
      try registry.create(name: "Other", symbol: "heart", folder: root.appending(path: "Personal"))
    }

    try registry.setActive(personal.id)
    let restored = OttoProfileRegistry(
      applicationSupport: root.appending(path: "support"), originalWorkspacePath: "/elsewhere")
    #expect(restored.profiles.map(\.name) == ["Work", "Personal"])
    #expect(restored.active?.id == personal.id)
    #expect(restored.profile(workspacePath: personal.workspacePath + "/")?.id == personal.id)

    try restored.remove(personal.id)
    #expect(restored.active?.id == original.id)
    // Forgetting a profile never deletes its files.
    #expect(FileManager.default.fileExists(atPath: personal.workspacePath))
    #expect(throws: OttoProfileRegistry.RegistryError.self) { try restored.remove(original.id) }
  }

  @Test(
    "Agents are told their profile, and cross-profile search stays off until the user allows it")
  func crossProfileAccess() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workPath = root.appending(path: "Work")
    try FileManager.default.createDirectory(at: workPath, withIntermediateDirectories: true)
    let registry = OttoProfileRegistry(
      applicationSupport: root.appending(path: "support"), originalWorkspacePath: workPath.path)
    let personal = try registry.create(
      name: "Personal", symbol: "heart", folder: root.appending(path: "Personal"))
    let personalBrain = try ProjectBrainStore(
      rootPath: personal.workspacePath + "/.otto/brain", project: "Personal")
    _ = try await personalBrain.write(
      MemoryRecord(
        id: "mortgage-plan", type: .wiki, project: "Personal", title: "Mortgage plan",
        body: "Remortgage before March to keep the fixed rate.", author: "test",
        confidence: .confirmed),
      expectedRevision: nil)

    let services = ApplicationServices(
      store: CanvasStore(), workspacePath: workPath.path, profiles: registry)
    await services.start()
    defer { services.stop() }
    #expect(services.currentProfile?.name == "Work")
    let text = try #require(services.profileBootstrapText)
    #expect(text.contains("Work space"))
    #expect(text.contains("off by default"))
    #expect(text.contains("Personal"))

    let caller = ToolContext(actorID: "agent", scopes: [.agentRead], source: .agent)
    let blocked = try await services.registry.call(
      name: "profile.search", input: try JSONValue.encode(ProfileSearchInput(query: "mortgage")),
      context: caller
    ).decode(ProfileSearchOutput.self)
    #expect(blocked.hits.isEmpty)
    #expect(blocked.note == ApplicationServices.crossProfileOffMessage)

    var work = try #require(services.currentProfile)
    work.crossProfileAccess = true
    try registry.update(work)
    let found = try await services.registry.call(
      name: "profile.search", input: try JSONValue.encode(ProfileSearchInput(query: "mortgage")),
      context: caller
    ).decode(ProfileSearchOutput.self)
    #expect(found.hits.first?.profile == "Personal")
    #expect(found.hits.first?.title == "Mortgage plan")

    let listed = try await services.registry.call(
      name: "profile.list", input: .object([:]), context: caller
    ).decode(ProfileListOutput.self)
    #expect(listed.profiles.map(\.name) == ["Work", "Personal"])
    #expect(listed.profiles.first?.current == true)
    #expect(listed.crossProfileAccess)
  }

  @Test("A new profile starts blank and copies only what the user picked")
  func quickStart() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let workPath = root.appending(path: "Work")
    try FileManager.default.createDirectory(at: workPath, withIntermediateDirectories: true)
    let registry = OttoProfileRegistry(
      applicationSupport: root.appending(path: "support"), originalWorkspacePath: workPath.path)
    let services = ApplicationServices(
      store: CanvasStore(), workspacePath: workPath.path,
      personalMemoryPath: root.appending(path: "work-user.md").path, profiles: registry)
    _ = try await services.personalMemory.add(
      CompactMemoryEntry(id: "name", text: "Name is Max", source: "user"))
    _ = try await services.personalMemory.add(
      CompactMemoryEntry(id: "style", text: "Prefers short answers", source: "user"))
    let brain = try #require(services.brain)
    _ = try await brain.write(
      MemoryRecord(
        id: "goals-2027", type: .wiki, project: "Work", title: "2027 goals",
        body: "Grow Trigify to 2M ARR.", author: "test", confidence: .confirmed),
      expectedRevision: nil)
    _ = try await brain.write(
      MemoryRecord(
        id: "secret-roadmap", type: .wiki, project: "Work", title: "Roadmap",
        body: "Not for Personal.", author: "test", confidence: .confirmed),
      expectedRevision: nil)

    let shareable = await services.shareableBrainRecords()
    #expect(Set(shareable.map(\.id)) == ["goals-2027", "secret-roadmap"])
    let personal = try await services.createProfile(
      name: "Personal", symbol: "heart", themeID: nil,
      quickStart: ProfileQuickStart(aboutMeEntryIDs: ["name"], brainRecordIDs: ["goals-2027"]))

    let about = CompactMemoryStore(
      filePath: registry.locations(for: personal).personalMemoryPath, title: "User context",
      budget: .personal)
    #expect(await about.entries().map(\.text) == ["Name is Max"])
    let personalBrain = try ProjectBrainStore(
      rootPath: personal.workspacePath + "/.otto/brain", project: "Personal")
    let copied = try await personalBrain.allRecords().map(\.id)
    #expect(copied == ["goals-2027"])
  }
}

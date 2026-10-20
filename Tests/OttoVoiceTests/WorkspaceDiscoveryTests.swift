import Foundation
import OttoVoice
import Testing

@Suite("Workspace discovery")
struct WorkspaceDiscoveryTests {
  @Test("Nested Git repositories are available to voice commands")
  func nestedRepository() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-workspace-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    let active = root.appending(path: "Muse", directoryHint: .isDirectory)
    let nested = root.appending(
      path: "Documents - Example MacBook/sample-app", directoryHint: .isDirectory)
    let ignored = root.appending(path: "node_modules/ignored-repo", directoryHint: .isDirectory)
    for repository in [active, nested, ignored] {
      try FileManager.default.createDirectory(
        at: repository.appending(path: ".git", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    let repositories = WorkspaceDiscovery.gitRepositories(
      activeWorkspace: active.path,
      roots: [root],
      maxDepth: 4
    )

    #expect(repositories.contains(active.standardizedFileURL.resolvingSymlinksInPath().path))
    #expect(repositories.contains(nested.standardizedFileURL.resolvingSymlinksInPath().path))
    #expect(!repositories.contains(ignored.standardizedFileURL.resolvingSymlinksInPath().path))
  }
}

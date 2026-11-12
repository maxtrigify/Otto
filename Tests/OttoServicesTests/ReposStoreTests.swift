import Foundation
import Testing
@testable import OttoServices

@MainActor
@Suite("ReposStore")
struct ReposStoreTests {
  /// Sendable box for capturing the git stub's arguments from a detached task.
  final class GitCallBox: @unchecked Sendable {
    var value: ([String], URL)?
  }

  private func makeStore(tmp: String) throws -> ReposStore {
    let root = URL(fileURLWithPath: tmp, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return ReposStore(workspacePath: tmp, git: { _, _ in })
  }

  // MARK: - URL handling

  @Test func normalizesHttpsRepoURLs() {
    #expect(ReposStore.normalizeURL("https://github.com/foo/bar") == "https://github.com/foo/bar")
    #expect(ReposStore.normalizeURL("  https://github.com/foo/bar/ ") == "https://github.com/foo/bar")
    #expect(ReposStore.normalizeURL("https://github.com/foo/bar.git") == "https://github.com/foo/bar.git")
  }

  @Test func rejectsNonHttpSchemes() {
    #expect(ReposStore.normalizeURL("ftp://github.com/foo/bar") == nil)
    #expect(ReposStore.normalizeURL("file:///tmp/foo") == nil)
    #expect(ReposStore.normalizeURL("github.com/foo/bar") == nil)
  }

  @Test func allowsHttpOnlyToLoopback() {
    #expect(ReposStore.normalizeURL("http://127.0.0.1:8000/repo") != nil)
    #expect(ReposStore.normalizeURL("http://localhost/repo") != nil)
    #expect(ReposStore.normalizeURL("http://100.64.0.5/repo") != nil)
    #expect(ReposStore.normalizeURL("http://example.com/repo") == nil)
  }

  @Test func derivesSafeFolderNames() {
    #expect(ReposStore.repoName(from: "https://github.com/foo/bar") == "bar")
    #expect(ReposStore.repoName(from: "https://github.com/foo/bar.git") == "bar")
    #expect(ReposStore.repoName(from: "https://github.com/foo/My_Repo-2") == "My_Repo-2")
    #expect(ReposStore.repoName(from: "https://github.com") == nil)
  }

  // MARK: - Add / persist / remove

  @Test func addPersistsAndDedupes() throws {
    let tmp = NSTemporaryDirectory() + "repos-add-\(UUID())"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let store = try makeStore(tmp: tmp)
    let repo = try store.add("https://github.com/owner/repo")
    #expect(store.repos.count == 1)
    #expect(repo.name == "repo")
    #expect(store.states[repo.id] == .notCloned)
    #expect(throws: RepoCloneError.self) { try store.add("https://github.com/owner/repo") }
    #expect(throws: RepoCloneError.self) { try store.add("not-a-url") }

    // Reload from disk.
    let reloaded = ReposStore(workspacePath: tmp, git: { _, _ in })
    #expect(reloaded.repos.map(\.id) == [repo.id])
    #expect(reloaded.repos.map(\.name) == ["repo"])
    #expect(reloaded.repos.map(\.url) == [repo.url])
  }

  @Test func removeDeletesEntryAndClone() throws {
    let tmp = NSTemporaryDirectory() + "repos-remove-\(UUID())"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let store = try makeStore(tmp: tmp)
    let repo = try store.add("https://github.com/owner/repo")
    let dir = store.cloneDirectory(for: repo)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try store.remove(repo)
    #expect(store.repos.isEmpty)
    #expect(store.states[repo.id] == nil)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
  }

  // MARK: - Clone

  @Test func cloneRunsShallowGitClone() async throws {
    let tmp = NSTemporaryDirectory() + "repos-clone-\(UUID())"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let calls = GitCallBox()
    let store = ReposStore(workspacePath: tmp) { arguments, directory in
      calls.value = (arguments, directory)
    }
    let repo = try store.add("https://github.com/owner/repo")
    await store.clone(repo)
    let args = try #require(calls.value?.0)
    #expect(args[0] == "clone")
    #expect(args.contains("--depth"))
    #expect(args.contains("1"))
    #expect(args.contains(repo.url))
    #expect(calls.value?.1.lastPathComponent == "repos")
    guard case .cloned(let path) = store.states[repo.id] else {
      Issue.record("expected cloned state")
      return
    }
    #expect(path.hasSuffix("/repos/repo"))
  }

  @Test func cloneReportsFailure() async throws {
    let tmp = NSTemporaryDirectory() + "repos-clone-fail-\(UUID())"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let store = ReposStore(workspacePath: tmp) { _, _ in
      throw RepoCloneError.gitFailed("boom")
    }
    let repo = try store.add("https://github.com/owner/repo")
    await store.clone(repo)
    guard case .failed = store.states[repo.id] else {
      Issue.record("expected failed state")
      return
    }
  }
}

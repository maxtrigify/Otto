import Foundation
import Testing

@testable import OttoRuntime

@Suite("Working context")
struct WorkingContextTests {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "otto-working-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Branch resolves from HEAD, from subdirectories, and for detached checkouts")
  func branchResolution() throws {
    let repo = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: repo) }
    let gitDirectory = repo.appending(path: ".git")
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    try Data("ref: refs/heads/dev\n".utf8)
      .write(to: gitDirectory.appending(path: "HEAD"))
    let nested = repo.appending(path: "Sources/Deep")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let fromRoot = WorkingContext.gitContext(for: repo.path)
    #expect(fromRoot?.repoName == repo.lastPathComponent)
    #expect(fromRoot?.branch == "dev")

    let fromNested = WorkingContext.gitContext(for: nested.path)
    #expect(fromNested?.repoName == repo.lastPathComponent)
    #expect(fromNested?.branch == "dev")

    try Data("0123456789abcdef0123456789abcdef01234567\n".utf8)
      .write(to: gitDirectory.appending(path: "HEAD"))
    #expect(WorkingContext.gitContext(for: repo.path)?.branch == "0123456")
  }

  @Test("Worktree .git files follow the gitdir pointer to the real HEAD")
  func worktreeIndirection() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let realGitDirectory = root.appending(path: "main-checkout/.git/worktrees/feature")
    try FileManager.default.createDirectory(
      at: realGitDirectory, withIntermediateDirectories: true)
    try Data("ref: refs/heads/feature-branch\n".utf8)
      .write(to: realGitDirectory.appending(path: "HEAD"))
    let worktree = root.appending(path: "feature-worktree")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    try Data("gitdir: \(realGitDirectory.path)\n".utf8)
      .write(to: worktree.appending(path: ".git"))

    let context = WorkingContext.gitContext(for: worktree.path)
    #expect(context?.repoName == "feature-worktree")
    #expect(context?.branch == "feature-branch")
  }

  @Test("A non-repo directory yields a plain directory state")
  func nonRepoDirectory() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let state = WorkingContext.resolve(pid: nil, fallbackDirectory: directory.path)
    #expect(state?.repoName == nil)
    #expect(state?.branch == nil)
    #expect(state?.displayName == directory.lastPathComponent)
  }

  @Test("Live working directory reads the process's actual cwd from the kernel")
  func liveWorkingDirectory() {
    let cwd = WorkingContext.liveWorkingDirectory(pid: getpid())
    #expect(
      cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .standardizedFileURL.path
    )
    #expect(WorkingContext.liveWorkingDirectory(pid: -1) == nil)
  }

  @Test("Resolve prefers the live pid directory over the fallback")
  func pidBeatsFallback() {
    let state = WorkingContext.resolve(pid: getpid(), fallbackDirectory: "/somewhere/else")
    #expect(state?.directory != "/somewhere/else")
  }
}

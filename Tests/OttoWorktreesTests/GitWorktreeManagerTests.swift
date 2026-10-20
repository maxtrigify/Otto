import Foundation
import OttoWorktrees
import Testing

@Suite("Git worktree safety")
struct GitWorktreeManagerTests {
  @Test("Creates isolated branches and refuses to delete dirty worktrees")
  func lifecycle() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    let worktreeRoot = root.appending(path: "worktrees")
    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: worktreeRoot.path
    )
    let handle = try await manager.create(name: "Auth review")
    #expect(handle.branch.hasPrefix("otto/auth-review-"))
    #expect(FileManager.default.fileExists(atPath: handle.path))

    let file = URL(fileURLWithPath: handle.path).appending(path: "README.md")
    try Data("changed\n".utf8).write(to: file)
    #expect(try await manager.isDirty(handle))
    await #expect(throws: WorktreeError.self) { try await manager.cleanup(handle) }
    #expect(FileManager.default.fileExists(atPath: handle.path))

    try Data("baseline\n".utf8).write(to: file)
    try await manager.cleanup(handle)
    #expect(!FileManager.default.fileExists(atPath: handle.path))
  }

  @Test("Status reconciles staged, unstaged, and untracked files")
  func comprehensiveStatus() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-status-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: root.appending(path: "worktrees").path
    )
    let handle = try await manager.create(name: "Status fixture")
    let worktree = URL(fileURLWithPath: handle.path)
    try Data("staged\n".utf8).write(to: worktree.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: worktree)
    try Data("untracked\n".utf8).write(to: worktree.appending(path: "NEW.md"))

    let status = try await manager.status(handle)
    #expect(status.dirty)
    #expect(status.changedFiles == 2)
    #expect(status.diff.contains("README.md"))
    await #expect(throws: WorktreeError.self) { try await manager.cleanup(handle) }
  }

  @Test("Overlapping worker changes are refused before integration")
  func conflictRefusal() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-conflict-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "shared.txt"))
    try runGit(["add", "shared.txt"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: root.appending(path: "worktrees").path)
    let first = try await manager.create(name: "First worker")
    let second = try await manager.create(name: "Second worker")
    try Data("first\n".utf8).write(
      to: URL(fileURLWithPath: first.path).appending(path: "shared.txt"))
    try Data("second\n".utf8).write(
      to: URL(fileURLWithPath: second.path).appending(path: "shared.txt"))

    let report = try await manager.conflicts(between: [first, second])
    #expect(report.overlappingPaths == ["shared.txt"])
    await #expect(throws: WorktreeError.self) {
      try await manager.validateNoConflicts(between: [first, second])
    }
    #expect(
      try String(contentsOf: root.appending(path: "shared.txt"), encoding: .utf8)
        == "baseline\n")
  }

  @Test("Committed worktree changes integrate into a clean repository")
  func integration() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-integrate-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: root.appending(path: "worktrees").path)
    let handle = try await manager.create(name: "Integrated worker")
    let worktree = URL(fileURLWithPath: handle.path)
    try Data("integrated\n".utf8).write(to: worktree.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: worktree)
    try runGit(["commit", "-m", "integrated change"], at: worktree)

    let result = try await manager.integrate(handle)
    #expect(result.commits.count == 1)
    #expect(result.repositoryHead.count == 40)
    #expect(
      try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        == "integrated\n")
  }

  @Test("Worktrees made before the rename keep integrating after .muse-worktrees moves")
  func legacyWorktreeRoot() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-legacy-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try Data(".otto-worktrees/\n".utf8).write(to: root.appending(path: ".gitignore"))
    try runGit(["add", "README.md", ".gitignore"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    // A worktree Muse created under the old folder name.
    let legacyPath = root.appending(path: ".muse-worktrees/old-agent").path
    try runGit(["worktree", "add", "-b", "muse/old-agent", legacyPath, "HEAD"], at: root)
    let legacyHandle = WorktreeHandle(branch: "muse/old-agent", path: legacyPath)

    // Creating a new worktree moves the folder and leaves a symlink behind.
    let manager = GitWorktreeManager(repositoryPath: root.path)
    let fresh = try await manager.create(name: "New agent")
    #expect(fresh.path.contains("/.otto-worktrees/"))
    #expect(
      (try? FileManager.default.destinationOfSymbolicLink(
        atPath: root.appending(path: ".muse-worktrees").path)) != nil)

    // The old handle still resolves, still passes path validation, and still integrates even
    // though the `.muse-worktrees` symlink is not ignored by the repository.
    let worktree = URL(fileURLWithPath: legacyHandle.path)
    try Data("legacy change\n".utf8).write(to: worktree.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: worktree)
    try runGit(["commit", "-m", "legacy change"], at: worktree)
    let result = try await manager.integrate(legacyHandle)
    #expect(result.commits.count == 1)
    #expect(
      try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        == "legacy change\n")
  }

  @Test("Integration refuses dirty repositories without changing either checkout")
  func integrationRefusesDirtyRepository() async throws {
    let root = URL(fileURLWithPath: "/tmp/otto-git-dirty-\(UUID().uuidString.prefix(10))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try runGit(["init"], at: root)
    try runGit(["config", "user.email", "otto@example.invalid"], at: root)
    try runGit(["config", "user.name", "Otto Tests"], at: root)
    try Data("baseline\n".utf8).write(to: root.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: root)
    try runGit(["commit", "-m", "baseline"], at: root)

    let manager = GitWorktreeManager(
      repositoryPath: root.path,
      worktreeRootPath: root.appending(path: "worktrees").path)
    let handle = try await manager.create(name: "Dirty target")
    let worktree = URL(fileURLWithPath: handle.path)
    try Data("worker\n".utf8).write(to: worktree.appending(path: "README.md"))
    try runGit(["add", "README.md"], at: worktree)
    try runGit(["commit", "-m", "worker change"], at: worktree)
    try Data("local uncommitted\n".utf8).write(to: root.appending(path: "README.md"))

    await #expect(throws: WorktreeError.self) { try await manager.integrate(handle) }
    #expect(
      try String(contentsOf: root.appending(path: "README.md"), encoding: .utf8)
        == "local uncommitted\n")
  }

  private func runGit(_ arguments: [String], at directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}

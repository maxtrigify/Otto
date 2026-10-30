import Foundation
import OttoModels

public struct WorktreeHandle: Codable, Sendable, Equatable {
  public var branch: String
  public var path: String

  public init(branch: String, path: String) {
    self.branch = branch
    self.path = path
  }
}

public struct WorktreeStatus: Codable, Sendable, Equatable {
  public var handle: WorktreeHandle
  public var dirty: Bool
  public var changedFiles: Int
  public var diff: String
}

public struct WorktreeConflictReport: Codable, Sendable, Equatable {
  public var handles: [WorktreeHandle]
  public var overlappingPaths: [String]

  public init(handles: [WorktreeHandle], overlappingPaths: [String]) {
    self.handles = handles
    self.overlappingPaths = overlappingPaths.sorted()
  }
}

public struct WorktreeIntegration: Codable, Sendable, Equatable {
  public var handle: WorktreeHandle
  public var commits: [String]
  public var repositoryHead: String

  public init(handle: WorktreeHandle, commits: [String], repositoryHead: String) {
    self.handle = handle
    self.commits = commits
    self.repositoryHead = repositoryHead
  }
}

public actor WorktreeSessionStore {
  private var handles: [UUID: WorktreeHandle] = [:]
  public init() {}
  public func set(_ handle: WorktreeHandle, for nodeID: UUID) { handles[nodeID] = handle }
  public func handle(for nodeID: UUID) -> WorktreeHandle? { handles[nodeID] }
  public func remove(nodeID: UUID) { handles[nodeID] = nil }
}

public enum WorktreeError: Error, LocalizedError, Sendable {
  case git(String)
  case dirty(String)
  case unsafePath(String)
  case conflict([String])
  case noCommits(String)

  public var errorDescription: String? {
    switch self {
    case .git(let message): "Git worktree operation failed: \(message)"
    case .dirty(let path): "Worktree has uncommitted changes and was retained: \(path)"
    case .unsafePath(let path): "Refusing unsafe worktree path: \(path)"
    case .conflict(let paths):
      "Worker worktrees overlap and require user resolution: \(paths.joined(separator: ", "))"
    case .noCommits(let branch):
      "Worktree branch has no commits to integrate: \(branch)"
    }
  }
}

public actor GitWorktreeManager {
  private let repository: URL
  private let worktreeRoot: URL
  /// Worktrees created before the rename live under `.muse-worktrees`. The folder is moved to
  /// `.otto-worktrees` (leaving a symlink) the first time a worktree is created; handles that
  /// still carry the old path stay valid.
  private let legacyWorktreeRoot: URL?
  private let usesDefaultRoot: Bool

  public init(repositoryPath: String, worktreeRootPath: String? = nil) {
    repository = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL
    usesDefaultRoot = worktreeRootPath == nil
    worktreeRoot =
      URL(
        fileURLWithPath: worktreeRootPath
          ?? URL(fileURLWithPath: repositoryPath).appending(path: OttoNames.agentWorktreesFolder)
          .path,
        isDirectory: true
      ).standardizedFileURL
    legacyWorktreeRoot =
      worktreeRootPath == nil
      ? URL(fileURLWithPath: repositoryPath)
        .appending(path: OttoNames.legacyAgentWorktreesFolder, directoryHint: .isDirectory)
        .standardizedFileURL
      : nil
  }

  public func create(name: String) throws -> WorktreeHandle {
    let slug = String(
      name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        .split(separator: "-").joined(separator: "-")
    )
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let branch = "otto/\(slug.isEmpty ? "agent" : slug)-\(suffix)"
    let path = worktreeRoot.appending(path: "\(slug.isEmpty ? "agent" : slug)-\(suffix)")
    if usesDefaultRoot {
      OttoWorkspaceMigration.migrateWorktreesFolder(repositoryPath: repository.path)
    }
    try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
    try runGit(["worktree", "add", "-b", branch, path.path, "HEAD"], at: repository)
    return WorktreeHandle(branch: branch, path: path.path)
  }

  public func isDirty(_ handle: WorktreeHandle) throws -> Bool {
    let directory = URL(fileURLWithPath: handle.path)
    return try !runGit(["status", "--porcelain=v1", "--untracked-files=all"], at: directory)
      .isEmpty || !changedPaths(at: directory).isEmpty
  }

  public func status(_ handle: WorktreeHandle) throws -> WorktreeStatus {
    let directory = URL(fileURLWithPath: handle.path)
    let porcelain = try runGit(
      ["status", "--porcelain=v1", "--untracked-files=all"],
      at: directory
    )
    let paths = try changedPaths(at: directory)
    let diff = try runGit(
      ["diff", "--no-ext-diff", "HEAD", "--stat", "--", "."],
      at: directory
    )
    return WorktreeStatus(
      handle: handle,
      dirty: !porcelain.isEmpty || !paths.isEmpty,
      changedFiles: paths.count,
      diff: String(diff.prefix(32_768))
    )
  }

  public func diff(_ handle: WorktreeHandle) throws -> String {
    String(
      try runGit(
        ["diff", "--no-ext-diff", "HEAD", "--", "."],
        at: URL(fileURLWithPath: handle.path)
      )
      .prefix(131_072))
  }

  public func conflicts(between handles: [WorktreeHandle]) throws -> WorktreeConflictReport {
    var owners: [String: Int] = [:]
    for handle in handles {
      for path in try changedPaths(at: URL(fileURLWithPath: handle.path)) {
        owners[path, default: 0] += 1
      }
    }
    return WorktreeConflictReport(
      handles: handles,
      overlappingPaths: owners.compactMap { $0.value > 1 ? $0.key : nil })
  }

  /// This is the only pre-integration gate: callers must resolve overlapping paths before any
  /// merge or patch application. The manager never guesses which worker wins.
  public func validateNoConflicts(between handles: [WorktreeHandle]) throws {
    let report = try conflicts(between: handles)
    guard report.overlappingPaths.isEmpty else {
      throw WorktreeError.conflict(report.overlappingPaths)
    }
  }

  /// Lands every commit made after the worktree diverged from the repository's current branch.
  /// The host app performs this operation outside the worker sandbox. Both checkouts must be clean,
  /// and a failed cherry-pick is aborted so the user's repository is returned to its prior state.
  public func integrate(_ handle: WorktreeHandle) throws -> WorktreeIntegration {
    try validateManagedPath(handle)
    if try isDirty(handle) { throw WorktreeError.dirty(handle.path) }
    var statusArguments = ["status", "--porcelain=v1", "--untracked-files=all"]
    let excludedRoots = ([worktreeRoot] + (legacyWorktreeRoot.map { [$0] } ?? []))
      .filter { $0.path.hasPrefix(repository.path + "/") }
      .map { String($0.path.dropFirst(repository.path.count + 1)) }
    if !excludedRoots.isEmpty {
      statusArguments += ["--", "."] + excludedRoots.map { ":(exclude)\($0)" }
    }
    let repositoryStatus = try runGit(statusArguments, at: repository)
    guard repositoryStatus.isEmpty else { throw WorktreeError.dirty(repository.path) }

    let mergeBase = try runGit(["merge-base", "HEAD", handle.branch], at: repository)
    let commitsText = try runGit(
      ["rev-list", "--reverse", "\(mergeBase)..\(handle.branch)"], at: repository)
    let commits = commitsText.split(whereSeparator: \.isNewline).map(String.init)
    guard !commits.isEmpty else { throw WorktreeError.noCommits(handle.branch) }

    do {
      _ = try runGit(["cherry-pick"] + commits, at: repository)
    } catch {
      _ = try? runGit(["cherry-pick", "--abort"], at: repository)
      throw error
    }
    let head = try runGit(["rev-parse", "HEAD"], at: repository)
    return WorktreeIntegration(handle: handle, commits: commits, repositoryHead: head)
  }

  public func cleanup(_ handle: WorktreeHandle) throws {
    try validateManagedPath(handle)
    if try isDirty(handle) { throw WorktreeError.dirty(handle.path) }
    try runGit(["worktree", "remove", handle.path], at: repository)
  }

  private func validateManagedPath(_ handle: WorktreeHandle) throws {
    let candidate = URL(fileURLWithPath: handle.path).standardizedFileURL
    let roots = [worktreeRoot] + (legacyWorktreeRoot.map { [$0] } ?? [])
    guard roots.contains(where: { candidate.path.hasPrefix($0.path + "/") }) else {
      throw WorktreeError.unsafePath(handle.path)
    }
  }

  @discardableResult
  private func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    #if os(Windows)
      process.executableURL = URL(fileURLWithPath: Self.windowsGit())
    #else
      _ = fcntl(output.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    #endif
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else { throw WorktreeError.git(text) }
    return text
  }

  #if os(Windows)
    /// Git for Windows on PATH, or its default install location.
    private static func windowsGit() -> String {
      let environment = ProcessInfo.processInfo.environment
      let path = environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
      for directory in path.split(separator: ";") {
        let candidate = URL(fileURLWithPath: String(directory)).appending(path: "git.exe").path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
      }
      return "C:\\Program Files\\Git\\cmd\\git.exe"
    }
  #endif

  private func changedPaths(at directory: URL) throws -> Set<String> {
    let tracked = try runGit(
      ["diff", "--no-ext-diff", "HEAD", "--name-only", "-z", "--", "."],
      at: directory
    )
    let untracked = try runGit(
      ["ls-files", "--others", "--exclude-standard", "-z", "--", "."],
      at: directory
    )
    return Set((tracked + "\0" + untracked).split(separator: "\0").map(String.init))
  }
}

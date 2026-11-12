import Combine
import Foundation

/// A repository Otto imported (issue #71). Repos are cloned into the workspace's `repos/`
/// folder so agent sessions and workflows can build on a concrete checkout. Only the reference
/// is persisted; the clone itself lives on disk.
public struct GitRepo: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  /// Short, filesystem-safe name (the repository name, without an owner).
  public var name: String
  /// Normalized clone URL (https, or loopback http).
  public var url: String
  public var addedAt: Date

  public init(id: UUID = UUID(), name: String, url: String, addedAt: Date = .now) {
    self.id = id
    self.name = name
    self.url = url
    self.addedAt = addedAt
  }
}

/// The current state of one imported repo, for the UI.
public enum RepoCloneState: Equatable, Sendable {
  case notCloned
  case cloning
  case cloned(at: String)
  case failed(String)
}

/// Signature for the git runner so tests can substitute a stub. Arguments are passed to `git`
/// (`[String]`) with the working directory the command runs in.
public typealias GitRun = @Sendable (_ arguments: [String], _ workingDirectory: URL) async throws -> Void

public enum RepoCloneError: LocalizedError, Equatable {
  case notAGitURL
  case missingRepositoryName
  case duplicateRepo
  case gitFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notAGitURL: "That doesn't look like a git repository URL."
    case .missingRepositoryName: "Could not work out a folder name for that repository."
    case .duplicateRepo: "That repository is already in your list."
    case .gitFailed(let detail): "git clone failed: \(detail)"
    }
  }
}

/// Per-workspace store of imported repositories. Mirrors `ConnectorAccessStore`: JSON persisted
/// under `.otto/`, loaded at init, written atomically on change. Main-actor-isolated because it
/// drives SwiftUI `@Published` state; the blocking git work runs on a detached task.
@MainActor
public final class ReposStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var repos: [GitRepo] = []
  @Published public private(set) var states: [UUID: RepoCloneState] = [:]

  private let fileURL: URL
  private let reposRoot: URL
  private let git: GitRun

  public init(
    workspacePath: String,
    fileManager: FileManager = .default,
    git: GitRun? = nil
  ) {
    let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
    self.fileURL = workspace.appending(path: ".otto/repos.json")
    self.reposRoot = workspace.appending(path: "repos", directoryHint: .isDirectory)
    self.git = git ?? Self.liveGit
    if let persisted = try? WorkspaceJSONFile.load(
      PersistedRepos.self, from: fileURL, fileManager: fileManager)
    {
      self.repos = persisted.repos
    }
    try? fileManager.createDirectory(at: reposRoot, withIntermediateDirectories: true)
  }

  // MARK: - Content

  /// Adds a repository from a pasted URL. Normalizes it, derives a folder name, and persists.
  /// Throws `RepoCloneError` when the URL is invalid or already present.
  @discardableResult
  public func add(_ rawURL: String) throws -> GitRepo {
    guard let url = Self.normalizeURL(rawURL) else { throw RepoCloneError.notAGitURL }
    guard let name = Self.repoName(from: url) else { throw RepoCloneError.missingRepositoryName }
    guard !repos.contains(where: { $0.url == url }) else { throw RepoCloneError.duplicateRepo }
    let repo = GitRepo(name: name, url: url)
    repos.append(repo)
    states[repo.id] = .notCloned
    try persist()
    return repo
  }

  /// Removes a repo and its local clone, if any.
  public func remove(_ repo: GitRepo, fileManager: FileManager = .default) throws {
    if let state = states[repo.id], case .cloned(let path) = state {
      try? fileManager.removeItem(at: URL(fileURLWithPath: path))
    }
    try? fileManager.removeItem(at: reposRoot.appending(path: repo.name))
    repos.removeAll { $0.id == repo.id }
    states[repo.id] = nil
    try persist()
  }

  /// Clones a repo (shallow) into `repos/<name>` under the workspace.
  public func clone(_ repo: GitRepo) async {
    let target = reposRoot.appending(path: repo.name)
    if case .cloned = states[repo.id] { return }
    states[repo.id] = .cloning
    // Hoist the sendable inputs before the detached task so the closure never captures `self`.
    let git = self.git
    let root = self.reposRoot
    do {
      try await Task.detached(priority: .utility) {
        try await git(["clone", "--depth", "1", repo.url, target.path], root)
      }.value
      states[repo.id] = .cloned(at: target.path)
    } catch {
      states[repo.id] = .failed(error.localizedDescription)
    }
  }

  /// The on-disk path a repo is (or will be) cloned to.
  public func cloneDirectory(for repo: GitRepo) -> URL {
    reposRoot.appending(path: repo.name)
  }

  // MARK: - Pure helpers

  /// Canonicalizes a repository URL. Accepts `https://…` and `http://` only to loopback,
  /// mirroring the app's SSRF guard, so Carl repo import cannot be made to reach arbitrary hosts.
  public static func normalizeURL(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
    if scheme == "http" {
      guard let host = url.host, Self.isLoopback(host) else { return nil }
    } else if scheme != "https" {
      return nil
    }
    var normalized = trimmed
    while normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized
  }

  /// Derives a safe folder name from a repository URL.
  public static func repoName(from urlString: String) -> String? {
    guard let url = URL(string: urlString) else { return nil }
    var last = url.lastPathComponent
    if last.hasSuffix(".git") { last.removeLast(4) }
    guard !last.isEmpty else { return nil }
    let safe = last.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    return safe.isEmpty ? nil : safe
  }

  private static func isLoopback(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" || lower == "[::1]" {
      return true
    }
    // 100.64.0.0/10 shared-address space (CGNAT) is also accepted by the app's guard.
    let parts = lower.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
    return parts.count == 4 && parts[0] == 100 && (parts[1] & 0xC0) == 0x40
  }

  private func persist() throws {
    let payload = PersistedRepos(schemaVersion: Self.currentSchemaVersion, repos: repos)
    try WorkspaceJSONFile.save(payload, to: fileURL, fileManager: .default)
  }

  private static let liveGit: GitRun = { arguments, workingDirectory in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = errors
    async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
    async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
    do {
      try process.run()
      process.waitUntilExit()
    }
    if process.terminationStatus != 0 {
      let message = String(decoding: await stderr, as: UTF8.self)
      throw RepoCloneError.gitFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    _ = await (stdout, stderr)
  }
}

private struct PersistedRepos: Codable {
  var schemaVersion: Int
  var repos: [GitRepo]
}

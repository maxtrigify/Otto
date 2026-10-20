import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Resolves where a supervised process is actually working: the live current directory straight
/// from the kernel (so a shell that has `cd`-ed reports where it really is, not where it
/// started) and the git repository and branch that directory sits in. Everything here is a
/// cheap syscall or a tiny file read — no subprocesses — so UI surfaces can refresh it on a
/// timer without cost.
public enum WorkingContext {
  public struct State: Equatable, Sendable {
    public var directory: String
    public var repoName: String?
    public var branch: String?

    /// The folder to headline: repo root name when inside a repo, else the directory name.
    public var displayName: String {
      if let repoName { return repoName }
      let name = (directory as NSString).lastPathComponent
      return name.isEmpty ? directory : name
    }

    public init(directory: String, repoName: String? = nil, branch: String? = nil) {
      self.directory = directory
      self.repoName = repoName
      self.branch = branch
    }
  }

  public static func resolve(pid: Int32?, fallbackDirectory: String?) -> State? {
    let directory =
      pid.flatMap(liveWorkingDirectory(pid:))
      ?? fallbackDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let directory, !directory.isEmpty else { return nil }
    guard let git = gitContext(for: directory) else {
      return State(directory: directory)
    }
    return State(directory: directory, repoName: git.repoName, branch: git.branch)
  }

  /// The process's current working directory, straight from the kernel.
  public static func liveWorkingDirectory(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    #if canImport(Darwin)
      var info = proc_vnodepathinfo()
      let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
      return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
        raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) }
      }
    #elseif os(Linux)
      let link = "/proc/\(pid)/cwd"
      guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link)
      else { return nil }
      return URL(fileURLWithPath: destination).standardizedFileURL.path
    #else
      return nil
    #endif
  }

  /// Walks up from `directory` to the enclosing git repository and reads the checked-out branch
  /// from HEAD directly. Worktrees (a `.git` file pointing at the real gitdir) are followed.
  public static func gitContext(for directory: String) -> (repoName: String, branch: String?)? {
    var current = URL(fileURLWithPath: directory).standardizedFileURL
    let fileManager = FileManager.default
    for _ in 0..<24 {
      let marker = current.appending(path: ".git")
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
        let gitDirectory = isDirectory.boolValue ? marker : linkedGitDirectory(marker)
        return (current.lastPathComponent, branch(inGitDirectory: gitDirectory))
      }
      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else { return nil }
      current = parent
    }
    return nil
  }

  /// A worktree's `.git` is a one-line file: `gitdir: /path/to/main/.git/worktrees/<name>`.
  private static func linkedGitDirectory(_ gitFile: URL) -> URL? {
    guard let contents = try? String(contentsOf: gitFile, encoding: .utf8),
      let line = contents.components(separatedBy: .newlines).first,
      line.hasPrefix("gitdir:")
    else { return nil }
    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path, relativeTo: gitFile.deletingLastPathComponent())
    return url.standardizedFileURL
  }

  private static func branch(inGitDirectory gitDirectory: URL?) -> String? {
    guard let gitDirectory,
      let head = try? String(
        contentsOf: gitDirectory.appending(path: "HEAD"), encoding: .utf8)
    else { return nil }
    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("ref:") {
      let reference = trimmed.dropFirst("ref:".count).trimmingCharacters(in: .whitespaces)
      if let range = reference.range(of: "refs/heads/") {
        return String(reference[range.upperBound...])
      }
      return (reference as NSString).lastPathComponent
    }
    // Detached HEAD: show the short commit rather than nothing.
    guard trimmed.count >= 7 else { return nil }
    return String(trimmed.prefix(7))
  }
}

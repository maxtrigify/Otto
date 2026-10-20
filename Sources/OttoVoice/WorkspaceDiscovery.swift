import Foundation

public enum WorkspaceDiscovery {
  private static let excludedDirectoryNames: Set<String> = [
    ".build", ".git", ".swiftpm", "Applications", "DerivedData", "Library", "Pods",
    "node_modules", "vendor",
  ]

  public static func gitRepositories(
    activeWorkspace: String,
    roots: [URL],
    maxDepth: Int = 4,
    limit: Int = 24,
    directoryScanLimit: Int = 3_000,
    fileManager: FileManager = .default
  ) -> [String] {
    let canonicalActiveWorkspace = URL(fileURLWithPath: activeWorkspace).standardizedFileURL
      .resolvingSymlinksInPath().path
    var repositories = Set([canonicalActiveWorkspace])
    var queue = roots.map { ($0.standardizedFileURL.resolvingSymlinksInPath(), 0) }
    var visited = Set<String>()
    var scannedDirectoryCount = 0

    while !queue.isEmpty, repositories.count < limit,
      scannedDirectoryCount < directoryScanLimit
    {
      let (directory, depth) = queue.removeFirst()
      let path = directory.resolvingSymlinksInPath().path
      guard visited.insert(path).inserted,
        fileManager.fileExists(atPath: path)
      else { continue }
      scannedDirectoryCount += 1

      if fileManager.fileExists(atPath: directory.appending(path: ".git").path) {
        repositories.insert(path)
        continue
      }
      guard depth < maxDepth,
        let children = try? fileManager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }
      for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard !excludedDirectoryNames.contains(child.lastPathComponent),
          (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { continue }
        queue.append((child, depth + 1))
      }
    }

    return Array(repositories).sorted().prefix(limit).map(\.self)
  }
}

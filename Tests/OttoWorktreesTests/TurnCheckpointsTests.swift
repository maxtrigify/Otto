import Foundation
import OttoWorktrees
import Testing

@Suite("Turn checkpoints")
struct TurnCheckpointsTests {
  @Test("A turn's edits, additions, and deletions are summarized between checkpoints")
  func summarizesTurn() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "one\ntwo\nthree\n")
    try repo.commitAll("base")

    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))

    try repo.write("existing.txt", "one\nTWO\nthree\nfour\n")
    try repo.write("created.txt", "fresh\n")
    try FileManager.default.removeItem(atPath: repo.file("todo-delete.txt"))

    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
    #expect(byPath.count == 3)
    #expect(byPath["created.txt"]?.additions == 1)
    #expect(byPath["created.txt"]?.deletions == 0)
    #expect(byPath["todo-delete.txt"]?.deletions == 1)
    #expect(byPath["existing.txt"]?.additions == 2)
    #expect(byPath["existing.txt"]?.deletions == 1)
    #expect(summary.totalAdditions == 3)
    #expect(summary.totalDeletions == 2)

    let fullDiff = try await store.unifiedDiff(
      in: repo.path, from: baseline, to: completion)
    #expect(fullDiff.contains("+TWO"))
    #expect(fullDiff.contains("+fresh"))
    let scoped = try await store.unifiedDiff(
      in: repo.path, from: baseline, to: completion, file: "created.txt")
    #expect(scoped.contains("+fresh"))
    #expect(!scoped.contains("TWO"))
  }

  @Test("Checkpoints never disturb the user's index, branch, or working tree")
  func leavesUserStateUntouched() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("tracked.txt", "committed\n")
    try repo.commitAll("base")
    // The user has a deliberately staged change and an unstaged one in flight.
    try repo.write("tracked.txt", "staged edit\n")
    try repo.git(["add", "tracked.txt"])
    try repo.write("unstaged.txt", "loose\n")
    let statusBefore = try repo.git(["status", "--porcelain=v1"])
    let headBefore = try repo.git(["rev-parse", "HEAD"])

    let store = TurnCheckpointStore()
    _ = try #require(try await store.captureCheckpoint(in: repo.path, agentID: UUID()))

    #expect(try repo.git(["status", "--porcelain=v1"]) == statusBefore)
    #expect(try repo.git(["rev-parse", "HEAD"]) == headBefore)
    #expect(try repo.git(["symbolic-ref", "HEAD"]).contains("refs/heads/"))
  }

  @Test("Binary files summarize without line counts")
  func binaryFiles() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.commitAll("base", allowEmpty: true)
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))

    try Data([0, 1, 2, 0, 4]).write(to: URL(fileURLWithPath: repo.file("blob.bin")))
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    #expect(summary.files.map(\.path) == ["blob.bin"])
    #expect(summary.files[0].additions == nil)
    #expect(summary.files[0].deletions == nil)
    #expect(summary.totalAdditions == 0)
  }

  @Test("Old checkpoints are pruned to the retention window")
  func prunesOldCheckpoints() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.commitAll("base", allowEmpty: true)
    let store = TurnCheckpointStore()
    let agentID = UUID()
    for turn in 0..<(TurnCheckpointStore.retainedCheckpointsPerAgent + 3) {
      try repo.write("churn.txt", "turn \(turn)\n")
      _ = try await store.captureCheckpoint(in: repo.path, agentID: agentID)
    }
    let refs = try repo.git([
      "for-each-ref", "--format=%(refname)", "refs/otto/checkpoints/\(agentID.uuidString)/",
    ])
    let count = refs.split(separator: "\n").count
    #expect(count == TurnCheckpointStore.retainedCheckpointsPerAgent)
  }

  @Test("Directories outside any repository yield no checkpoint")
  func nonRepositoryDirectories() async throws {
    let directory = NSTemporaryDirectory() + "otto-nonrepo-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let store = TurnCheckpointStore()
    #expect(try await store.captureCheckpoint(in: directory, agentID: UUID()) == nil)
  }

  @Test("Restore returns the workspace to the exact baseline without moving HEAD")
  func restoresBaseline() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "before\n")
    try repo.commitAll("base")
    let head = try repo.git(["rev-parse", "HEAD"])
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    try repo.write("existing.txt", "after\n")
    try repo.write("new.txt", "created\n")
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)

    try await store.restoreBaseline(summary)

    #expect(try String(contentsOfFile: repo.file("existing.txt"), encoding: .utf8) == "before\n")
    #expect(!FileManager.default.fileExists(atPath: repo.file("new.txt")))
    #expect(try repo.git(["rev-parse", "HEAD"]) == head)
  }

  @Test("Restore refuses to overwrite changes made after the completed turn")
  func restoreFailsClosedOnLaterChanges() async throws {
    let repo = try TemporaryRepo()
    defer { repo.cleanup() }
    try repo.write("existing.txt", "before\n")
    try repo.commitAll("base")
    let store = TurnCheckpointStore()
    let agentID = UUID()
    let baseline = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    try repo.write("existing.txt", "after\n")
    let completion = try #require(
      try await store.captureCheckpoint(in: repo.path, agentID: agentID))
    let summary = try await store.changeSummary(
      in: repo.path, from: baseline, to: completion)
    try repo.write("later.txt", "do not lose\n")

    await #expect(throws: TurnCheckpointError.self) {
      try await store.restoreBaseline(summary)
    }
    #expect(try String(contentsOfFile: repo.file("existing.txt"), encoding: .utf8) == "after\n")
    #expect(try String(contentsOfFile: repo.file("later.txt"), encoding: .utf8) == "do not lose\n")
  }
}

private struct TemporaryRepo {
  let path: String

  init() throws {
    path = NSTemporaryDirectory() + "otto-turnrepo-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try git(["init", "--initial-branch=main"])
    try git(["config", "user.name", "Test"])
    try git(["config", "user.email", "test@localhost"])
    try write("todo-delete.txt", "doomed\n")
  }

  func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

  func cleanup() { try? FileManager.default.removeItem(atPath: path) }

  func write(_ name: String, _ content: String) throws {
    try content.write(toFile: file(name), atomically: true, encoding: .utf8)
  }

  func commitAll(_ message: String, allowEmpty: Bool = false) throws {
    try git(["add", "-A"])
    var arguments = ["commit", "-m", message]
    if allowEmpty { arguments.append("--allow-empty") }
    try git(arguments)
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw TurnCheckpointError.git("git \(arguments.joined(separator: " ")) failed")
    }
    return String(decoding: output, as: UTF8.self)
  }
}

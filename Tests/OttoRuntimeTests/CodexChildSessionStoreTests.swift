import Foundation
import Testing

@testable import OttoRuntime

struct CodexChildSessionStoreTests {
  @Test func attributesOnlyMatchingChildrenAndObservesCompletion() async throws {
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let since = Date().addingTimeInterval(-2)
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy/MM/dd"
    let directory = home.appending(path: ".codex/sessions/" + format.string(from: since))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: since)
    let file = directory.appending(path: "child.jsonl")
    let padding = String(repeating: "x", count: 24_000)
    let metadata = """
      {"type":"session_meta","payload":{"id":"child","timestamp":"\(timestamp)","agent_nickname":"Verifier","instructions":"\(padding)","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}}}
      {"type":"event_msg","payload":{"type":"task_started"}}
      """
    try (metadata + "\n").write(to: file, atomically: true, encoding: .utf8)
    try metadata.replacingOccurrences(of: "parent", with: "other").write(
      to: directory.appending(path: "unrelated.jsonl"), atomically: true, encoding: .utf8)
    let reader = CodexChildSessionStore(home: home)
    let running = await reader.children(parentID: "parent", since: since)
    #expect(running.count == 1)
    #expect(running.first?.state == .working)
    let complete =
      metadata + "\n"
      + #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Checked"}}"#
      + "\n"
    try complete.write(to: file, atomically: true, encoding: .utf8)
    let done = await reader.children(parentID: "parent", since: since)
    #expect(done.first?.state == .done)
    #expect(done.first?.activity == "Checked")
    #expect(done.first?.startedAt == running.first?.startedAt)
  }

  @Test func installedCodexCaptureCanBeReadWhenExplicitlyRequested() async throws {
    guard let parent = ProcessInfo.processInfo.environment["OTTO_CODEX_CHILD_CAPTURE_PARENT"],
      let rawDate = ProcessInfo.processInfo.environment["OTTO_CODEX_CHILD_CAPTURE_SINCE"],
      let since = ISO8601DateFormatter().date(from: rawDate)
    else { return }
    let reader = CodexChildSessionStore()
    let children = await reader.children(parentID: parent, since: since)
    #expect(children.count == 2)
    #expect(children.allSatisfy { $0.state == .done })
    #expect(Set(children.map(\.activity)) == ["4", "6"])
  }
}

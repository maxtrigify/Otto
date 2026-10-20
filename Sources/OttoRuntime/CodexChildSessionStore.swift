import Foundation

/// Some Codex builds omit spawn events from exec stdout. Their rollout metadata still carries
/// explicit parent identity. Only attributed child tails are read; unrelated conversations are
/// never projected. This actor keeps disk IO off AgentSupervisor's executor.
actor CodexChildSessionStore {
  private let root: URL
  private var cache: [URL: (Date, Int, AgentChildRun)] = [:]

  init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    root = home.appending(path: ".codex/sessions")
  }

  func children(parentID: String, since: Date, now: Date = .now) -> [AgentChildRun] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy/MM/dd"
    let days = Set([formatter.string(from: since), formatter.string(from: now)])
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    let files = days.flatMap { day in
      (try? FileManager.default.contentsOfDirectory(
        at: root.appending(path: day), includingPropertiesForKeys: Array(keys))) ?? []
    }.filter { $0.pathExtension == "jsonl" }
      .compactMap { url -> (URL, Date, Int)? in
        guard let info = try? url.resourceValues(forKeys: keys),
          let date = info.contentModificationDate,
          date >= since.addingTimeInterval(-5)
        else { return nil }
        return (url, date, info.fileSize ?? 0)
      }.sorted { $0.1 > $1.1 }.prefix(128)
    var result: [AgentChildRun] = []
    for (url, date, size) in files {
      if let hit = cache[url], hit.0 == date, hit.1 == size {
        if hit.2.parentID == parentID { result.append(hit.2) }
        continue
      }
      guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
      defer { try? handle.close() }
      guard let head = try? handle.read(upToCount: 65_536),
        let first = head.split(separator: 10).first,
        let record = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
        record["type"] as? String == "session_meta",
        let metadata = record["payload"] as? [String: Any], let id = metadata["id"] as? String,
        let source = metadata["source"] as? [String: Any],
        let subagent = source["subagent"] as? [String: Any],
        let spawn = subagent["thread_spawn"] as? [String: Any],
        spawn["parent_thread_id"] as? String == parentID
      else { continue }
      let start = timestamp(metadata["timestamp"] as? String) ?? date
      // Resuming a parent does not resurrect children from an earlier turn.
      guard start >= since.addingTimeInterval(-5) else { continue }
      var child =
        cache[url]?.2
        ?? AgentChildRun(
          id: id,
          name: metadata["agent_nickname"] as? String ?? spawn["agent_nickname"] as? String
            ?? spawn["agent_path"] as? String ?? "Subagent",
          activity: "Starting", state: .starting, startedAt: start)
      child.parentID = parentID
      child.kind = "agent"
      let offset = max(0, size - 65_536)
      try? handle.seek(toOffset: UInt64(offset))
      guard let tail = try? handle.read(upToCount: 65_536) else { continue }
      var lines = tail.split(separator: 10)
      if offset > 0, !lines.isEmpty { lines.removeFirst() }
      var log: [String] = []
      var toolIDs: Set<String> = []
      for line in lines {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let payload = o["payload"] as? [String: Any]
        else { continue }
        let type = payload["type"] as? String
        if o["type"] as? String == "event_msg" {
          switch type {
          case "task_started":
            child.state = .working
            child.completedAt = nil
          case "task_complete":
            child.state = .done
            child.completedAt = timestamp(o["timestamp"] as? String) ?? date
            child.activity = String(
              (payload["last_agent_message"] as? String ?? "Completed").prefix(500))
          case "turn_aborted":
            child.state = .stopped
            child.completedAt = timestamp(o["timestamp"] as? String) ?? date
          default: break
          }
        } else if o["type"] as? String == "turn_context" {
          child.model = payload["model"] as? String ?? child.model
        } else if o["type"] as? String == "response_item", type == "function_call" {
          guard let tool = payload["name"] as? String else { continue }
          let rawInput = (payload["arguments"] as? String)?.data(using: .utf8)
          let input =
            rawInput.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
          // Explicit display fields only; never expose opaque/encrypted tool arguments.
          let detail =
            input["cmd"] as? String ?? input["command"] as? String ?? input["path"] as? String
            ?? input["file_path"] as? String ?? ""
          let activity = String((tool + (detail.isEmpty ? "" : " · " + detail)).prefix(500))
          log.append(activity)
          toolIDs.insert(payload["call_id"] as? String ?? activity)
          if child.state.isActive { child.activity = activity }
        }
      }
      if !log.isEmpty { child.activityLog = Array(log.suffix(40)) }
      child.toolCount = max(child.toolCount, toolIDs.count)
      cache[url] = (date, size, child)
      result.append(child)
    }
    if cache.count > 128 { cache = cache.filter { Set(files.map(\.0)).contains($0.key) } }
    return result.sorted { $0.startedAt < $1.startedAt }
  }

  private func timestamp(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
  }
}

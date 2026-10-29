import Foundation
import OttoModels

/// Normalizes provider-owned children. Tool-call completion is deliberately separate from
/// child completion: asynchronous spawn and wait calls can return while children keep working.
/// Only IDs carried by a provider are used for attribution; parent activity is never guessed.
struct NativeChildEventParser: Sendable {
  let provider: AgentProvider
  private var children: [String: AgentChildRun] = [:]
  private var aliases: [String: String] = [:]
  private var background: Set<String> = []
  private var resultTargets: [String: String] = [:]
  private var seenTools: Set<String> = []
  private var changed: [String] = []

  init(provider: AgentProvider) { self.provider = provider }

  mutating func ingest(_ line: String) -> (events: [ParsedAgentEvent], nested: Bool) {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return ([], false) }
    changed = []
    let parent = string(object, "parent_tool_use_id")
    switch provider {
    case .claudeCode, .grok: claude(object, parent: parent)
    case .codex, .openAI: codex(object)
    case .hermes: hermes(object)
    case .kimi: kimi(object)
    case .cursor: cursor(object)
    case .openCode: openCode(object)
    // Pi has no built-in subagents; anything of the kind comes from user extensions.
    case .pi, .shell: break
    }
    let isTaskEvent =
      string(object, "type") == "system"
      && ["task_started", "task_progress", "task_notification", "task_updated"].contains(
        string(object, "subtype") ?? "")
    return (
      changed.compactMap { children[$0].map(ParsedAgentEvent.childStarted) },
      parent != nil || isTaskEvent
    )
  }

  private mutating func start(
    _ id: String, input: [String: Any], name: String = "Subagent", parent: String? = nil,
    kind: String = "agent"
  ) {
    guard !id.isEmpty else { return }
    if children[id] == nil {
      // Keep a bounded retained history, never evict a live child.
      if children.count >= 200,
        let oldest = children.values.filter({ !$0.state.isActive }).min(by: {
          $0.startedAt < $1.startedAt
        })
      {
        children.removeValue(forKey: oldest.id)
        aliases = aliases.filter { $0.value != oldest.id }
        background.remove(oldest.id)
      }
      let label = string(input, "description", "name", "subagent_type", "subagentType") ?? name
      let task = string(input, "prompt", "goal", "task", "description", "command") ?? label
      var child = AgentChildRun(
        id: id, name: String(label.prefix(80)), activity: String(task.prefix(240)),
        model: string(input, "model"), effort: string(input, "effort"), state: .working)
      child.task = String(task.prefix(2_000))
      child.parentID = parent
      child.kind = kind
      child.activityLog = []
      children[id] = child
    }
    mark(id)
  }

  private mutating func update(
    _ rawID: String, text: String? = nil, state: AgentChildRunState? = nil, toolID: String? = nil,
    toolCount: Int? = nil, usage: [String: Any] = [:]
  ) {
    let id = aliases[rawID] ?? rawID
    guard var child = children[id] else { return }
    if let text, !text.isEmpty {
      let bounded = String(text.prefix(500))
      child.activity = String(bounded.prefix(240))
      if child.activityLog?.last != bounded {
        child.activityLog = Array(((child.activityLog ?? []) + [bounded]).suffix(40))
      }
    }
    if let state {
      child.state = state
      child.completedAt = state.isActive ? nil : child.completedAt ?? .now
    }
    if let toolID, seenTools.insert(id + ":" + toolID).inserted { child.toolCount += 1 }
    if let toolCount { child.toolCount = max(child.toolCount, toolCount) }
    child.inputTokens = usage["input_tokens"] as? Int ?? child.inputTokens
    child.outputTokens = usage["output_tokens"] as? Int ?? child.outputTokens
    children[id] = child
    mark(id)
  }

  private mutating func mark(_ id: String) {
    if !changed.contains(id) { changed.append(id) }
  }

  private func string(_ o: [String: Any], _ keys: String...) -> String? {
    keys.lazy.compactMap { o[$0] as? String }.first { !$0.isEmpty }
  }

  private func status(_ value: String?) -> AgentChildRunState? {
    switch value?.lowercased().replacingOccurrences(of: "_", with: "") {
    case "pendinginit", "pending", "starting": .starting
    case "running", "working", "inprogress": .working
    case "waiting", "waitingforinput", "blocked": .waiting
    case "completed", "complete", "done", "success": .done
    case "failed", "errored", "error": .failed
    case "killed", "stopped", "cancelled", "canceled", "shutdown", "interrupted": .stopped
    case "notfound": .unknown
    default: nil
    }
  }

  private func arguments(_ raw: Any?) -> [String: Any] {
    if let object = raw as? [String: Any] { return object }
    guard let text = raw as? String, let data = text.data(using: .utf8) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private mutating func claude(_ o: [String: Any], parent: String?) {
    let type = string(o, "type")
    if type == "system", let subtype = string(o, "subtype"),
      ["task_started", "task_progress", "task_notification", "task_updated"].contains(subtype),
      let taskID = string(o, "task_id")
    {
      let id = string(o, "tool_use_id") ?? aliases[taskID] ?? taskID
      aliases[taskID] = id
      let patch = o["patch"] as? [String: Any] ?? [:]
      let taskType = string(o, "task_type") ?? ""
      start(
        id, input: o, name: "Background task",
        kind: taskType.contains("bash") || taskType.contains("shell") ? "command" : "agent")
      if o["is_backgrounded"] as? Bool == true { background.insert(id) }
      update(
        id, text: string(o, "summary", "description") ?? string(patch, "description"),
        state: status(string(patch, "status") ?? string(o, "status")),
        toolCount: (o["usage"] as? [String: Any])?["tool_uses"] as? Int)
      return
    }
    let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    if type == "assistant" {
      for block in content {
        if string(block, "type") == "tool_use", let name = string(block, "name"),
          let id = string(block, "id")
        {
          let input = arguments(block["input"])
          if ["TaskOutput", "get_task_output"].contains(name),
            let target = string(input, "task_id", "id")
          {
            resultTargets[id] = target
          }
          let isChild = ["Agent", "Task", "task", "spawn_subagent", "delegate_task"].contains(name)
          let isJob =
            name == "Monitor" || (name == "Bash" && input["run_in_background"] as? Bool == true)
          if isChild || isJob {
            start(
              id, input: input, name: isJob ? "Background command" : "Subagent", parent: parent,
              kind: isJob ? "command" : "agent")
            if input["run_in_background"] as? Bool == true || name == "Monitor" {
              background.insert(id)
            }
          }
          if let parent {
            update(
              parent, text: name + " · " + ClaudeOutputParser.toolDetail(name: name, input: input),
              toolID: id)
          }
        } else if string(block, "type") == "text", let parent {
          update(parent, text: string(block, "text"))
        }
      }
    } else if type == "user" {
      let result = o["tool_use_result"] as? [String: Any] ?? [:]
      for block in content where string(block, "type") == "tool_result" {
        guard let id = string(block, "tool_use_id") else { continue }
        if let target = resultTargets.removeValue(forKey: id) {
          let payload =
            result.isEmpty ? arguments(KimiOutputParser.messageText(block["content"])) : result
          let task = payload["task"] as? [String: Any] ?? payload
          update(
            target, text: string(task, "output", "summary"), state: status(string(task, "status")))
          continue
        }
        guard children[id] != nil else { continue }
        if let taskID = string(result, "agentId", "task_id", "backgroundTaskId") {
          aliases[taskID] = id
        }
        let asynchronous =
          result["isAsync"] as? Bool == true || result["backgroundTaskId"] != nil
          || status(string(result, "status")) == .working
        if asynchronous { background.insert(id) }
        if block["is_error"] as? Bool == true {
          update(id, text: KimiOutputParser.messageText(block["content"]), state: .failed)
        } else if status(string(result, "status")) == .done || !background.contains(id) {
          let text = KimiOutputParser.messageText(result["content"] ?? block["content"])
          update(
            id, text: text, state: .done, toolCount: result["totalToolUseCount"] as? Int,
            usage: arguments(result["usage"]))
          if let model = string(result, "resolvedModel") { children[id]?.model = model }
        }
      }
    }
  }

  private mutating func codex(_ o: [String: Any]) {
    guard let item = o["item"] as? [String: Any], let type = string(item, "type"),
      ["collab_tool_call", "collaboration_tool_call", "subagent", "agent_task"].contains(type)
    else { return }
    let states = item["agents_states"] as? [String: [String: Any]] ?? [:]
    let receivers = item["receiver_thread_ids"] as? [String] ?? []
    let ids = Array(Set(receivers + Array(states.keys))).sorted()
    if !ids.isEmpty {
      for id in ids {
        start(id, input: item)
        let state = states[id] ?? [:]
        // `item.completed` means the spawn/wait tool returned, NOT that the child finished.
        update(id, text: string(state, "message"), state: status(string(state, "status")))
      }
    } else if type == "subagent" || type == "agent_task", let id = string(item, "agent_id", "id") {
      start(id, input: item)
      update(id, state: status(string(item, "status")), usage: arguments(item["usage"]))
    }
  }

  private mutating func hermes(_ o: [String: Any]) {
    guard let type = string(o, "type"), type.hasPrefix("subagent."),
      let p = o["payload"] as? [String: Any], let id = string(p, "subagent_id", "child_session_id")
    else { return }
    start(id, input: p, name: string(p, "goal") ?? "Subagent", parent: string(p, "parent_id"))
    let text = string(p, "summary", "tool_preview", "text")
    update(
      id, text: text,
      state: status(string(p, "status")) ?? (type == "subagent.complete" ? .done : nil),
      toolCount: p["tool_count"] as? Int, usage: p)
  }

  private mutating func kimi(_ o: [String: Any]) {
    if string(o, "role") == "assistant" {
      for call in o["tool_calls"] as? [[String: Any]] ?? [] {
        let function = arguments(call["function"])
        guard ["Task", "Agent"].contains(string(function, "name") ?? ""),
          let id = string(call, "id")
        else { continue }
        start(id, input: arguments(function["arguments"]))
      }
    } else if string(o, "role") == "tool", let id = string(o, "tool_call_id") {
      update(
        id, text: KimiOutputParser.messageText(o["content"]),
        state: o["is_error"] as? Bool == true ? .failed : .done)
    }
  }

  private mutating func cursor(_ o: [String: Any]) {
    guard string(o, "type") == "tool_call", let id = string(o, "call_id"),
      let call = o["tool_call"] as? [String: Any], let task = call["taskToolCall"] as? [String: Any]
    else { return }
    start(id, input: arguments(task["args"]))
    guard string(o, "subtype") == "completed" else { return }
    let result = arguments(task["result"])
    let success = arguments(result["success"])
    if success["isBackground"] as? Bool == true {
      background.insert(id)
      update(id, text: "Running in background; awaiting provider completion")
    } else {
      update(
        id, text: string(success, "result", "summary", "text"),
        state: result["error"] != nil ? .failed : .done)
    }
  }

  private mutating func openCode(_ o: [String: Any]) {
    guard string(o, "type") == "tool_use", let part = o["part"] as? [String: Any],
      ["task", "subagent"].contains(string(part, "tool") ?? ""),
      let id = string(part, "callID", "id")
    else { return }
    let state = arguments(part["state"])
    start(id, input: arguments(state["input"]))
    update(
      id, text: string(state, "output", "error", "title"), state: status(string(state, "status")))
  }
}

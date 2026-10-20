import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Native child lifecycle")
struct NativeChildEventParserTests {
  private func children(_ events: [ParsedAgentEvent]) -> [AgentChildRun] {
    events.compactMap { if case .childStarted(let child) = $0 { child } else { nil } }
  }

  @Test func claudeBackgroundCompletionAndAttribution() throws {
    var p = ClaudeOutputParser()
    _ = p.ingest(
      line:
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a","name":"Agent","input":{"description":"First","run_in_background":true}},{"type":"tool_use","id":"b","name":"Agent","input":{"description":"Second"}}]}}"#
    )
    let nested = p.ingest(
      line:
        #"{"type":"assistant","parent_tool_use_id":"a","message":{"content":[{"type":"tool_use","id":"read1","name":"Read","input":{"file_path":"README.md"}}]}}"#
    )
    let first = try #require(children(nested).first)
    #expect(first.id == "a")
    #expect(first.toolCount == 1)
    #expect(first.activity.contains("README.md"))
    #expect(nested.count == 1)  // no child output leaked into parent transcript
    let launched = p.ingest(
      line:
        #"{"type":"user","tool_use_result":{"isAsync":true,"agentId":"task-a"},"message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"Launched"}]}}"#
    )
    #expect(children(launched).allSatisfy { $0.state != .done })
    let completed = p.ingest(
      line:
        #"{"type":"system","subtype":"task_notification","task_id":"task-a","status":"completed","summary":"Checked README"}"#
    )
    #expect(children(completed).last?.id == "a")
    #expect(children(completed).last?.state == .done)
    #expect(children(completed).last?.toolCount == 1)
  }

  @Test func claudeTaskUpdatesAndWatchers() {
    var p = ClaudeOutputParser()
    _ = p.ingest(
      line:
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"watch","name":"Monitor","input":{"command":"watch-build"}}]}}"#
    )
    _ = p.ingest(
      line:
        #"{"type":"system","subtype":"task_started","tool_use_id":"watch","task_id":"w","task_type":"local_bash","description":"Watch build"}"#
    )
    let progress = p.ingest(
      line:
        #"{"type":"system","subtype":"task_progress","task_id":"w","description":"Waiting for build","usage":{"tool_uses":4}}"#
    )
    #expect(children(progress).last?.state == .working)
    #expect(children(progress).last?.kind == "command")
    let stopped = p.ingest(
      line: #"{"type":"system","subtype":"task_updated","task_id":"w","patch":{"status":"killed"}}"#
    )
    #expect(children(stopped).last?.state == .stopped)
  }

  @Test func codexSpawnAndWaitReturnDoNotFinishChildren() throws {
    var p = CodexOutputParser()
    let spawn = p.ingest(
      line:
        #"{"type":"item.completed","item":{"type":"collab_tool_call","id":"spawn-call","tool":"spawn_agent","receiver_thread_ids":["child"],"prompt":"Check build","agents_states":{"child":{"status":"running","message":null}},"status":"completed"}}"#
    )
    #expect(children(spawn).first?.id == "child")
    #expect(children(spawn).first?.state == .working)
    let started = try #require(children(spawn).first?.startedAt)
    let wait = p.ingest(
      line:
        #"{"type":"item.completed","item":{"type":"collab_tool_call","id":"wait-call","tool":"wait","receiver_thread_ids":["child"],"agents_states":{},"status":"completed"}}"#
    )
    #expect(children(wait).last?.state == .working)
    #expect(children(wait).last?.startedAt == started)
    let done = p.ingest(
      line:
        #"{"type":"item.completed","item":{"type":"collab_tool_call","id":"wait-2","tool":"wait","receiver_thread_ids":["child"],"agents_states":{"child":{"status":"completed","message":"Build passed"}},"status":"completed"}}"#
    )
    #expect(children(done).last?.state == .done)
    #expect(children(done).last?.activity == "Build passed")
  }

  @Test func hermesPreservesNestedIdentityAndUsage() {
    var p = HermesOutputParser()
    _ = p.ingest(
      line:
        #"{"type":"subagent.start","payload":{"subagent_id":"h","parent_id":"parent","goal":"Review","model":"test"}}"#
    )
    let tool = p.ingest(
      line:
        #"{"type":"subagent.tool","payload":{"subagent_id":"h","tool_preview":"Read auth.swift","tool_count":3}}"#
    )
    #expect(children(tool).last?.toolCount == 3)
    let done = p.ingest(
      line:
        #"{"type":"subagent.complete","payload":{"subagent_id":"h","status":"error","summary":"Read failed","input_tokens":200,"output_tokens":30}}"#
    )
    #expect(children(done).last?.state == .failed)
    #expect(children(done).last?.parentID == "parent")
    #expect(children(done).last?.inputTokens == 200)
  }

  @Test func remainingHarnessesSurfaceTheirNativeTasks() {
    var kimi = KimiOutputParser()
    let start = kimi.ingest(
      line:
        #"{"role":"assistant","tool_calls":[{"id":"k","function":{"name":"Task","arguments":"{\"description\":\"Search\",\"prompt\":\"Find tests\"}"}}]}"#
    )
    #expect(children(start).first?.name == "Search")
    #expect(
      children(kimi.ingest(line: #"{"role":"tool","tool_call_id":"k","content":"Found tests"}"#))
        .last?.state == .done)
    var cursor = CursorOutputParser()
    let background = cursor.ingest(
      line:
        #"{"type":"tool_call","subtype":"completed","call_id":"c","tool_call":{"taskToolCall":{"args":{"description":"Review"},"result":{"success":{"isBackground":true}}}}}"#
    )
    #expect(children(background).last?.state == .working)
    var openCode = OpenCodeOutputParser()
    let done = openCode.ingest(
      line:
        #"{"type":"tool_use","part":{"callID":"o","tool":"task","state":{"status":"completed","input":{"description":"Review"},"output":"Checked"}}}"#
    )
    #expect(children(done).last?.state == .done)
    var grok = ProviderParser.forProvider(.grok)
    #expect(
      children(
        grok.ingest(
          line:
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"g","name":"Agent","input":{"description":"Review"}}]}}"#
        )
      ).first?.state == .working)
  }

  @Test func capturedClaudeRunHasTwoCompletedChildren() throws {
    let url = try #require(
      Bundle.module.url(
        forResource: "claude_children_live", withExtension: "jsonl", subdirectory: "Fixtures"))
    var p = ClaudeOutputParser()
    var latest: [String: AgentChildRun] = [:]
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
      for child in children(p.ingest(line: String(line))) { latest[child.id] = child }
    }
    #expect(latest.count == 2)
    #expect(latest.values.allSatisfy { $0.state == .done })
  }

  @Test func nestedProseDoesNotReplaceParentProjection() {
    let text =
      #"{"type":"assistant","message":{"content":[{"type":"text","text":"Parent"}]}}"# + "\n"
      + #"{"type":"stream_event","parent_tool_use_id":"child","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Child"}}}"#
    #expect(ProviderConversationProjection.liveText(from: text, provider: .claudeCode) == "Parent")
  }

  @Test func ottoDelegationUsesTheSupervisedChildState() async throws {
    let supervisor = AgentSupervisor()
    do {
      let parent = try await supervisor.spawnDeterministicMock()
      let child = try await supervisor.spawnDeterministicMock()
      await supervisor.registerDelegatedChild(parentID: parent, childID: child, name: "Verifier")
      let before = try await supervisor.snapshot(agentID: parent)
      try await supervisor.stop(agentID: child)
      let after = try await supervisor.snapshot(agentID: parent)
      await supervisor.stopAll()
      #expect(before.childRuns.count == 1)
      #expect(before.childRuns.first?.id == child.uuidString)
      #expect(after.childRuns.first?.state == .stopped)
    } catch {
      await supervisor.stopAll()
      throw error
    }
  }

  @Test func unknownEventsNeverInventChildren() {
    for provider in AgentProvider.allCases {
      var p = ProviderParser.forProvider(provider)
      #expect(
        children(p.ingest(line: #"{"type":"tool_call","tool":"Read","id":"random"}"#)).isEmpty)
    }
  }
}

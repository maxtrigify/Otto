import Foundation
import OttoTools
import Testing

@testable import OttoHarness

@Suite("Otto-owned agent harness")
struct HarnessTests {
  @Test("Otto owns resumable history while system instructions refresh every turn")
  func resumeUsesCanonicalHistoryAndFreshSystem() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = HarnessSessionStore(rootURL: fixture.url)
    let runner = HarnessRunner(sessionStore: store)
    let backend = ScriptedBackend(
      providerID: "provider-a",
      responses: [
        HarnessBackendResponse(providerContinuation: .string("provider-1"), text: "first answer"),
        HarnessBackendResponse(providerContinuation: .string("provider-2"), text: "second answer"),
      ])

    let first = try await runner.run(
      HarnessTurnRequest(
        providerID: "provider-a", modelID: "model-a",
        systemInstructions: "Original bot instructions", prompt: "first question"),
      backend: backend)
    let second = try await runner.run(
      HarnessTurnRequest(
        sessionID: first.sessionID,
        providerID: "provider-a", modelID: "model-a",
        systemInstructions: "Revised bot instructions", prompt: "second question"),
      backend: backend)

    #expect(second.sessionID == first.sessionID)
    let requests = await backend.recordedRequests()
    #expect(requests.count == 2)
    #expect(requests[0].systemInstructions == "Original bot instructions")
    #expect(requests[1].systemInstructions == "Revised bot instructions")
    guard case .conversation(let history) = requests[1].input else {
      Issue.record("Expected canonical conversation input")
      return
    }
    #expect(history.map(\.content) == ["first question", "first answer", "second question"])
    #expect(requests[1].providerContinuation == nil)
  }

  @Test("A session can change model backend without losing Otto history")
  func switchesBackend() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let runner = HarnessRunner(sessionStore: HarnessSessionStore(rootURL: fixture.url))
    let firstBackend = ScriptedBackend(
      providerID: "provider-a",
      responses: [HarnessBackendResponse(text: "answer from A")])
    let secondBackend = ScriptedBackend(
      providerID: "provider-b",
      responses: [HarnessBackendResponse(text: "answer from B")])
    let first = try await runner.run(
      HarnessTurnRequest(
        providerID: "provider-a", modelID: "model-a",
        systemInstructions: "system", prompt: "hello"),
      backend: firstBackend)
    _ = try await runner.run(
      HarnessTurnRequest(
        sessionID: first.sessionID,
        providerID: "provider-b", modelID: "model-b",
        systemInstructions: "current system", prompt: "continue"),
      backend: secondBackend)

    let requests = await secondBackend.recordedRequests()
    guard case .conversation(let history) = try #require(requests.first).input else {
      Issue.record("Expected conversation history")
      return
    }
    #expect(history.map(\.content) == ["hello", "answer from A", "continue"])
    #expect(requests[0].systemInstructions == "current system")
  }

  @Test("Tool execution is controlled by the harness")
  func toolLoop() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let backend = ScriptedBackend(
      providerID: "provider-a",
      responses: [
        HarnessBackendResponse(
          providerContinuation: .string("round-1"),
          toolCalls: [HarnessToolCall(id: "call-1", name: "brain_search", arguments: .object([:]))]),
        HarnessBackendResponse(
          providerContinuation: .string("round-2"), text: "Used remembered context"),
      ])
    let executor = RecordingToolExecutor(output: "A saved decision")
    let runner = HarnessRunner(sessionStore: HarnessSessionStore(rootURL: fixture.url))
    _ = try await runner.run(
      HarnessTurnRequest(
        providerID: "provider-a", modelID: "model-a", systemInstructions: "system",
        prompt: "What did we decide?",
        tools: [
          HarnessTool(
            name: "brain_search", description: "Search memory", inputSchema: .object([:]))
        ]),
      backend: backend,
      toolExecutor: executor)

    let calls = await executor.recordedCalls()
    #expect(calls.map(\.name) == ["brain_search"])
    let requests = await backend.recordedRequests()
    guard case .toolResults(let results) = requests[1].input else {
      Issue.record("Expected tool results")
      return
    }
    #expect(results == [HarnessToolResult(callID: "call-1", output: "A saved decision")])
    #expect(requests[1].systemInstructions == "system")
    #expect(requests[1].providerContinuation == .string("round-1"))
  }

  @Test("Stored transcripts are bounded and private")
  func boundedPrivateStorage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = HarnessSessionStore(
      rootURL: fixture.url,
      limits: .init(maximumMessages: 4, maximumUTF8Bytes: 1_024))
    var session = HarnessSession(providerID: "openai", modelID: "model")
    session.messages = (0..<8).map {
      HarnessMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "message-\($0)")
    }
    try await store.save(session)

    let loaded = try await store.load(sessionID: session.id)
    #expect(loaded.messages.map(\.content) == ["message-4", "message-5", "message-6", "message-7"])
    #expect(
      loaded.archivedMessages?.map(\.content) == [
        "message-0", "message-1", "message-2", "message-3",
      ])
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.url.appending(path: "\(session.id).json").path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("OpenAI transport encodes the current system role and canonical history")
  func openAIRequestEncoding() throws {
    let backend = OpenAIResponsesBackend(apiKey: "test")
    let data = try backend.requestBody(
      for: HarnessBackendRequest(
        systemInstructions: "authoritative system",
        modelID: "gpt-test",
        input: .conversation([
          HarnessMessage(role: .user, content: "prior user"),
          HarnessMessage(role: .assistant, content: "prior assistant"),
          HarnessMessage(role: .user, content: "current user"),
        ])))
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input[0]["role"] as? String == "system")
    #expect(input[0]["content"] as? String == "authoritative system")
    #expect(
      input.dropFirst().compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
    #expect(body["previous_response_id"] == nil)
  }

  @Test("Anthropic receives an authoritative system prompt and native tool continuation")
  func anthropicRequestAndToolContinuation() throws {
    let backend = AnthropicMessagesBackend(apiKey: "test")
    let request = HarnessBackendRequest(
      systemInstructions: "authoritative system",
      modelID: "claude-sonnet-5",
      reasoningEffort: "high",
      input: .conversation([HarnessMessage(role: .user, content: "research this")]),
      tools: [
        HarnessTool(
          name: "brain.search", description: "Search memory",
          inputSchema: .object(["type": .string("object")]))
      ])
    let firstBody = try backend.requestBody(for: request)
    let first = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
    #expect(first["system"] as? String == "authoritative system")
    #expect((first["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect((first["output_config"] as? [String: Any])?["effort"] as? String == "high")
    let tools = try #require(first["tools"] as? [[String: Any]])
    #expect(tools.first?["name"] as? String == "brain_search")
    #expect(tools.first?["input_schema"] is [String: Any])

    let response = try backend.parseResponse(
      Data(
        #"{"content":[{"type":"thinking","thinking":"private"},{"type":"tool_use","id":"tool-1","name":"brain_search","input":{"query":"decision"}}]}"#
          .utf8),
      priorMessages: [.object(["role": .string("user"), "content": .string("research this")])])
    #expect(response.toolCalls.first?.name == "brain_search")
    let continuationBody = try backend.requestBody(
      for: HarnessBackendRequest(
        systemInstructions: "revised authoritative system",
        modelID: "claude-sonnet-5",
        input: .toolResults([HarnessToolResult(callID: "tool-1", output: "saved decision")]),
        providerContinuation: response.providerContinuation))
    let continuation = try #require(
      JSONSerialization.jsonObject(with: continuationBody) as? [String: Any])
    #expect(continuation["system"] as? String == "revised authoritative system")
    let messages = try #require(continuation["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
    let resultBlocks = try #require(messages.last?["content"] as? [[String: Any]])
    #expect(resultBlocks.first?["type"] as? String == "tool_result")
    #expect(resultBlocks.first?["tool_use_id"] as? String == "tool-1")
  }

  @Test("Kimi-compatible chat receives system instructions and tool messages")
  func chatCompletionsRequestAndToolContinuation() throws {
    let backend = OpenAIChatCompletionsBackend(
      apiKey: "test", providerID: "moonshot", providerDisplayName: "Moonshot",
      endpoint: URL(string: "https://example.invalid/chat/completions")!)
    let request = HarnessBackendRequest(
      systemInstructions: "authoritative system",
      modelID: "kimi-k2.5",
      input: .conversation([HarnessMessage(role: .user, content: "research this")]),
      tools: [
        HarnessTool(
          name: "brain.search", description: "Search memory",
          inputSchema: .object(["type": .string("object")]))
      ])
    let firstBody = try backend.requestBody(for: request)
    let first = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
    let firstMessages = try #require(first["messages"] as? [[String: Any]])
    #expect(firstMessages.first?["role"] as? String == "system")
    #expect(firstMessages.first?["content"] as? String == "authoritative system")

    let response = try backend.parseResponse(
      Data(
        #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call-1","type":"function","function":{"name":"brain_search","arguments":"{\"query\":\"decision\"}"}}]}}]}"#
          .utf8),
      priorMessages: firstMessages.map { try! HarnessJSON.value($0) })
    #expect(response.toolCalls.first?.name == "brain_search")
    let continuationBody = try backend.requestBody(
      for: HarnessBackendRequest(
        systemInstructions: "authoritative system",
        modelID: "kimi-k2.5",
        input: .toolResults([HarnessToolResult(callID: "call-1", output: "saved decision")]),
        providerContinuation: response.providerContinuation))
    let continuation = try #require(
      JSONSerialization.jsonObject(with: continuationBody) as? [String: Any])
    let messages = try #require(continuation["messages"] as? [[String: Any]])
    #expect(messages.last?["role"] as? String == "tool")
    #expect(messages.last?["tool_call_id"] as? String == "call-1")
    #expect(messages.last?["content"] as? String == "saved decision")
  }
}

private actor ScriptedBackend: HarnessModelBackend {
  nonisolated let providerID: String
  private var responses: [HarnessBackendResponse]
  private var requests: [HarnessBackendRequest] = []

  init(providerID: String, responses: [HarnessBackendResponse]) {
    self.providerID = providerID
    self.responses = responses
  }

  func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse {
    requests.append(request)
    return responses.removeFirst()
  }

  func recordedRequests() -> [HarnessBackendRequest] { requests }
}

private actor RecordingToolExecutor: HarnessToolExecutor {
  private let output: String
  private var calls: [HarnessToolCall] = []

  init(output: String) { self.output = output }

  func execute(_ call: HarnessToolCall) async throws -> String {
    calls.append(call)
    return output
  }

  func recordedCalls() -> [HarnessToolCall] { calls }
}

private struct Fixture {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appending(path: "otto-harness-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }
}

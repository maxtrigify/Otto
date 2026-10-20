import Foundation
import OttoControl
import OttoHarness
import OttoModels
import OttoTools

private enum DirectRuntimeError: Error, LocalizedError {
  case invalidArguments(String)
  case missingAPIKey(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let detail): detail
    case .missingAPIKey(let provider):
      "\(provider) API key is missing. Add it in Otto Settings → Models, then retry."
    }
  }
}

private struct Options {
  var idle = false
  var prompt = ""
  var system = ""
  var backend = "openai"
  var model = "gpt-5.6"
  var effort: String?
  var resumeID: String?

  init(arguments: [String]) throws {
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      switch flag {
      case "--idle": idle = true
      case "--prompt-base64": prompt = try Self.decode(Self.value(after: &index, in: arguments))
      case "--system-base64": system = try Self.decode(Self.value(after: &index, in: arguments))
      case "--backend": backend = try Self.value(after: &index, in: arguments)
      case "--model": model = try Self.value(after: &index, in: arguments)
      case "--effort": effort = try Self.value(after: &index, in: arguments)
      // Keep the old spelling so sessions created by the 0.1.22 direct runtime migrate cleanly.
      case "--session-id", "--previous-response-id":
        resumeID = try Self.value(after: &index, in: arguments)
      default: throw DirectRuntimeError.invalidArguments("Unknown option: \(flag)")
      }
      index += 1
    }
    if !idle, prompt.isEmpty {
      throw DirectRuntimeError.invalidArguments("A prompt is required")
    }
  }

  private static func value(after index: inout Int, in arguments: [String]) throws -> String {
    index += 1
    guard index < arguments.count else {
      throw DirectRuntimeError.invalidArguments("Missing value for \(arguments[index - 1])")
    }
    return arguments[index]
  }

  private static func decode(_ encoded: String) throws -> String {
    guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8)
    else { throw DirectRuntimeError.invalidArguments("Invalid base64 argument") }
    return value
  }
}

private struct ControlToolExecutor: HarnessToolExecutor {
  let client: ControlClient
  let actualNames: [String: String]

  func execute(_ call: HarnessToolCall) async throws -> String {
    guard let actualName = actualNames[call.name] else {
      throw DirectRuntimeError.invalidArguments("Unknown Otto tool: \(call.name)")
    }
    let result = try await client.callAsync(
      actualName,
      arguments: call.arguments,
      requestID: call.id,
      timeoutMilliseconds: 3_600_000)
    guard let data = try? JSONEncoder().encode(result) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }
}

@main
private enum OttoOpenAIAgent {
  static func main() async {
    if CommandLine.arguments.dropFirst().contains("--version") {
      print("otto-openai-agent 3.0.0")
      return
    }
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.idle {
        emit(["type": "thread.started", "thread_id": HarnessSession.makeID()])
        while readLine() != nil {}
        return
      }
      try await run(options)
    } catch {
      emit(["type": "turn.failed", "message": error.localizedDescription])
      Foundation.exit(1)
    }
  }

  private static func run(_ options: Options) async throws {
    let providerName = providerDisplayName(options.backend)
    let apiKey =
      (OttoEnvironment.value("MODEL_API_KEY")
      ?? OttoEnvironment.value("OPENAI_API_KEY"))?.trimmingCharacters(
        in: .whitespacesAndNewlines)
    guard let apiKey, !apiKey.isEmpty else { throw DirectRuntimeError.missingAPIKey(providerName) }

    let client = controlClient()
    let definitions = (try? await client?.listToolsAsync()) ?? []
    let callable = definitions.filter { !$0.isProviderInternal && !$0.requiresConfirmation }
    let rawTools = callable.map {
      HarnessTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
    }
    let backend = try modelBackend(id: options.backend, apiKey: apiKey)
    let nameMap = HarnessToolNaming.safeNames(rawTools)
    let definitionByName = Dictionary(uniqueKeysWithValues: rawTools.map { ($0.name, $0) })
    let tools = nameMap.compactMap { exposedName, actualName -> HarnessTool? in
      guard let definition = definitionByName[actualName] else { return nil }
      return HarnessTool(
        name: exposedName,
        description: definition.description,
        inputSchema: definition.inputSchema)
    }
    let executor = client.map { ControlToolExecutor(client: $0, actualNames: nameMap) }
    let isOttoSession = options.resumeID.map(HarnessSession.isOttoID) == true
    // Only the retired OpenAI-only helper emitted raw Responses API ids. Such an id is opaque to
    // every other provider, so switching model vendor must begin from Otto's canonical history.
    let legacyOpenAIResponseID =
      backend.providerID == "openai" && !isOttoSession
      ? options.resumeID : nil
    let request = HarnessTurnRequest(
      sessionID: isOttoSession ? options.resumeID : nil,
      legacyProviderResponseID: legacyOpenAIResponseID,
      providerID: backend.providerID,
      modelID: options.model,
      reasoningEffort: options.effort,
      systemInstructions: options.system,
      prompt: options.prompt,
      tools: tools)
    let runner = HarnessRunner(sessionStore: HarnessSessionStore())
    let result = try await runner.run(
      request,
      backend: backend,
      toolExecutor: executor,
      onEvent: { event in
        switch event {
        case .sessionStarted(let sessionID):
          emit(["type": "thread.started", "thread_id": sessionID])
          emit(["type": "turn.started"])
        case .toolStarted(let name):
          emit([
            "type": "item.completed",
            "item": [
              "type": "mcp_tool_call", "server": "otto", "tool": nameMap[name] ?? name,
            ],
          ])
        }
      })
    emit(["type": "item.completed", "item": ["type": "agent_message", "text": result.text]])
    emit(["type": "turn.completed"])
  }

  private static func modelBackend(id: String, apiKey: String) throws -> any HarnessModelBackend {
    switch id {
    case "openai":
      OpenAIResponsesBackend(apiKey: apiKey)
    case "anthropic":
      AnthropicMessagesBackend(apiKey: apiKey)
    case "xai":
      OpenAIResponsesBackend(
        apiKey: apiKey,
        providerID: "xai",
        providerDisplayName: "xAI",
        endpoint: URL(string: "https://api.x.ai/v1/responses")!)
    case "moonshot":
      OpenAIChatCompletionsBackend(
        apiKey: apiKey,
        providerID: "moonshot",
        providerDisplayName: "Moonshot",
        endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!)
    default:
      throw DirectRuntimeError.invalidArguments("Unknown model backend: \(id)")
    }
  }

  private static func providerDisplayName(_ id: String) -> String {
    switch id {
    case "anthropic": "Anthropic"
    case "xai": "xAI"
    case "moonshot": "Moonshot"
    default: "OpenAI"
    }
  }

  private static func controlClient() -> ControlClient? {
    let environment = ProcessInfo.processInfo.environment
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment),
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment)
    else { return nil }
    return ControlClient(
      socketPath: socket,
      token: token,
      sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
        UUID.init(uuidString:)),
      sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
        UUID.init(uuidString:)))
  }

  private static func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      var line = String(data: data, encoding: .utf8)
    else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
  }
}

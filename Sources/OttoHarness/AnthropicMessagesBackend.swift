import Foundation
import OttoTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct AnthropicMessagesBackend: HarnessModelBackend {
  public let providerID = "anthropic"
  private let apiKey: String
  private let endpoint: URL
  private let session: URLSession
  private let maximumOutputTokens: Int

  public init(
    apiKey: String,
    endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
    session: URLSession = .shared,
    maximumOutputTokens: Int = 16_000
  ) {
    self.apiKey = apiKey
    self.endpoint = endpoint
    self.session = session
    self.maximumOutputTokens = maximumOutputTokens
  }

  public func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse {
    let messages = try requestMessages(for: request)
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    urlRequest.httpBody = try requestBody(for: request, messages: messages)
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let message =
        ((object?["error"] as? [String: Any])?["message"] as? String)
        ?? String(decoding: data.prefix(2_000), as: UTF8.self)
      throw HarnessError.providerRequestFailed("Anthropic request failed: \(message)")
    }
    return try parseResponse(data, priorMessages: messages)
  }

  func requestBody(for request: HarnessBackendRequest, messages: [JSONValue]? = nil) throws -> Data
  {
    let messages = try messages ?? requestMessages(for: request)
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "max_tokens": .number(Double(maximumOutputTokens)),
      "system": .string(request.systemInstructions),
      "messages": .array(messages),
    ]
    if !request.tools.isEmpty {
      let names = HarnessToolNaming.safeNames(request.tools)
      body["tools"] = .array(
        request.tools.compactMap { tool in
          guard let name = names.first(where: { $0.value == tool.name })?.key else { return nil }
          return .object([
            "name": .string(name),
            "description": .string(String(tool.description.prefix(1_024))),
            "input_schema": tool.inputSchema,
          ])
        })
    }
    if let effort = request.reasoningEffort {
      body["thinking"] = .object(["type": .string("adaptive")])
      body["output_config"] = .object(["effort": .string(effort)])
    }
    return try JSONEncoder().encode(JSONValue.object(body))
  }

  func parseResponse(_ data: Data, priorMessages: [JSONValue]) throws -> HarnessBackendResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rawContent = object["content"] as? [[String: Any]]
    else { throw HarnessError.malformedProviderResponse("Anthropic returned malformed JSON.") }
    var text: [String] = []
    var toolCalls: [HarnessToolCall] = []
    for block in rawContent {
      switch block["type"] as? String {
      case "text":
        if let value = block["text"] as? String { text.append(value) }
      case "tool_use":
        guard let id = block["id"] as? String, let name = block["name"] as? String else {
          continue
        }
        toolCalls.append(
          HarnessToolCall(
            id: id,
            name: name,
            arguments: try HarnessJSON.value(block["input"] ?? [:])))
      default: continue
      }
    }
    let assistantContent = try rawContent.map(HarnessJSON.value)
    let continuationMessages =
      priorMessages + [
        .object(["role": .string("assistant"), "content": .array(assistantContent)])
      ]
    return HarnessBackendResponse(
      providerContinuation: .object(["messages": .array(continuationMessages)]),
      text: text.joined(separator: "\n"),
      toolCalls: toolCalls,
      usage: HarnessTokenUsage.parse(object["usage"]))
  }

  private func requestMessages(for request: HarnessBackendRequest) throws -> [JSONValue] {
    switch request.input {
    case .conversation(let messages):
      return messages.map {
        .object(["role": .string($0.role.rawValue), "content": .string($0.content)])
      }
    case .toolResults(let results):
      guard case .object(let continuation) = request.providerContinuation,
        case .array(var messages) = continuation["messages"]
      else {
        throw HarnessError.malformedProviderResponse(
          "Anthropic tool continuation is missing its assistant message.")
      }
      messages.append(
        .object([
          "role": .string("user"),
          "content": .array(
            results.map {
              .object([
                "type": .string("tool_result"),
                "tool_use_id": .string($0.callID),
                "content": .string($0.output),
              ])
            }),
        ]))
      return messages
    }
  }
}

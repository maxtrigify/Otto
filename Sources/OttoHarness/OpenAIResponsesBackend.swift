import Foundation
import OttoTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OpenAIResponsesBackend: HarnessModelBackend {
  public let providerID: String
  private let providerDisplayName: String
  private let apiKey: String
  private let endpoint: URL
  private let session: URLSession

  public init(
    apiKey: String,
    providerID: String = "openai",
    providerDisplayName: String = "OpenAI",
    endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.providerID = providerID
    self.providerDisplayName = providerDisplayName
    self.endpoint = endpoint
    self.session = session
  }

  public func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse {
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try requestBody(for: request)
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let message =
        ((object?["error"] as? [String: Any])?["message"] as? String)
        ?? String(decoding: data.prefix(2_000), as: UTF8.self)
      throw HarnessError.providerRequestFailed("\(providerDisplayName) request failed: \(message)")
    }
    return try parseResponse(data)
  }

  public func requestBody(for request: HarnessBackendRequest) throws -> Data {
    var input: [[String: Any]] = [
      ["role": "system", "content": request.systemInstructions]
    ]
    switch request.input {
    case .conversation(let messages):
      input += messages.map { ["role": $0.role.rawValue, "content": $0.content] }
    case .toolResults(let results):
      input += results.map {
        ["type": "function_call_output", "call_id": $0.callID, "output": $0.output]
      }
    }

    var body: [String: Any] = [
      "model": request.modelID,
      "input": input,
      // Otto persists the canonical conversation. Provider storage is used only for continuation
      // within one tool-call round and for migration from legacy response identifiers.
      "store": true,
    ]
    if case .string(let previousResponseID) = request.providerContinuation {
      body["previous_response_id"] = previousResponseID
    }
    if let reasoningEffort = request.reasoningEffort {
      body["reasoning"] = ["effort": reasoningEffort]
    }
    if !request.tools.isEmpty {
      let names = HarnessToolNaming.safeNames(request.tools)
      body["tools"] = try request.tools.compactMap { tool -> [String: Any]? in
        guard let exposedName = names.first(where: { $0.value == tool.name })?.key else {
          return nil
        }
        return [
          "type": "function",
          "name": exposedName,
          "description": String(tool.description.prefix(1_024)),
          "parameters": try jsonObject(tool.inputSchema),
          "strict": false,
        ]
      }
    }
    return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
  }

  public func parseResponse(_ data: Data) throws -> HarnessBackendResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let responseID = object["id"] as? String
    else { throw HarnessError.malformedProviderResponse("OpenAI returned malformed JSON.") }
    var texts: [String] = []
    var calls: [HarnessToolCall] = []
    for item in object["output"] as? [[String: Any]] ?? [] {
      switch item["type"] as? String {
      case "message":
        for content in item["content"] as? [[String: Any]] ?? []
        where content["type"] as? String == "output_text" {
          if let text = content["text"] as? String { texts.append(text) }
        }
      case "function_call":
        guard let callID = item["call_id"] as? String,
          let exposedName = item["name"] as? String
        else { continue }
        let arguments = (item["arguments"] as? String).flatMap(jsonValue) ?? .object([:])
        calls.append(HarnessToolCall(id: callID, name: exposedName, arguments: arguments))
      default: continue
      }
    }
    return HarnessBackendResponse(
      providerContinuation: .string(responseID),
      text: texts.joined(separator: "\n"),
      toolCalls: calls)
  }

  private func jsonObject(_ value: JSONValue) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }

  private func jsonValue(_ string: String) -> JSONValue? {
    try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
  }
}

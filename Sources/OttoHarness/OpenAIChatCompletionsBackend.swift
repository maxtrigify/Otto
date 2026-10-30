import Foundation
import OttoTools

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Backend for providers implementing the OpenAI Chat Completions message and tool-call shape.
/// Otto uses this for Moonshot/Kimi; provider-specific endpoints and names are explicit.
public struct OpenAIChatCompletionsBackend: HarnessModelBackend {
  public let providerID: String
  private let providerDisplayName: String
  private let apiKey: String
  private let endpoint: URL
  private let session: URLSession

  public init(
    apiKey: String,
    providerID: String,
    providerDisplayName: String,
    endpoint: URL,
    session: URLSession = .shared
  ) {
    self.apiKey = apiKey
    self.providerID = providerID
    self.providerDisplayName = providerDisplayName
    self.endpoint = endpoint
    self.session = session
  }

  public func complete(_ request: HarnessBackendRequest) async throws -> HarnessBackendResponse {
    let messages = try requestMessages(for: request)
    var urlRequest = URLRequest(url: endpoint)
    urlRequest.httpMethod = "POST"
    if !apiKey.isEmpty {
      urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpBody = try requestBody(for: request, messages: messages)
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      let message =
        ((object?["error"] as? [String: Any])?["message"] as? String)
        ?? String(decoding: data.prefix(2_000), as: UTF8.self)
      // A session keeps the model it was started with, which a local server may since have
      // dropped or renamed; say how to switch rather than leave only the server's wording.
      let hint =
        providerID == "local"
          && [400, 401, 403, 404].contains((response as? HTTPURLResponse)?.statusCode ?? 0)
          && message.lowercased().contains("model")
        ? " Pick another model from the model menu under the message box, or fetch the server's models in Settings → Models."
        : ""
      throw HarnessError.providerRequestFailed(
        "\(providerDisplayName) request failed: \(message)\(hint)")
    }
    return try parseResponse(data, priorMessages: messages)
  }

  func requestBody(for request: HarnessBackendRequest, messages: [JSONValue]? = nil) throws -> Data
  {
    let messages = try messages ?? requestMessages(for: request)
    var body: [String: JSONValue] = [
      "model": .string(request.modelID),
      "messages": .array(messages),
    ]
    if !request.tools.isEmpty {
      let names = HarnessToolNaming.safeNames(request.tools)
      body["tools"] = .array(
        request.tools.compactMap { tool in
          guard let name = names.first(where: { $0.value == tool.name })?.key else { return nil }
          return .object([
            "type": .string("function"),
            "function": .object([
              "name": .string(name),
              "description": .string(String(tool.description.prefix(1_024))),
              "parameters": tool.inputSchema,
            ]),
          ])
        })
    }
    return try HarnessJSON.stableEncoder.encode(JSONValue.object(body))
  }

  func parseResponse(_ data: Data, priorMessages: [JSONValue]) throws -> HarnessBackendResponse {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choice = (object["choices"] as? [[String: Any]])?.first,
      let message = choice["message"] as? [String: Any]
    else {
      throw HarnessError.malformedProviderResponse(
        "\(providerDisplayName) returned malformed JSON.")
    }
    var calls: [HarnessToolCall] = []
    for item in message["tool_calls"] as? [[String: Any]] ?? [] {
      guard let id = item["id"] as? String,
        let function = item["function"] as? [String: Any],
        let name = function["name"] as? String
      else { continue }
      let arguments =
        (function["arguments"] as? String).flatMap {
          try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        } ?? .object([:])
      calls.append(HarnessToolCall(id: id, name: name, arguments: arguments))
    }
    let content = message["content"] as? String ?? ""
    let continuationMessages = priorMessages + [try HarnessJSON.value(message)]
    return HarnessBackendResponse(
      providerContinuation: .object(["messages": .array(continuationMessages)]),
      text: content,
      toolCalls: calls)
  }

  private func requestMessages(for request: HarnessBackendRequest) throws -> [JSONValue] {
    switch request.input {
    case .conversation(let messages):
      return [
        .object(["role": .string("system"), "content": .string(request.systemInstructions)])
      ]
        + messages.map {
          .object(["role": .string($0.role.rawValue), "content": .string($0.content)])
        }
    case .toolResults(let results):
      guard case .object(let continuation) = request.providerContinuation,
        case .array(var messages) = continuation["messages"]
      else {
        throw HarnessError.malformedProviderResponse(
          "\(providerDisplayName) tool continuation is missing its assistant message.")
      }
      messages += results.map {
        .object([
          "role": .string("tool"),
          "tool_call_id": .string($0.callID),
          "content": .string($0.output),
        ])
      }
      return messages
    }
  }
}

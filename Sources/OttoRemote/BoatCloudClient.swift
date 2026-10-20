import Foundation

public struct BoatSandbox: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let state: String
  public let archiveAfter: String?
  public var canPrompt: Bool { ["ready", "idle", "running"].contains(state) }
}

public struct BoatLimits: Codable, Sendable {
  public let canStart: Bool
  public let accessTier: String?
  public let activeSandboxes: Int
  public let maxActiveSandboxes: Int
  public let creditBalanceHours: Double?
}

public struct BoatCreateIntent: Codable, Equatable, Sendable {
  public let key: String
  public let createdAt: Date
  public let noEnv: Bool
  public init(noEnv: Bool) {
    key = UUID().uuidString
    createdAt = Date()
    self.noEnv = noEnv
  }
}

public struct BoatPromptReceipt: Decodable, Sendable {
  public let promptId: String
  public let conversationId: String?
}

public struct BoatEvent: Decodable, Identifiable, Sendable {
  public let id: String?
  public let type: String
  public let taskId: String?
  public let conversationId: String?
  public let timestamp: Double?
  public let data: Payload?
  public struct Payload: Decodable, Sendable {
    public let content: String?
    public let status: String?
    public let isStreaming: Bool?
    private enum CodingKeys: String, CodingKey {
      case content, status
      case isStreaming = "is_streaming"
    }
  }
}

public struct BoatEventPage: Decodable, Sendable {
  public let events: [BoatEvent]
  public let pageInfo: PageInfo
  public struct PageInfo: Decodable, Sendable {
    public let nextCursor: String?
    public let hasMore: Bool
  }
}

public enum BoatCloudError: Error, LocalizedError, Equatable {
  case notConnected, invalidResponse, invalidIdentifier, trialOnly, capacity, expiredIntent
  case request(Int, String)
  public var errorDescription: String? {
    switch self {
    case .notConnected: "Connect your Boat account in Cloud settings."
    case .invalidResponse: "Boat returned an unexpected response. Refresh before continuing."
    case .invalidIdentifier: "The cloud machine identifier is invalid."
    case .trialOnly: "Trial-only mode requires an active Boat trial. No machine was started."
    case .capacity: "Boat cannot start a machine with your current account limits."
    case .expiredIntent:
      "This creation attempt is over 23 hours old. Check the Boat dashboard before starting another machine."
    case .request(let status, _):
      switch status {
      case 401: "Boat authentication failed. Reconnect your account."
      case 402: "Boat requires billing or additional credit. No payment was made by Otto."
      case 403: "Boat denied this operation. Check your account access."
      case 409: "Boat cannot perform this operation yet. Check machine state and agent setup."
      case 429: "Boat's usage or request limit was reached. Try again later."
      default: "Boat request failed (HTTP \(status)). Refresh to check its outcome."
      }
    }
  }
}

/// Fixed origin, ephemeral transport, no redirects or automatic mutation retries.
public struct BoatCloudClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
  private let token: String
  private let transport: Transport
  public init(token: String, transport: @escaping Transport = Self.liveTransport) {
    self.token = token
    self.transport = transport
  }

  public func limits() async throws -> BoatLimits { try await request("limits") }

  public func sandbox(_ id: String) async throws -> BoatSandbox {
    struct Response: Decodable { let sandbox: BoatSandbox }
    let response: Response = try await request("sandboxes/\(try identifier(id))")
    return response.sandbox
  }

  /// Fixed key order, so a retried request carries exactly the bytes of the original.
  private static var stableEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public func create(_ intent: BoatCreateIntent, trialOnly: Bool) async throws -> BoatSandbox {
    guard Date().timeIntervalSince(intent.createdAt) < 23 * 3600 else {
      throw BoatCloudError.expiredIntent
    }
    try await checkStart(trialOnly: trialOnly)
    struct Body: Encodable {
      let type = "small"
      let ttlSeconds = 3600
      let noEnv: Bool
    }
    struct Response: Decodable { let sandbox: BoatSandbox }
    let response: Response = try await request(
      "sandboxes", method: "POST", body: Self.stableEncoder.encode(Body(noEnv: intent.noEnv)),
      idempotencyKey: intent.key)
    return response.sandbox
  }

  public func resume(_ id: String, trialOnly: Bool) async throws {
    try await checkStart(trialOnly: trialOnly)
    let _: Envelope = try await request(
      "sandboxes/\(try identifier(id))/resume", method: "POST",
      body: Data("{\"ttlSeconds\":3600}".utf8))
  }

  public func stop(_ id: String) async throws {
    let _: Envelope = try await request("sandboxes/\(try identifier(id))/stop", method: "POST")
  }

  public func prompt(
    _ id: String, text: String, provider: String,
    conversation: String?
  ) async throws -> BoatPromptReceipt {
    struct Body: Encodable {
      let prompt: String
      let provider: String
      let conversationId: String?
      let new: Bool
      let fast = false
    }
    guard ["codex", "claude-code"].contains(provider),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw BoatCloudError.invalidResponse
    }
    return try await request(
      "sandboxes/\(try identifier(id))/prompt", method: "POST",
      body: Self.stableEncoder.encode(
        Body(
          prompt: text, provider: provider,
          conversationId: conversation, new: conversation == nil)))
  }

  public func events(_ id: String, conversation: String, cursor: String?) async throws
    -> BoatEventPage
  {
    var query = [
      URLQueryItem(name: "conversation", value: conversation),
      URLQueryItem(name: "sort", value: "asc"), URLQueryItem(name: "limit", value: "100"),
    ]
    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
    return try await request("sandboxes/\(try identifier(id))/events", query: query)
  }

  public func promptStatus(_ id: String, promptID: String) async throws -> String {
    guard !promptID.isEmpty,
      promptID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
    else {
      throw BoatCloudError.invalidIdentifier
    }
    struct Run: Decodable { let status: String }
    struct Response: Decodable { let promptRun: Run }
    let response: Response = try await request(
      "sandboxes/\(try identifier(id))/prompts/\(promptID)")
    return response.promptRun.status
  }

  private func checkStart(trialOnly: Bool) async throws {
    let limits = try await limits()
    if trialOnly && limits.accessTier != "trial" { throw BoatCloudError.trialOnly }
    guard limits.canStart, limits.activeSandboxes < limits.maxActiveSandboxes else {
      throw BoatCloudError.capacity
    }
  }

  private func identifier(_ value: String) throws -> String {
    guard
      value.range(of: "^bx_[23456789abcdefghjkmnpqrstuvwxyz]{8}$", options: .regularExpression)
        != nil
    else {
      throw BoatCloudError.invalidIdentifier
    }
    return value
  }

  private struct Envelope: Decodable {
    let ok: Bool
    let code: String?
  }
  private func request<T: Decodable>(
    _ path: String, method: String = "GET", body: Data? = nil,
    query: [URLQueryItem] = [], idempotencyKey: String? = nil
  ) async throws -> T {
    guard !token.isEmpty else { throw BoatCloudError.notConnected }
    var url = URLComponents(string: "https://boat.dev/api/v1/\(path)")!
    url.queryItems = query.isEmpty ? nil : query
    var request = URLRequest(url: url.url!)
    request.httpMethod = method
    request.timeoutInterval = 45
    request.httpBody = body
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("personal", forHTTPHeaderField: "X-Boat-Org")
    if let idempotencyKey {
      request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
    }
    let (data, status) = try await transport(request)
    guard data.count < 8_388_608 else { throw BoatCloudError.invalidResponse }
    let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
    guard (200..<300).contains(status), envelope?.ok == true else {
      throw BoatCloudError.request(status, envelope?.code ?? "unknown")
    }
    do { return try JSONDecoder().decode(T.self, from: data) } catch {
      throw BoatCloudError.invalidResponse
    }
  }

  public static func liveTransport(_ request: URLRequest) async throws -> (Data, Int) {
    let session = URLSession(
      configuration: .ephemeral, delegate: BoatRedirectBlocker(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    // Newer SDKs already type this as HTTPURLResponse; widening first keeps both SDKs warning-free.
    guard let response = (response as URLResponse) as? HTTPURLResponse else {
      throw BoatCloudError.invalidResponse
    }
    return (data, response.statusCode)
  }
}

private final class BoatRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

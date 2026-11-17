import Foundation
import Network
import OttoTools

/// Answers the Model Context Protocol requests a local assistant makes for Otto's tools.
///
/// Kept apart from the network code so the protocol can be tested without a socket.
public struct LocalToolProtocol: Sendable {
  public typealias Call =
    @Sendable (_ name: String, _ arguments: JSONValue) async -> (
      text: String, isError: Bool
    )

  public struct Reply: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
      self.status = status
      self.body = body
    }
  }

  private let tools: [ToolDefinition]
  private let namesByWireName: [String: String]
  private let wireNames: [String: String]
  private let call: Call

  public init(tools: [ToolDefinition], call: @escaping Call) {
    self.tools = tools
    var wireNames: [String: String] = [:]
    var originals: [String: String] = [:]
    for tool in tools {
      let base = Self.wireName(tool.name)
      var candidate = base
      var suffix = 2
      while originals[candidate] != nil {
        candidate = String(base.prefix(60)) + "_\(suffix)"
        suffix += 1
      }
      originals[candidate] = tool.name
      wireNames[tool.name] = candidate
    }
    self.wireNames = wireNames
    namesByWireName = originals
    self.call = call
  }

  public var toolNames: [String] { wireNames.values.sorted() }

  /// The protocol allows letters, digits, underscores and hyphens; Otto's names use dots.
  static func wireName(_ name: String) -> String {
    let mapped = name.map { character -> Character in
      character.isLetter || character.isNumber || character == "_" || character == "-"
        ? character : "_"
    }
    return String(String(mapped).prefix(64))
  }

  public func respond(to body: Data) async -> Reply {
    guard let request = try? JSONDecoder().decode(JSONValue.self, from: body),
      let object = request.objectValue,
      let method = object["method"]?.stringValue
    else {
      return reply(id: .null, error: -32700, message: "Parse error")
    }
    // A request without an id is a notification: acknowledged, never answered.
    guard let id = object["id"], id != .null else { return Reply(status: 202) }
    let parameters = object["params"]?.objectValue ?? [:]
    switch method {
    case "initialize":
      return reply(
        id: id,
        result: .object([
          "protocolVersion": parameters["protocolVersion"] ?? .string("2025-06-18"),
          "capabilities": .object(["tools": .object([:])]),
          "serverInfo": .object(["name": .string("otto-voice"), "version": .string("1")]),
        ]))
    case "ping":
      return reply(id: id, result: .object([:]))
    case "tools/list":
      let listed = tools.map { tool in
        JSONValue.object([
          "name": .string(wireNames[tool.name] ?? tool.name),
          "description": .string(tool.description),
          "inputSchema": tool.inputSchema,
        ])
      }
      return reply(id: id, result: .object(["tools": .array(listed)]))
    case "tools/call":
      guard let wire = parameters["name"]?.stringValue, let name = namesByWireName[wire] else {
        return reply(id: id, error: -32602, message: "Unknown tool")
      }
      let outcome = await call(name, parameters["arguments"] ?? .object([:]))
      return reply(
        id: id,
        result: .object([
          "content": .array([.object(["type": .string("text"), "text": .string(outcome.text)])]),
          "isError": .bool(outcome.isError),
        ]))
    default:
      return reply(id: id, error: -32601, message: "Method not found")
    }
  }

  private func reply(id: JSONValue, result: JSONValue) -> Reply {
    encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
  }

  private func reply(id: JSONValue, error code: Int, message: String) -> Reply {
    encode(
      .object([
        "jsonrpc": .string("2.0"), "id": id,
        "error": .object(["code": .number(Double(code)), "message": .string(message)]),
      ]))
  }

  private func encode(_ value: JSONValue) -> Reply {
    Reply(status: 200, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
  }
}

public enum LocalToolBridgeError: Error, LocalizedError, Sendable {
  case couldNotListen(String)

  public var errorDescription: String? {
    switch self {
    case .couldNotListen(let detail): "Otto could not open its local tool connection: \(detail)"
    }
  }
}

/// Serves Otto's tools to the local assistant over a loopback-only HTTP connection.
///
/// The assistant runs as a separate process and can only reach tools through a protocol it
/// already speaks. Requests carry a secret made for this one conversation, and the listener is
/// bound to this Mac alone, so nothing else on the network can call a tool through it.
public final class LocalToolBridge: @unchecked Sendable {
  public let token: String
  public private(set) var port: Int = 0

  private let listener: NWListener
  private let service: LocalToolProtocol
  private let queue = DispatchQueue(label: "io.openotto.voice.tool-bridge")

  public init(tools: [ToolDefinition], call: @escaping LocalToolProtocol.Call) throws {
    service = LocalToolProtocol(tools: tools, call: call)
    token = (0..<4).map { _ in String(UInt64.random(in: 0...UInt64.max), radix: 16) }.joined()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.allowLocalEndpointReuse = true
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw LocalToolBridgeError.couldNotListen(error.localizedDescription)
    }
  }

  public func start() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let resumed = Resumed()
      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.port = Int(self?.listener.port?.rawValue ?? 0)
          if resumed.claim() { continuation.resume() }
        case .failed(let error):
          if resumed.claim() {
            continuation.resume(
              throwing: LocalToolBridgeError.couldNotListen(error.localizedDescription))
          }
        default: break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        guard let self else { return }
        connection.start(queue: self.queue)
        self.receive(on: connection, buffered: Data())
      }
      listener.start(queue: queue)
    }
  }

  public func stop() {
    listener.cancel()
  }

  /// The names the tools carry on the wire, for harnesses that must approve each one by name.
  public var toolNames: [String] { service.toolNames }

  /// The address the assistant is told to connect to.
  public var address: String { "http://127.0.0.1:\(port)/mcp" }

  private func receive(on connection: NWConnection, buffered: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffered
      if let data { buffer.append(data) }
      if let request = HTTPRequest(buffer) {
        Task {
          let (status, body) = await self.answer(request)
          self.send(status: status, body: body, on: connection)
        }
        return
      }
      if isComplete || error != nil || buffer.count > 8 << 20 {
        connection.cancel()
        return
      }
      self.receive(on: connection, buffered: buffer)
    }
  }

  private func answer(_ request: HTTPRequest) async -> (Int, Data) {
    guard request.headers["authorization"] == "Bearer \(token)" else { return (401, Data()) }
    // The protocol's optional server-to-client stream is not offered.
    guard request.method == "POST" else { return (405, Data()) }
    let reply = await service.respond(to: request.body)
    return (reply.status, reply.body)
  }

  private func send(status: Int, body: Data, on connection: NWConnection) {
    let reason = [200: "OK", 202: "Accepted", 401: "Unauthorized", 405: "Method Not Allowed"]
    var head = "HTTP/1.1 \(status) \(reason[status] ?? "OK")\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n\r\n"
    var response = Data(head.utf8)
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
      lock.withLock {
        if done { return false }
        done = true
        return true
      }
    }
  }
}

/// One complete HTTP request, or nil while more bytes are still to arrive.
struct HTTPRequest: Equatable {
  var method: String
  var headers: [String: String]
  var body: Data

  init?(_ data: Data) {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    lines.removeFirst()
    method = String(requestLine.split(separator: " ").first ?? "")
    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[line.startIndex..<colon].lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    self.headers = headers
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerEnd.upperBound
    guard data.endIndex - bodyStart >= length else { return nil }
    body = data.subdata(in: bodyStart..<(bodyStart + length))
  }
}

extension JSONValue {
  /// The members of a JSON object, or nil for any other kind of value.
  var objectValue: [String: JSONValue]? {
    guard case .object(let object) = self else { return nil }
    return object
  }
}

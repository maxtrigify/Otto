#if canImport(AppKit)
  import AppKit
#endif
#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation
#if canImport(Network)
  import Network
#endif
#if canImport(Security)
  import Security
#endif

/// Native installed-app OAuth. Google disallows password entry in embedded WKWebViews.
/// The listener binds only to IPv4 loopback and lives for a single PKCE transaction.
@MainActor
final class GoogleLoopbackSignIn {
  struct Authorization: Sendable {
    let code: String
    let verifier: String
    let redirectURI: String
  }
  private var listener: NWListener?
  private var ready: CheckedContinuation<UInt16, Error>?
  private var response: CheckedContinuation<Authorization, Error>?
  private var timeout: Task<Void, Never>?
  private var state = ""
  private var verifier = ""
  private var redirectURI = ""
  private var connections: [UUID: NWConnection] = [:]
  private var buffers: [UUID: Data] = [:]
  private var connectionTimers: [UUID: Task<Void, Never>] = [:]
  private var completed = false

  func authorize(clientID: String, scopes: Set<String>) async throws -> Authorization {
    state = try Self.random()
    verifier = try Self.random()
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(180))
      guard !Task.isCancelled else { return }
      self?.cancel()
    }
    let port = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        ready = continuation
        listener.stateUpdateHandler = { [weak self] update in
          Task { @MainActor in
            guard let self else { return }
            switch update {
            case .ready:
              guard let port = listener.port?.rawValue else {
                self.cancel()
                return
              }
              self.ready?.resume(returning: port)
              self.ready = nil
            case .failed: self.cancel()
            default: break
            }
          }
        }
        listener.newConnectionHandler = { [weak self] connection in
          Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "io.openotto.google-oauth"))
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
    redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
    let url = Self.authorizationURL(
      clientID: clientID, redirectURI: redirectURI, scopes: scopes, state: state,
      challenge: Self.challenge(verifier))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !completed else {
          continuation.resume(throwing: AppConnectionError.cancelled)
          return
        }
        response = continuation
        if !NSWorkspace.shared.open(url) { cancel() }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }

  /// `include_granted_scopes` makes the new grant cover the scopes the account already gave
  /// Otto, so granting calendar access later does not drop Gmail sending, and vice versa.
  nonisolated static func authorizationURL(
    clientID: String, redirectURI: String, scopes: Set<String>, state: String, challenge: String
  ) -> URL {
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scopes.sorted().joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "include_granted_scopes", value: "true"),
      URLQueryItem(name: "prompt", value: "consent select_account"),
    ]
    return components.url!
  }

  func cancel() { finish(.failure(AppConnectionError.cancelled)) }
  private func accept(_ connection: NWConnection) {
    guard !completed, connections.count < 16 else {
      connection.cancel()
      return
    }
    let id = UUID()
    connections[id] = connection
    buffers[id] = Data()
    connectionTimers[id] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.close(id)
    }
    connection.start(queue: DispatchQueue(label: "io.openotto.google-callback"))
    receive(id, connection)
  }
  private func receive(_ id: UUID, _ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
      [weak self] data, _, complete, error in
      Task { @MainActor in
        guard let self, self.connections[id] != nil else { return }
        if let data { self.buffers[id, default: Data()].append(data) }
        guard let buffer = self.buffers[id], buffer.count <= 16_384 else {
          self.close(id)
          return
        }
        if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
          self.handle(text, id: id, connection: connection)
        } else if complete || error != nil {
          self.close(id)
        } else {
          self.receive(id, connection)
        }
      }
    }
  }
  private func handle(_ text: String, id: UUID, connection: NWConnection) {
    let firstLine = text.components(separatedBy: "\r\n").first ?? ""
    let fields = firstLine.split(separator: " ")
    let result: Result<Authorization, Error>
    do {
      guard fields.count == 3, fields[0] == "GET",
        let components = URLComponents(
          string: "\(redirectURI.components(separatedBy: "/oauth2callback")[0])\(fields[1])")
      else {
        throw AppConnectionError.invalidCallback
      }
      let code = try Self.validateCallback(components, expectedState: state)
      result = .success(Authorization(code: code, verifier: verifier, redirectURI: redirectURI))
    } catch AppConnectionError.cancelled {
      result = .failure(AppConnectionError.cancelled)
    } catch {
      reply(
        connection, status: "400 Bad Request", body: "This sign-in response could not be verified.")
      detach(id)
      return  // Unsolicited/invalid traffic must not consume the real OAuth transaction.
    }
    reply(
      connection, status: "200 OK",
      body: "Return to Otto to finish connecting Gmail. You can close this tab.")
    detach(id)
    finish(result)
  }
  private func reply(_ connection: NWConnection, status: String, body: String) {
    let message =
      "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
    connection.send(
      content: Data(message.utf8), completion: .contentProcessed { _ in connection.cancel() })
  }
  private func detach(_ id: UUID) {
    connections[id] = nil
    buffers[id] = nil
    connectionTimers.removeValue(forKey: id)?.cancel()
  }
  private func close(_ id: UUID) {
    connections[id]?.cancel()
    detach(id)
  }
  private func finish(_ result: Result<Authorization, Error>) {
    guard !completed else { return }
    completed = true
    timeout?.cancel()
    listener?.cancel()
    listener = nil
    for id in Array(connections.keys) { close(id) }
    ready?.resume(throwing: AppConnectionError.cancelled)
    ready = nil
    response?.resume(with: result)
    response = nil
    state = ""
    verifier = ""
  }
  static func validateCallback(_ components: URLComponents, expectedState: String) throws -> String
  {
    guard components.path == "/oauth2callback", components.fragment == nil,
      let items = components.queryItems,
      items.filter({ $0.name == "state" }).count == 1,
      items.first(where: { $0.name == "state" })?.value == expectedState
    else {
      throw AppConnectionError.invalidCallback
    }
    if items.contains(where: { $0.name == "error" }) { throw AppConnectionError.cancelled }
    guard items.filter({ $0.name == "code" }).count == 1,
      let code = items.first(where: { $0.name == "code" })?.value,
      !code.isEmpty, code.utf8.count < 4096
    else { throw AppConnectionError.invalidCallback }
    return code
  }
  static func challenge(_ verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
  }
  private static func random() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw AppConnectionError.invalidCallback
    }
    return Data(bytes).base64URL
  }
}

extension Data {
  var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  init?(base64URL: String) {
    let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
  }
}

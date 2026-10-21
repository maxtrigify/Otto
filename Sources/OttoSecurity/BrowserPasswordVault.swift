import Foundation

/// The personal browser's vault is separate from bot account grants. All builds use Keychain.
package actor BrowserPasswordVault {
  package static let shared = BrowserPasswordVault()
  package struct Login: Codable, Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
  {
    package var origin: String
    package var username: String
    package var password: String
    package init(origin: String, username: String, password: String) {
      self.origin = origin
      self.username = username
      self.password = password
    }
    package var description: String { "<browser login redacted>" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: ["login": "<redacted>"]) }
  }
  package struct Summary: Sendable, Equatable, Identifiable {
    package var origin: String
    package var username: String
    package var id: String { origin + "\n" + username }
  }
  package enum Failure: Error { case invalid, busy }
  private let storage: any SecretStore
  private var busy = false
  private let key = "browser-logins-v1"
  package init(
    storage: any SecretStore = KeychainSecretStore(service: "io.openotto.browser-passwords")
  ) {
    self.storage = storage
  }
  package static func origin(for url: URL?) -> String? {
    guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
      !host.isEmpty, url.user == nil, url.password == nil
    else { return nil }
    var parts = URLComponents()
    parts.scheme = "https"
    parts.host = host
    parts.port = url.port == 443 ? nil : url.port
    return parts.string
  }
  private func read() async throws -> [Login] {
    guard let data = try await storage.value(for: key)?.data(using: .utf8) else { return [] }
    return try JSONDecoder().decode([Login].self, from: data)
  }
  package func summaries() async throws -> [Summary] {
    try await read().map { Summary(origin: $0.origin, username: $0.username) }
      .sorted { ($0.origin, $0.username) < ($1.origin, $1.username) }
  }
  package func login(origin: String, username: String) async throws -> Login? {
    guard Self.origin(for: URL(string: origin)) == origin else { throw Failure.invalid }
    return try await read().first { $0.origin == origin && $0.username == username }
  }
  package func save(_ login: Login) async throws {
    guard Self.origin(for: URL(string: login.origin)) == login.origin,
      !login.password.isEmpty, login.password.utf8.count <= 16_384,
      login.username.utf8.count <= 4096
    else { throw Failure.invalid }
    guard !busy else { throw Failure.busy }
    busy = true
    defer { busy = false }
    var logins = try await read()
    logins.removeAll { $0.origin == login.origin && $0.username == login.username }
    logins.append(login)
    try await storage.set(String(decoding: JSONEncoder().encode(logins), as: UTF8.self), for: key)
  }
  package func delete(origin: String, username: String) async throws {
    guard !busy else { throw Failure.busy }
    busy = true
    defer { busy = false }
    var logins = try await read()
    logins.removeAll { $0.origin == origin && $0.username == username }
    if logins.isEmpty {
      try await storage.delete(key)
    } else {
      try await storage.set(String(decoding: JSONEncoder().encode(logins), as: UTF8.self), for: key)
    }
  }
}

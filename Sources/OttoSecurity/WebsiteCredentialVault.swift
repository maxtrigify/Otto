import CryptoKit
import Foundation

/// Package-only executor storage; never registered as an agent tool or generic RPC API.
package actor WebsiteCredentialVault {
  package struct Credential: Codable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
  {
    package var signature: String
    package var username: String
    package var password: String
    package var successURL: String
    package init(signature: String, username: String, password: String, successURL: String = "") {
      self.signature = signature
      self.username = username
      self.password = password
      self.successURL = successURL
    }
    package var description: String { "<website credential redacted>" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: ["credential": "<redacted>"]) }
  }
  private let storage: any SecretStore
  package init(
    storage: any SecretStore = makeKeychainSecretStore(service: OttoSecretService.websitePasswords)
  ) {
    self.storage = storage
  }
  private func key(owner: UUID, workspace: UUID, account: UUID, origin: String) -> String {
    SHA256.hash(
      data: Data(
        [owner.uuidString, workspace.uuidString, account.uuidString, origin].joined(separator: "\n")
          .utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
  }
  package func save(
    _ credential: Credential, owner: UUID, workspace: UUID, account: UUID, origin: String
  ) async throws {
    guard !credential.password.isEmpty, credential.password.utf8.count <= 16_384,
      credential.username.utf8.count <= 16_384, credential.signature.utf8.count <= 4096,
      credential.successURL.utf8.count <= 4096
    else { throw SecretStoreError.invalidEncoding }
    let encoded = try JSONEncoder().encode(credential).base64EncodedString()
    try await storage.set(
      encoded, for: key(owner: owner, workspace: workspace, account: account, origin: origin))
  }
  package func load(owner: UUID, workspace: UUID, account: UUID, origin: String) async throws
    -> Credential?
  {
    guard
      let encoded = try await storage.value(
        for: key(owner: owner, workspace: workspace, account: account, origin: origin))
    else { return nil }
    guard encoded.utf8.count <= 100_000, let data = Data(base64Encoded: encoded) else {
      throw SecretStoreError.invalidEncoding
    }
    return try JSONDecoder().decode(Credential.self, from: data)
  }
  package func delete(owner: UUID, workspace: UUID, account: UUID, origin: String) async throws {
    try await storage.delete(
      key(owner: owner, workspace: workspace, account: account, origin: origin))
  }
}

import CryptoKit
import Foundation
import OttoRPCContracts
import OttoSecurity
import Testing

@testable import OttoServices

@Suite("Private phone relay integration", .serialized)
@MainActor struct PrivatePhoneConnectionTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OTTO_PHONE_RELAY_TEST"] == "1"))
  func realRelayAuthenticatesSwiftHostAndEncryptedPhone() async throws {
    let connection = PrivatePhoneConnection(secrets: InMemorySecretStore())
    let identity = try await connection.installationIdentity()
    let scope = PrivatePhoneSessionLedger.Scope(
      installationID: identity.id, workspaceID: UUID(), bindingID: UUID(), jobID: UUID(),
      botID: UUID(), runID: UUID(), accountID: UUID(), origin: "https://example.test")
    var phoneTask: Task<Void, any Error>?
    var handled = 0
    try await connection.run(
      scope: scope,
      sendLink: { url in
        phoneTask = Task {
          let fragment = try #require(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment)
          var base = String(fragment.dropFirst(3)).replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(
              of: "_", with: "/")
          while base.count % 4 != 0 { base += "=" }
          struct Link: Decodable {
            var installationID: UUID
            var sessionID: UUID
            var expiresAt: Int64
            var hostPublicKey: Data
            var capability: Data
          }
          let data = try #require(Data(base64Encoded: base))
          #expect(data.count == 137)
          func uuid(_ start: Int) throws -> UUID {
            let h = data[start..<start + 16].map { String(format: "%02x", $0) }.joined()
            let a = Array(h)
            let pieces: [String] = [
              String(a[0..<8]), String(a[8..<12]), String(a[12..<16]), String(a[16..<20]),
              String(a[20..<32]),
            ]
            guard let result = UUID(uuidString: pieces.joined(separator: "-")) else {
              Issue.record("Link contains an invalid UUID")
              throw CancellationError()
            }
            return result
          }
          let link = Link(
            installationID: try uuid(0), sessionID: try uuid(16),
            expiresAt: Int64(data[32..<40].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }),
            hostPublicKey: data[40..<105], capability: data[105..<137])
          let phone = P256.KeyAgreement.PrivateKey()
          let host = try P256.KeyAgreement.PublicKey(x963Representation: link.hostPublicKey)
          let endpoint = try #require(PrivatePhoneConnection.endpoint)
          var parts = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
          let origin = endpoint.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
          parts.scheme = endpoint.scheme == "https" ? "wss" : "ws"
          parts.path =
            "/v1/phone/\(link.installationID.uuidString.lowercased())/\(link.sessionID.uuidString.lowercased())"
          var request = URLRequest(url: try #require(parts.url))
          request.setValue(origin, forHTTPHeaderField: "Origin")
          let session = URLSession(configuration: .ephemeral)
          let socket = session.webSocketTask(with: request)
          defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
          }
          socket.resume()
          let c = PrivatePhoneEnvelope.Context(
            installationID: link.installationID, sessionID: link.sessionID, operationID: UUID(),
            direction: .phoneToHost, expiresAt: link.expiresAt)
          let plaintext = try JSONSerialization.data(withJSONObject: [
            "action": "claim", "capability": link.capability.base64EncodedString(),
          ])
          let wire = try PrivatePhoneEnvelope.seal(
            plaintext, context: c, recipient: host, sender: phone)
          struct Payload: Encodable {
            var publicKey: Data
            var envelope: PrivatePhoneEnvelope.Wire
          }
          try await socket.send(
            .string(
              String(
                decoding: JSONEncoder().encode(
                  Payload(publicKey: phone.publicKey.x963Representation, envelope: wire)),
                as: UTF8.self)))
          guard case .string(let response) = try await socket.receive() else {
            throw PrivatePhoneConnection.Failure.interrupted
          }
          let reply = try JSONDecoder().decode(
            PrivatePhoneEnvelope.Wire.self, from: Data(response.utf8))
          let expected = PrivatePhoneEnvelope.Context(
            installationID: c.installationID, sessionID: c.sessionID, operationID: c.operationID,
            direction: .hostToPhone, expiresAt: c.expiresAt)
          let view = try JSONDecoder().decode(
            PrivatePhoneView.self,
            from: PrivatePhoneEnvelope.open(
              reply, expected: expected, recipient: phone, sender: host))
          #expect(view.mode == "complete")
        }
      }, isValid: { true },
      handle: { command in
        #expect(command.action == "claim")
        handled += 1
        return PrivatePhoneView(
          mode: "complete", title: "Done", origin: "https://example.test",
          message: "Synthetic check")
      })
    try await phoneTask?.value
    #expect(handled == 1)
  }
}

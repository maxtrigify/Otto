import CryptoKit
import Foundation
import Testing

@testable import OttoSecurity

@Suite("Private phone authenticated envelopes")
struct PrivatePhoneEnvelopeTests {
  typealias Envelope = PrivatePhoneEnvelope
  func context() -> Envelope.Context {
    Envelope.Context(
      installationID: UUID(), sessionID: UUID(), operationID: UUID(),
      direction: .phoneToHost, expiresAt: Int64(Date.now.timeIntervalSince1970) + 300)
  }

  @Test func authenticatedRoundTrip() throws {
    let host = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let input = Data(UUID().uuidString.utf8)
    let context = context()
    let wire = try Envelope.seal(input, context: context, recipient: host.publicKey, sender: phone)
    let result = try Envelope.open(
      wire, expected: context, recipient: host, sender: phone.publicKey)
    #expect(result == input)
    #expect(throws: (any Error).self) {
      try Envelope.open(
        wire, expected: context, recipient: host,
        sender: P256.KeyAgreement.PrivateKey().publicKey)
    }
    #expect(throws: (any Error).self) {
      try Envelope.open(
        wire, expected: context, recipient: P256.KeyAgreement.PrivateKey(),
        sender: phone.publicKey)
    }
    #expect(throws: (any Error).self) {
      try Envelope.open(wire, expected: self.context(), recipient: host, sender: phone.publicKey)
    }
    #expect(throws: (any Error).self) {
      try Envelope.open(
        wire, expected: context, recipient: host, sender: phone.publicKey,
        now: Date(timeIntervalSince1970: Double(context.expiresAt)))
    }
  }

  @Test func tamperedAndOversize() throws {
    let host = P256.KeyAgreement.PrivateKey()
    let phone = P256.KeyAgreement.PrivateKey()
    let c = context()
    let wire = try Envelope.seal(Data([1]), context: c, recipient: host.publicKey, sender: phone)
    var ciphertext = wire.ciphertext
    ciphertext[ciphertext.startIndex] ^= 1
    let bad = Envelope.Wire(
      version: 1, context: c, encapsulatedKey: wire.encapsulatedKey,
      ciphertext: ciphertext)
    #expect(throws: (any Error).self) {
      try Envelope.open(bad, expected: c, recipient: host, sender: phone.publicKey)
    }
    #expect(throws: (any Error).self) {
      try Envelope.seal(
        Data(count: Envelope.maximumPlaintextBytes + 1), context: c,
        recipient: host.publicKey, sender: phone)
    }
  }

  /// Opt-in because standard Swift tests must not silently require a Node installation.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OTTO_PHONE_INTEROP_TEST"] == "1"))
  func webCryptoInteroperability() throws {
    let host = P256.KeyAgreement.PrivateKey()
    let c = context()
    let input = Data(UUID().uuidString.utf8)
    let encoder = JSONEncoder()
    let contextObject = try JSONSerialization.jsonObject(with: encoder.encode(c))
    let result = try node([
      "action": "seal", "context": contextObject,
      "plaintext": input.base64EncodedString(),
      "hostPublicKey": host.publicKey.x963Representation.base64EncodedString(),
    ])
    let wire = try JSONDecoder().decode(
      Envelope.Wire.self,
      from: JSONSerialization.data(withJSONObject: result["envelope"]!))
    let phone = try P256.KeyAgreement.PublicKey(
      x963Representation:
        Data(base64Encoded: result["publicKey"] as! String)!)
    let opened = try Envelope.open(wire, expected: c, recipient: host, sender: phone)
    // Compare digests so failure reporting never prints synthetic secret material.
    #expect(SHA256.hash(data: opened) == SHA256.hash(data: input))
    let responseContext = Envelope.Context(
      installationID: c.installationID,
      sessionID: c.sessionID, operationID: c.operationID, direction: .hostToPhone,
      expiresAt: c.expiresAt)
    let reply = try Envelope.seal(input, context: responseContext, recipient: phone, sender: host)
    let confirmation = try node([
      "action": "open", "privateKey": result["privateKey"]!,
      "hostPublicKey": host.publicKey.x963Representation.base64EncodedString(),
      "envelope": try JSONSerialization.jsonObject(with: encoder.encode(reply)),
    ])
    let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    #expect(confirmation["digest"] as? String == digest)
  }

  private func node(_ input: [String: Any]) throws -> [String: Any] {
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    // otto-swift freezes source inputs without node_modules. Explicitly select the
    // checked-out helper/dependency tree for this opt-in cross-language test.
    let root =
      ProcessInfo.processInfo.environment["OTTO_PHONE_SOURCE_ROOT"].map {
        URL(fileURLWithPath: $0)
      } ?? sourceRoot
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "node", root.appendingPathComponent("PrivateSignIn/test/interop.mjs").path,
    ]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    stdin.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: input))
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Envelope.Failure.invalidEnvelope }
    return try JSONSerialization.jsonObject(with: output) as! [String: Any]
  }
}

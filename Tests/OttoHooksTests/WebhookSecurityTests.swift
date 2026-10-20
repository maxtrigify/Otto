import Crypto
import Foundation
import Testing

@testable import OttoHooks

struct WebhookSecurityTests {
  @Test func verifiesRawBodyAndRejectsWrongKeyOrTruncation() throws {
    let body = Data(#"{"ok":true}"#.utf8)
    let secret = "correct horse battery staple"
    let signature = sign(body, secret: secret)
    try WebhookSignatureVerifier.verify(
      body: body, secret: secret, signatureHeader: signature, timestampHeader: nil)
    #expect(throws: WebhookRejection.invalidSignature) {
      try WebhookSignatureVerifier.verify(
        body: body, secret: "wrong", signatureHeader: signature, timestampHeader: nil)
    }
    #expect(throws: WebhookRejection.invalidSignature) {
      try WebhookSignatureVerifier.verify(
        body: body.dropLast(), secret: secret, signatureHeader: signature, timestampHeader: nil)
    }
  }

  @Test func rejectsReplayedTimestampAndOversizedBody() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let timestamp = "1"
    let body = Data("payload".utf8)
    let secret = "secret"
    let signature = sign(Data("\(timestamp).".utf8) + body, secret: secret)
    #expect(throws: WebhookRejection.replayedTimestamp) {
      try WebhookSignatureVerifier.verify(
        body: body, secret: secret, signatureHeader: signature, timestampHeader: timestamp, now: now
      )
    }
    #expect(throws: WebhookRejection.oversized) {
      try WebhookSignatureVerifier.verify(
        body: Data(repeating: 1, count: 65_537), secret: secret, signatureHeader: signature,
        timestampHeader: nil)
    }
  }

  @Test func idempotencyDedupesForOneHour() async throws {
    let admission = WebhookAdmission()
    let now = Date(timeIntervalSince1970: 100)
    try await admission.admit(route: "git", idempotencyKey: "delivery", now: now)
    await #expect(throws: WebhookRejection.duplicate) {
      try await admission.admit(
        route: "git", idempotencyKey: "delivery", now: now.addingTimeInterval(3_599))
    }
    try await admission.admit(
      route: "git", idempotencyKey: "delivery", now: now.addingTimeInterval(3_601))
  }

  @Test func nonLoopbackBindFailsClosed() throws {
    try WebhookConfiguration.validateLoopbackHost("127.0.0.1")
    #expect(throws: WebhookRejection.notFound) {
      try WebhookConfiguration.validateLoopbackHost("0.0.0.0")
    }
  }

  @Test func fallbackIdempotencyIsSlugBoundAndCanonicalizesJSON() {
    let first = WebhookConfiguration.idempotencyKey(
      slug: "alpha", headers: [:], body: Data(#"{"b":2,"a":1}"#.utf8))
    let reordered = WebhookConfiguration.idempotencyKey(
      slug: "alpha", headers: [:], body: Data(#"{"a":1,"b":2}"#.utf8))
    let otherRoute = WebhookConfiguration.idempotencyKey(
      slug: "beta", headers: [:], body: Data(#"{"a":1,"b":2}"#.utf8))
    #expect(first == reordered)
    #expect(first != otherRoute)
  }

  private func sign(_ body: Data, secret: String) -> String {
    HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
      .map { String(format: "%02x", $0) }.joined()
  }
}

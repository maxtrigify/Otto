import CryptoKit
import Foundation
import Testing

@testable import OttoSecurity

@Suite("Private phone request lifecycle")
struct PrivatePhoneSessionLedgerTests {
  typealias Ledger = PrivatePhoneSessionLedger
  func scope() -> Ledger.Scope {
    Ledger.Scope(
      installationID: UUID(), workspaceID: UUID(), bindingID: UUID(), jobID: UUID(),
      botID: UUID(), runID: UUID(), accountID: UUID(), origin: "https://example.com")
  }
  @Test func singleClaimAndAtMostOnceAcceptance() async throws {
    let ledger = Ledger()
    let scope = scope()
    let issued = try await ledger.issue(scope: scope)
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    try await ledger.claim(
      id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    await #expect(throws: (any Error).self) {
      try await ledger.claim(
        id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    }
    let op = UUID()
    try await ledger.accept(id: issued.id, operationID: op, browserPublicKey: key, scope: scope)
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(), browserPublicKey: key, scope: scope)
    }
    try await ledger.completedOperation(id: issued.id, operationID: op)
    await #expect(throws: (any Error).self) {
      try await ledger.accept(id: issued.id, operationID: op, browserPublicKey: key, scope: scope)
    }
    try await ledger.accept(id: issued.id, operationID: UUID(), browserPublicKey: key, scope: scope)
    await ledger.close(id: issued.id)
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(), browserPublicKey: key, scope: scope)
    }
  }
  @Test func wrongScopeKeyAndRevocation() async throws {
    let ledger = Ledger()
    let scope = scope()
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let issued = try await ledger.issue(scope: scope)
    await #expect(throws: (any Error).self) {
      try await ledger.claim(
        id: issued.id, capability: Data(count: 32), browserPublicKey: key, scope: scope)
    }
    try await ledger.claim(
      id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(), browserPublicKey: key, scope: self.scope())
    }
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(),
        browserPublicKey: P256.KeyAgreement.PrivateKey().publicKey.x963Representation, scope: scope)
    }
    await ledger.revoke(bindingID: scope.bindingID)
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(), browserPublicKey: key, scope: scope)
    }
    let restarted = Ledger()
    await #expect(throws: (any Error).self) {
      try await restarted.claim(
        id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    }
  }
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func read() -> Date { lock.withLock { date } }
    func advance() { lock.withLock { date = date.addingTimeInterval(301) } }
  }

  @Test func expiryCannotBeClaimedOrMutated() async throws {
    let clock = Clock()
    let scope = scope()
    let ledger = Ledger(now: { clock.read() })
    let issued = try await ledger.issue(scope: scope)
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    try await ledger.claim(
      id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    clock.advance()
    await #expect(throws: (any Error).self) {
      try await ledger.accept(
        id: issued.id, operationID: UUID(), browserPublicKey: key, scope: scope)
    }
    await #expect(throws: (any Error).self) {
      try await ledger.claim(
        id: issued.id, capability: issued.capability, browserPublicKey: key, scope: scope)
    }
  }

  @Test func replacementAndRedaction() async throws {
    let ledger = Ledger()
    let scope = scope()
    let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    let first = try await ledger.issue(scope: scope)
    _ = try await ledger.issue(scope: scope)
    await #expect(throws: (any Error).self) {
      try await ledger.claim(
        id: first.id, capability: first.capability, browserPublicKey: key, scope: scope)
    }
    var dumped = ""
    dump(first, to: &dumped)
    #expect(!dumped.contains(first.capability.base64EncodedString()))
    #expect(String(describing: first) == "<private sign-in capability redacted>")
  }
}

import Foundation
import Testing

@testable import OttoSecurity

@Suite("Account access broker")
struct AccountAccessBrokerTests {
  typealias Broker = AccountAccessBroker
  let origin = "https://example.com"

  @Test("Native input redacts string interpolation, debug output and reflection")
  func redactedInput() {
    let canary = "synthetic-reflection-canary"
    let input = Broker.SecretInput(canary)
    #expect(String(describing: input) == "<redacted>")
    #expect(String(reflecting: input) == "<redacted>")
    var output = ""
    dump(input, to: &output)
    #expect(!output.contains(canary))
  }

  func identity(botID: UUID = UUID(), runID: UUID = UUID(), deviceID: UUID = UUID())
    -> Broker.Identity
  {
    Broker.Identity(
      userID: UUID(), workspaceID: UUID(), botID: botID, runID: runID, deviceID: deviceID)
  }

  func account(_ broker: Broker, _ identity: Broker.Identity) async throws -> Broker.Account {
    try await broker.createAccount(
      userID: identity.userID, workspaceID: identity.workspaceID, origin: origin,
      bots: .selected([identity.botID]), actions: [.browser])
  }

  @Test("Selected bot grant survives restart and new runs, but never implies future bots")
  func persistentGrants() async throws {
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    let saved = try await account(broker, actor)
    let restarted = Broker(storage: storage)
    let nextRun = Broker.Identity(
      userID: actor.userID, workspaceID: actor.workspaceID, botID: actor.botID,
      runID: UUID(), deviceID: UUID())
    #expect(
      try await restarted.authorise(
        accountID: saved.id, identity: nextRun, origin: origin, action: .browser) == saved)
    let futureBot = Broker.Identity(
      userID: actor.userID, workspaceID: actor.workspaceID, botID: UUID(),
      runID: UUID(), deviceID: UUID())
    await #expect(throws: Broker.Failure.denied) {
      try await restarted.authorise(
        accountID: saved.id, identity: futureBot, origin: origin, action: .browser)
    }
    try await restarted.updateGrant(
      accountID: saved.id, userID: actor.userID, workspaceID: actor.workspaceID,
      bots: .allCurrentAndFuture, actions: [.browser])
    #expect(
      try await restarted.authorise(
        accountID: saved.id, identity: futureBot, origin: origin, action: .browser
      ).id == saved.id)
  }

  @Test("Owner, workspace, action and exact origin are independent boundaries")
  func permissionBoundaries() async throws {
    let broker = Broker(storage: InMemorySecretStore())
    let actor = identity()
    let saved = try await account(broker, actor)
    for other in [
      Broker.Identity(
        userID: UUID(), workspaceID: actor.workspaceID, botID: actor.botID,
        runID: actor.runID, deviceID: actor.deviceID),
      Broker.Identity(
        userID: actor.userID, workspaceID: UUID(), botID: actor.botID,
        runID: actor.runID, deviceID: actor.deviceID),
    ] {
      await #expect(throws: Broker.Failure.denied) {
        try await broker.authorise(
          accountID: saved.id, identity: other, origin: origin, action: .browser)
      }
    }
    for otherOrigin in [
      "http://example.com", "https://example.com.evil.test",
      "https://sub.example.com", "https://example.com:8443",
    ] {
      await #expect(throws: Broker.Failure.denied) {
        try await broker.authorise(
          accountID: saved.id, identity: actor, origin: otherOrigin, action: .browser)
      }
    }
    await #expect(throws: Broker.Failure.denied) {
      try await broker.authorise(accountID: saved.id, identity: actor, origin: origin, action: .api)
    }
    #expect(try await broker.accounts(userID: UUID(), workspaceID: actor.workspaceID).isEmpty)
  }

  @Test("Origins reject URL content and normalise HTTPS case/default port")
  func origins() async throws {
    let broker = Broker(storage: InMemorySecretStore())
    let actor = identity()
    for value in [
      "http://example.com", "https://user:password@example.com",
      "https://example.com/login", "https://example.com/?key=value",
      "https://example.com/#secret", "https://*.example.com", "https://example.com.",
      "file:///tmp/test", "https://example.com:0", "https://example.com:65536",
    ] {
      await #expect(throws: Broker.Failure.invalidOrigin) {
        try await broker.createAccount(
          userID: actor.userID, workspaceID: actor.workspaceID, origin: value,
          bots: .selected([actor.botID]), actions: [.browser])
      }
    }
    let saved = try await broker.createAccount(
      userID: actor.userID, workspaceID: actor.workspaceID, origin: "HTTPS://EXAMPLE.COM:443/",
      bots: .selected([actor.botID]), actions: [.browser])
    #expect(saved.origin == origin)
  }

  @Test("Secure input is single use and summaries cannot encode the credential")
  func intakeAndReplay() async throws {
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    let canary = "synthetic-test-canary-only"
    try await broker.submitInput(
      requestID: request.id, identity: actor, origin: origin, secret: .init(canary))
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: origin, secret: .init(canary))
    }
    let restarted = Broker(storage: storage)
    let summaries = try await restarted.accounts(
      userID: actor.userID, workspaceID: actor.workspaceID)
    #expect(summaries.first?.hasCredential == true)
    let encoded = String(decoding: try JSONEncoder().encode(summaries), as: UTF8.self)
    #expect(!encoded.contains(canary))
  }

  @Test("Input is bound to device, run, bot, owner, workspace and origin")
  func inputBinding() async throws {
    let broker = Broker(storage: InMemorySecretStore())
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    let fields = [actor.userID, actor.workspaceID, actor.botID, actor.runID, actor.deviceID]
    for index in fields.indices {
      var changed = fields
      changed[index] = UUID()
      let other = Broker.Identity(
        userID: changed[0], workspaceID: changed[1], botID: changed[2],
        runID: changed[3], deviceID: changed[4])
      await #expect(throws: Broker.Failure.invalidRequest) {
        try await broker.submitInput(
          requestID: request.id, identity: other, origin: origin, secret: .init("test"))
      }
    }
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: "https://other.test", secret: .init("test"))
    }
    // Wrong-party attempts cannot consume the legitimate user's request.
    try await broker.submitInput(
      requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
  }

  @Test("A newer prompt supersedes the old one and invalid values consume their request")
  func supersededAndInvalidInput() async throws {
    let broker = Broker(storage: InMemorySecretStore())
    let actor = identity()
    let saved = try await account(broker, actor)
    let old = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    let latest = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: old.id, identity: actor, origin: origin, secret: .init("test"))
    }
    await #expect(throws: Broker.Failure.invalidSecret) {
      try await broker.submitInput(
        requestID: latest.id, identity: actor, origin: origin, secret: .init(""))
    }
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: latest.id, identity: actor, origin: origin, secret: .init("test"))
    }
  }

  @Test("Expiry and process restart retire pending input")
  func expiryAndRestart() async throws {
    let clock = TestClock()
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage, now: { clock.read() })
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    clock.advance(300)
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
    }
    let fresh = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    let restarted = Broker(storage: storage)
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await restarted.submitInput(
        requestID: fresh.id, identity: actor, origin: origin, secret: .init("test"))
    }
  }

  @Test("Grant changes and disconnect invalidate pending requests")
  func revocation() async throws {
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    try await broker.updateGrant(
      accountID: saved.id, userID: actor.userID, workspaceID: actor.workspaceID,
      bots: .selected([]), actions: [])
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
    }
    await #expect(throws: Broker.Failure.denied) {
      try await broker.authorise(
        accountID: saved.id, identity: actor, origin: origin, action: .browser)
    }
    try await broker.disconnect(
      accountID: saved.id, userID: actor.userID, workspaceID: actor.workspaceID)
    let restarted = Broker(storage: storage)
    #expect(
      try await restarted.accounts(userID: actor.userID, workspaceID: actor.workspaceID).isEmpty)
  }

  @Test("Disconnect deletes credential and another owner cannot change grants")
  func removalAndAdministration() async throws {
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    let canary = "synthetic-delete-canary"
    try await broker.submitInput(
      requestID: request.id, identity: actor, origin: origin, secret: .init(canary))
    await #expect(throws: Broker.Failure.denied) {
      try await broker.updateGrant(
        accountID: saved.id, userID: UUID(), workspaceID: actor.workspaceID,
        bots: .allCurrentAndFuture, actions: [.api])
    }
    await #expect(throws: Broker.Failure.denied) {
      try await broker.disconnect(accountID: saved.id, userID: actor.userID, workspaceID: UUID())
    }
    try await broker.disconnect(
      accountID: saved.id, userID: actor.userID, workspaceID: actor.workspaceID)
    #expect(try await storage.value(for: "account-access-v1")?.contains(canary) == false)
  }

  @Test("Corrupt or unsupported state fails closed")
  func corruptState() async throws {
    let storage = InMemorySecretStore()
    let broker = Broker(storage: storage)
    for value in ["not-json", "{\"version\":99,\"entries\":[]}"] {
      try await storage.set(value, for: "account-access-v1")
      await #expect(throws: Broker.Failure.unavailable) {
        try await broker.accounts(userID: UUID(), workspaceID: UUID())
      }
      #expect(try await storage.value(for: "account-access-v1") == value)
    }
  }

  @Test("Removing a device or ending a run cancels its pending input")
  func cancellation() async throws {
    let broker = Broker(storage: InMemorySecretStore())
    let actor = identity()
    let saved = try await account(broker, actor)
    for cancelDevice in [true, false] {
      let request = try await broker.requestInput(
        accountID: saved.id, identity: actor, origin: origin, action: .browser)
      if cancelDevice {
        try await broker.cancelInputs(deviceID: actor.deviceID)
      } else {
        try await broker.cancelInputs(runID: actor.runID)
      }
      await #expect(throws: Broker.Failure.invalidRequest) {
        try await broker.submitInput(
          requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
      }
    }
  }

  @Test("Persistence errors are sanitised and failed submissions cannot be replayed")
  func failedStorage() async throws {
    let storage = ControlledStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    let saved = try await account(broker, actor)
    let request = try await broker.requestInput(
      accountID: saved.id, identity: actor, origin: origin, action: .browser)
    await storage.setFailWrites(true)
    await #expect(throws: Broker.Failure.unavailable) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
    }
    await storage.setFailWrites(false)
    await #expect(throws: Broker.Failure.invalidRequest) {
      try await broker.submitInput(
        requestID: request.id, identity: actor, origin: origin, secret: .init("test"))
    }
    #expect(
      try await broker.accounts(userID: actor.userID, workspaceID: actor.workspaceID)
        .first?.hasCredential == false)
  }

  @Test("Suspended storage cannot allow concurrent lost updates")
  func concurrentMutation() async throws {
    let storage = ControlledStore()
    let broker = Broker(storage: storage)
    let actor = identity()
    await storage.pauseNextWrite()
    let creation = Task { try await account(broker, actor) }
    await storage.waitUntilPaused()
    await #expect(throws: Broker.Failure.busy) {
      try await account(broker, actor)
    }
    await storage.resumeWrite()
    let saved = try await creation.value
    #expect(
      try await broker.accounts(userID: actor.userID, workspaceID: actor.workspaceID) == [saved])
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_000)
  func read() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor ControlledStore: SecretStore {
  enum StorageFailure: Error { case sensitiveUnderlyingError }
  private var value: String?
  private var failWrites = false
  private var shouldPause = false
  private var paused: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  func setFailWrites(_ value: Bool) { failWrites = value }
  func pauseNextWrite() { shouldPause = true }
  func waitUntilPaused() async {
    if paused != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func resumeWrite() {
    paused?.resume()
    paused = nil
  }
  func set(_ value: String, for key: String) async throws {
    if shouldPause {
      shouldPause = false
      await withCheckedContinuation {
        paused = $0
        observer?.resume()
        observer = nil
      }
    }
    if failWrites { throw StorageFailure.sensitiveUnderlyingError }
    self.value = value
  }
  func value(for key: String) async throws -> String? { value }
  func delete(_ key: String) async throws { value = nil }
}

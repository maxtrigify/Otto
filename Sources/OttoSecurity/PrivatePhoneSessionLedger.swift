#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
import Foundation

/// In-memory, request-scoped authorization ledger. A restarted host has no valid sessions.
/// This is not an HTTP authentication layer: the transport must prove possession of the
/// browser key before calling methods with its public key.
public actor PrivatePhoneSessionLedger {
  public enum Failure: Error { case denied }
  public struct Scope: Equatable, Sendable {
    public let installationID: UUID
    public let workspaceID: UUID
    public let bindingID: UUID
    public let jobID: UUID
    public let botID: UUID
    public let runID: UUID
    public let accountID: UUID
    public let origin: String

    public init(
      installationID: UUID, workspaceID: UUID, bindingID: UUID, jobID: UUID,
      botID: UUID, runID: UUID, accountID: UUID, origin: String
    ) {
      self.installationID = installationID
      self.workspaceID = workspaceID
      self.bindingID = bindingID
      self.jobID = jobID
      self.botID = botID
      self.runID = runID
      self.accountID = accountID
      self.origin = origin
    }
  }

  public struct Issued: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
  {
    public let id: UUID
    public let expiresAt: Date
    public let capability: Data
    public var description: String { "<private sign-in capability redacted>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["capability": "<redacted>"]) }
  }

  private struct Record {
    let scope: Scope
    let expiresAt: Date
    let capabilityHash: Data
    var browserKey: Data?
    var accepted: Set<UUID> = []
    var inFlight: UUID?
  }
  private var records: [UUID: Record] = [:]
  private let now: @Sendable () -> Date
  public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

  public func issue(scope: Scope) throws -> Issued {
    purge()
    guard records.count < 16, let url = URLComponents(string: scope.origin),
      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path.isEmpty
    else { throw Failure.denied }
    // A new request for the same job/account supersedes its previous capability.
    records = records.filter {
      $0.value.scope.jobID != scope.jobID || $0.value.scope.accountID != scope.accountID
    }
    let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let issued = Issued(id: UUID(), expiresAt: now().addingTimeInterval(300), capability: token)
    records[issued.id] = Record(
      scope: scope, expiresAt: issued.expiresAt,
      capabilityHash: Data(SHA256.hash(data: token)))
    return issued
  }

  /// Call only after authenticating an encrypted claim from this browser public key.
  /// Atomic single-claim behavior means even the winning browser cannot claim twice.
  public func claim(id: UUID, capability: Data, browserPublicKey: Data, scope: Scope) throws {
    purge()
    guard capability.count == 32, browserPublicKey.count == 65,
      (try? P256.KeyAgreement.PublicKey(x963Representation: browserPublicKey)) != nil,
      var record = records[id], record.scope == scope, record.browserKey == nil,
      equal(record.capabilityHash, Data(SHA256.hash(data: capability)))
    else { throw Failure.denied }
    record.browserKey = browserPublicKey
    records[id] = record
  }

  /// Consume before any side effect. A lost acknowledgement never makes this ID retryable.
  /// Only one mutation can be in flight. Read-only status is handled separately by the host.
  public func accept(id: UUID, operationID: UUID, browserPublicKey: Data, scope: Scope) throws {
    purge()
    guard var record = records[id], record.scope == scope,
      record.browserKey == browserPublicKey, record.browserKey != nil,
      record.inFlight == nil, record.accepted.count < 128,
      !record.accepted.contains(operationID)
    else { throw Failure.denied }
    record.accepted.insert(operationID)
    record.inFlight = operationID
    records[id] = record
  }

  /// The trusted host clears in-flight state only after it knows the mutation's result.
  /// For uncertainty it must close the session instead of allowing a fresh mutation.
  public func completedOperation(id: UUID, operationID: UUID) throws {
    purge()
    guard var record = records[id], record.inFlight == operationID else { throw Failure.denied }
    record.inFlight = nil
    records[id] = record
  }

  public func close(id: UUID) { records.removeValue(forKey: id) }
  public func revoke(bindingID: UUID) {
    records = records.filter { $0.value.scope.bindingID != bindingID }
  }
  private func purge() {
    let date = now()
    records = records.filter { $0.value.expiresAt > date }
  }
  private func equal(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
  }
}

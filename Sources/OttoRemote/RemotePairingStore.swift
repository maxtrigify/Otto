import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

private struct PersistedRemotePairing: Codable {
  var schemaVersion: Int
  var environmentID: UUID
  var environmentName: String
  var fingerprint: String
  var offers: [RemotePairingOffer]
  var devices: [RemotePairedDevice]
}

public enum RemotePairingError: Error, LocalizedError, Equatable, Sendable {
  case invalidOffer
  case expiredOffer
  case invalidDevice
  case unauthorized

  public var errorDescription: String? {
    switch self {
    case .invalidOffer: "That pairing offer is invalid or has already been used."
    case .expiredOffer: "That pairing offer has expired."
    case .invalidDevice: "A device name and public key are required."
    case .unauthorized: "That device credential is invalid, revoked, or out of scope."
    }
  }
}

public actor RemotePairingStore {
  public static let currentSchemaVersion = 1
  public let environmentID: UUID
  public let environmentName: String
  public let fingerprint: String
  private let fileURL: URL
  private var offers: [RemotePairingOffer]
  private var devices: [RemotePairedDevice]

  public init(
    stateDirectory: URL, environmentName: String, environmentPublicKey: String,
    environmentID: UUID = UUID()
  ) throws {
    self.fileURL = stateDirectory.appending(path: "paired-devices.json")
    if let data = try? Data(contentsOf: fileURL),
      let persisted = try? JSONDecoder.remote.decode(PersistedRemotePairing.self, from: data)
    {
      self.environmentID = persisted.environmentID
      self.environmentName = persisted.environmentName
      self.fingerprint = persisted.fingerprint
      self.offers = persisted.offers
      self.devices = persisted.devices
    } else {
      self.environmentID = environmentID
      self.environmentName = String(environmentName.prefix(120))
      self.fingerprint = Self.hash(environmentPublicKey)
      self.offers = []
      self.devices = []
      try FileManager.default.createDirectory(
        at: stateDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let data = try JSONEncoder.remote.encode(
        PersistedRemotePairing(
          schemaVersion: Self.currentSchemaVersion, environmentID: environmentID,
          environmentName: String(environmentName.prefix(120)),
          fingerprint: Self.hash(environmentPublicKey), offers: [], devices: []))
      try data.write(to: fileURL, options: [.atomic])
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
  }

  public func createOffer(
    scopes: Set<RemoteDeviceScope>, lifetime: TimeInterval = 300, now: Date = .now
  ) throws -> RemotePairingOffer {
    offers.removeAll { $0.expiresAt <= now }
    let offer = RemotePairingOffer(
      environmentID: environmentID, environmentName: environmentName,
      fingerprint: fingerprint, code: Self.code(),
      expiresAt: now.addingTimeInterval(min(max(lifetime, 30), 600)), scopes: scopes)
    offers.append(offer)
    try persist()
    return offer
  }

  public func qrPayload(for offer: RemotePairingOffer) -> RemotePairingQRPayload {
    RemotePairingQRPayload(
      protocolVersion: RemoteProtocol.version, offerID: offer.id,
      environmentID: offer.environmentID, environmentName: offer.environmentName,
      fingerprint: offer.fingerprint, code: offer.code, expiresAt: offer.expiresAt)
  }

  public func exchange(
    offerID: UUID, code: String, deviceName: String, devicePublicKey: String,
    now: Date = .now
  ) throws -> RemotePairingResult {
    guard let index = offers.firstIndex(where: { $0.id == offerID && $0.code == code }) else {
      throw RemotePairingError.invalidOffer
    }
    let offer = offers.remove(at: index)
    guard offer.expiresAt > now else {
      try persist()
      throw RemotePairingError.expiredOffer
    }
    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = devicePublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !key.isEmpty else { throw RemotePairingError.invalidDevice }
    let credential = RemoteTokenGenerator.generate()
    let device = RemotePairedDevice(
      name: String(name.prefix(120)), publicKey: String(key.prefix(1_024)),
      credentialHash: Self.hash(credential), scopes: offer.scopes, pairedAt: now)
    devices.append(device)
    try persist()
    return RemotePairingResult(device: device, credential: credential)
  }

  public func authorize(
    deviceID: UUID, credential: String, scope: RemoteDeviceScope, now: Date = .now
  ) throws -> RemotePairedDevice {
    guard let index = devices.firstIndex(where: { $0.id == deviceID }),
      devices[index].revokedAt == nil,
      devices[index].scopes.contains(scope),
      Self.constantTimeEqual(devices[index].credentialHash, Self.hash(credential))
    else { throw RemotePairingError.unauthorized }
    devices[index].lastSeenAt = now
    try persist()
    return devices[index]
  }

  public func listDevices() -> [RemotePairedDevice] {
    devices.sorted { $0.pairedAt > $1.pairedAt }
  }

  public func revoke(deviceID: UUID, at date: Date = .now) throws {
    guard let index = devices.firstIndex(where: { $0.id == deviceID }) else {
      throw RemotePairingError.unauthorized
    }
    devices[index].revokedAt = date
    try persist()
  }

  public func registerPush(
    deviceID: UUID,
    token: String,
    environment: RemotePushEnvironment,
    at date: Date = .now
  ) throws {
    guard let index = devices.firstIndex(where: { $0.id == deviceID && $0.revokedAt == nil }) else {
      throw RemotePairingError.unauthorized
    }
    let normalized = token.lowercased()
    guard (32...512).contains(normalized.count),
      normalized.allSatisfy({ $0.isHexDigit })
    else { throw RemotePairingError.invalidDevice }
    devices[index].pushToken = normalized
    devices[index].pushEnvironment = environment
    devices[index].pushRegisteredAt = date
    try persist()
  }

  private func persist() throws {
    let encoder = JSONEncoder.remote
    let data = try encoder.encode(
      PersistedRemotePairing(
        schemaVersion: Self.currentSchemaVersion, environmentID: environmentID,
        environmentName: environmentName, fingerprint: fingerprint, offers: offers,
        devices: devices))
    try data.write(to: fileURL, options: [.atomic])
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private nonisolated static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private nonisolated static func code() -> String {
    var generator = SystemRandomNumberGenerator()
    return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
  }

  private nonisolated static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var difference = UInt8(a.count ^ b.count)
    for index in 0..<max(a.count, b.count) {
      difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
    }
    return difference == 0
  }
}

import Foundation

public enum ManagedRemoteDeviceKind: String, Codable, CaseIterable, Sendable {
  case macHost = "mac_host"
  case iPhone = "iphone"
}

public enum ManagedEnvironmentPresenceState: String, Codable, CaseIterable, Sendable {
  case online
  case offline
}

public struct ManagedRemoteAccount: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var displayName: String
  public var createdAt: Date

  public init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
    self.id = id
    self.displayName = displayName
    self.createdAt = createdAt
  }
}

/// Hosted relay access is a separate Otto entitlement. Local and Tailscale connections never
/// consult this state.
public enum ManagedRemoteSubscriptionState: String, Codable, Equatable, Sendable {
  case missing
  case active
  case expired
}

public struct ManagedRemoteSubscriptionStatus: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var state: ManagedRemoteSubscriptionState
  public var plan: String?
  public var features: [String]
  public var expiresAt: Date?

  public init(
    accountID: UUID,
    state: ManagedRemoteSubscriptionState,
    plan: String? = nil,
    features: [String] = [],
    expiresAt: Date? = nil
  ) {
    self.accountID = accountID
    self.state = state
    self.plan = plan
    self.features = features
    self.expiresAt = expiresAt
  }
}

public enum ManagedRemoteSubscriptionFeature {
  public static let remoteAccess = "managed_remote"
}

public enum ManagedRemoteSubscriptionDevice {
  public static func identifier(for accountID: UUID) -> String {
    "managed-remote:\(accountID.uuidString.lowercased())"
  }
}

public struct ManagedRemoteSubscriptionActivationRequest: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var licenseKey: String

  public init(accountID: UUID, licenseKey: String) {
    self.accountID = accountID
    self.licenseKey = licenseKey
  }
}

public struct ManagedRemoteSubscriptionRefreshRequest: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var deviceToken: String

  public init(accountID: UUID, deviceToken: String) {
    self.accountID = accountID
    self.deviceToken = deviceToken
  }
}

public struct ManagedRemoteSubscriptionActivationResponse: Codable, Equatable, Sendable {
  public var status: ManagedRemoteSubscriptionStatus
  public var entitlement: SignedDocument
  public var deviceToken: String

  public init(
    status: ManagedRemoteSubscriptionStatus,
    entitlement: SignedDocument,
    deviceToken: String
  ) {
    self.status = status
    self.entitlement = entitlement
    self.deviceToken = deviceToken
  }
}

public struct ManagedRemoteDevice: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var accountID: UUID
  public var name: String
  public var kind: ManagedRemoteDeviceKind
  public var publicKey: String
  public var createdAt: Date
  public var revokedAt: Date?

  public init(
    id: UUID = UUID(), accountID: UUID, name: String, kind: ManagedRemoteDeviceKind,
    publicKey: String, createdAt: Date = .now, revokedAt: Date? = nil
  ) {
    self.id = id
    self.accountID = accountID
    self.name = name
    self.kind = kind
    self.publicKey = publicKey
    self.createdAt = createdAt
    self.revokedAt = revokedAt
  }
}

public struct ManagedEnvironmentPresence: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { environmentID }
  public var environmentID: UUID
  public var accountID: UUID
  public var hostDeviceID: UUID
  public var name: String
  public var endpoint: URL
  public var state: ManagedEnvironmentPresenceState
  public var hostVersion: String
  public var protocolVersion: Int
  public var capabilities: [String]
  public var lastSeenAt: Date
  public var expiresAt: Date

  public init(
    environmentID: UUID, accountID: UUID, hostDeviceID: UUID, name: String, endpoint: URL,
    state: ManagedEnvironmentPresenceState, hostVersion: String, protocolVersion: Int,
    capabilities: [String], lastSeenAt: Date, expiresAt: Date
  ) {
    self.environmentID = environmentID
    self.accountID = accountID
    self.hostDeviceID = hostDeviceID
    self.name = name
    self.endpoint = endpoint
    self.state = state
    self.hostVersion = hostVersion
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
    self.lastSeenAt = lastSeenAt
    self.expiresAt = expiresAt
  }
}

public struct ManagedConnectionTicketClaims: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var deviceID: UUID
  public var environmentID: UUID
  public var endpoint: URL
  public var scopes: [String]
  public var nonce: UUID
  public var issuedAt: Date
  public var expiresAt: Date

  public init(
    accountID: UUID, deviceID: UUID, environmentID: UUID, endpoint: URL,
    scopes: [String], nonce: UUID = UUID(), issuedAt: Date, expiresAt: Date
  ) {
    self.accountID = accountID
    self.deviceID = deviceID
    self.environmentID = environmentID
    self.endpoint = endpoint
    self.scopes = scopes
    self.nonce = nonce
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
  }
}

public struct ManagedAccountProvisioning: Codable, Equatable, Sendable {
  public var account: ManagedRemoteAccount
  public var credential: String
  public init(account: ManagedRemoteAccount, credential: String) {
    self.account = account
    self.credential = credential
  }
}

public struct ManagedDeviceRegistration: Codable, Equatable, Sendable {
  public var device: ManagedRemoteDevice
  public var credential: String
  public init(device: ManagedRemoteDevice, credential: String) {
    self.device = device
    self.credential = credential
  }
}

public struct ManagedPairingOffer: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var accountID: UUID
  public var secret: String
  public var createdAt: Date
  public var expiresAt: Date

  public init(
    id: UUID = UUID(),
    accountID: UUID,
    secret: String,
    createdAt: Date = .now,
    expiresAt: Date
  ) {
    self.id = id
    self.accountID = accountID
    self.secret = secret
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }
}

public enum ManagedRemotePairingPayloadError: Error, LocalizedError, Equatable, Sendable {
  case invalidPayload

  public var errorDescription: String? {
    "That managed Otto pairing code is invalid. Ask the Mac to create a new one."
  }
}

/// The short-lived payload rendered by a managed Mac. It carries only a single-use exchange
/// secret; durable account and device credentials are never embedded in the QR code.
public struct ManagedRemotePairingPayload: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var controlPlaneURL: URL
  public var offerID: UUID
  public var secret: String
  public var expiresAt: Date

  public init(
    protocolVersion: Int = 1,
    controlPlaneURL: URL,
    offerID: UUID,
    secret: String,
    expiresAt: Date
  ) throws {
    guard protocolVersion == 1,
      Self.isSafeControlPlane(controlPlaneURL),
      secret.utf8.count >= 32,
      secret.utf8.count <= 1_024
    else { throw ManagedRemotePairingPayloadError.invalidPayload }
    self.protocolVersion = protocolVersion
    self.controlPlaneURL = controlPlaneURL
    self.offerID = offerID
    self.secret = secret
    self.expiresAt = expiresAt
  }

  public func qrString() throws -> String {
    let data = try JSONEncoder.commercial.encode(self)
    let payload = data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var components = URLComponents()
    components.scheme = "otto"
    components.host = "remote"
    components.queryItems = [URLQueryItem(name: "payload", value: payload)]
    guard let value = components.string else {
      throw ManagedRemotePairingPayloadError.invalidPayload
    }
    return value
  }

  public init(qrString: String) throws {
    guard let components = URLComponents(string: qrString),
      // `muse://` codes from before the rename are still accepted.
      ["otto", "muse"].contains(components.scheme?.lowercased()),
      components.host?.lowercased() == "remote",
      let encoded = components.queryItems?.first(where: { $0.name == "payload" })?.value
    else { throw ManagedRemotePairingPayloadError.invalidPayload }
    var base64 = encoded.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
    guard let data = Data(base64Encoded: base64),
      let decoded = try? JSONDecoder.commercial.decode(Self.self, from: data)
    else { throw ManagedRemotePairingPayloadError.invalidPayload }
    try self.init(
      protocolVersion: decoded.protocolVersion,
      controlPlaneURL: decoded.controlPlaneURL,
      offerID: decoded.offerID,
      secret: decoded.secret,
      expiresAt: decoded.expiresAt
    )
  }

  private static func isSafeControlPlane(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return false }
    let loopback = host == "127.0.0.1" || host == "::1" || host == "localhost"
    return scheme == "https" || (scheme == "http" && loopback)
  }
}

public struct ManagedEnvironmentRegistration: Codable, Equatable, Sendable {
  public var presence: ManagedEnvironmentPresence
  public var connectorCredential: String
  public init(presence: ManagedEnvironmentPresence, connectorCredential: String) {
    self.presence = presence
    self.connectorCredential = connectorCredential
  }
}

public struct ManagedAccountProvisionRequest: Codable, Equatable, Sendable {
  public var displayName: String
  public init(displayName: String) { self.displayName = displayName }
}

public struct ManagedDeviceRegistrationRequest: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var name: String
  public var kind: ManagedRemoteDeviceKind
  public var publicKey: String

  public init(accountID: UUID, name: String, kind: ManagedRemoteDeviceKind, publicKey: String) {
    self.accountID = accountID
    self.name = name
    self.kind = kind
    self.publicKey = publicKey
  }
}

public struct ManagedPairingOfferRequest: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var lifetime: TimeInterval

  public init(accountID: UUID, lifetime: TimeInterval = 300) {
    self.accountID = accountID
    self.lifetime = lifetime
  }
}

public struct ManagedPairingExchangeRequest: Codable, Equatable, Sendable {
  public var offerID: UUID
  public var secret: String
  public var deviceName: String
  public var devicePublicKey: String

  public init(
    offerID: UUID,
    secret: String,
    deviceName: String,
    devicePublicKey: String
  ) {
    self.offerID = offerID
    self.secret = secret
    self.deviceName = deviceName
    self.devicePublicKey = devicePublicKey
  }
}

public struct ManagedEnvironmentRegistrationRequest: Codable, Equatable, Sendable {
  public var hostDeviceID: UUID
  public var environmentID: UUID
  public var name: String
  public var hostVersion: String
  public var protocolVersion: Int
  public var capabilities: [String]

  public init(
    hostDeviceID: UUID, environmentID: UUID, name: String, hostVersion: String,
    protocolVersion: Int, capabilities: [String]
  ) {
    self.hostDeviceID = hostDeviceID
    self.environmentID = environmentID
    self.name = name
    self.hostVersion = hostVersion
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
  }
}

public struct ManagedEnvironmentHeartbeatRequest: Codable, Equatable, Sendable {
  public var environmentID: UUID
  public var hostVersion: String
  public var protocolVersion: Int
  public var capabilities: [String]

  public init(
    environmentID: UUID, hostVersion: String, protocolVersion: Int, capabilities: [String]
  ) {
    self.environmentID = environmentID
    self.hostVersion = hostVersion
    self.protocolVersion = protocolVersion
    self.capabilities = capabilities
  }
}

public struct ManagedConnectionTicketRequest: Codable, Equatable, Sendable {
  public var deviceID: UUID
  public var environmentID: UUID
  public var scopes: [String]
  public var lifetime: TimeInterval

  public init(
    deviceID: UUID, environmentID: UUID, scopes: [String], lifetime: TimeInterval = 120
  ) {
    self.deviceID = deviceID
    self.environmentID = environmentID
    self.scopes = scopes
    self.lifetime = lifetime
  }
}

public struct ManagedDeviceRevocationRequest: Codable, Equatable, Sendable {
  public var accountID: UUID
  public var deviceID: UUID
  public init(accountID: UUID, deviceID: UUID) {
    self.accountID = accountID
    self.deviceID = deviceID
  }
}

import Foundation

public enum ReleaseChannel: String, Codable, CaseIterable, Sendable {
  case stable
  case beta
  case `internal`
}

public struct SignedDocument: Codable, Equatable, Sendable {
  public var payload: Data
  public var signature: Data
  public var keyID: String

  public init(payload: Data, signature: Data, keyID: String) {
    self.payload = payload
    self.signature = signature
    self.keyID = keyID
  }
}

public struct EntitlementClaims: Codable, Equatable, Sendable {
  public var licenseID: String
  public var deviceID: String
  public var plan: String
  public var features: [String]
  public var issuedAt: Date
  public var expiresAt: Date
  public var offlineGraceEndsAt: Date

  public init(
    licenseID: String,
    deviceID: String,
    plan: String,
    features: [String],
    issuedAt: Date,
    expiresAt: Date,
    offlineGraceEndsAt: Date
  ) {
    self.licenseID = licenseID
    self.deviceID = deviceID
    self.plan = plan
    self.features = features
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.offlineGraceEndsAt = offlineGraceEndsAt
  }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
  public var version: String
  public var build: Int
  public var artifactURL: URL
  public var sha256: String
  public var byteCount: Int64
  public var minimumMacOSVersion: String
  public var changelog: String
  public var rolloutPercentage: Int
  public var rollbackVersion: String?

  public init(
    version: String,
    build: Int,
    artifactURL: URL,
    sha256: String,
    byteCount: Int64,
    minimumMacOSVersion: String,
    changelog: String,
    rolloutPercentage: Int = 100,
    rollbackVersion: String? = nil
  ) {
    self.version = version
    self.build = build
    self.artifactURL = artifactURL
    self.sha256 = sha256
    self.byteCount = byteCount
    self.minimumMacOSVersion = minimumMacOSVersion
    self.changelog = changelog
    self.rolloutPercentage = rolloutPercentage
    self.rollbackVersion = rollbackVersion
  }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
  public var generatedAt: Date
  public var releases: [ReleaseChannel: UpdateRelease]
  public var blockedVersions: [String]
  public var message: String?

  public init(
    generatedAt: Date,
    releases: [ReleaseChannel: UpdateRelease],
    blockedVersions: [String] = [],
    message: String? = nil
  ) {
    self.generatedAt = generatedAt
    self.releases = releases
    self.blockedVersions = blockedVersions
    self.message = message
  }
}

public struct LicenseActivationRequest: Codable, Equatable, Sendable {
  public var licenseKey: String
  public var deviceID: String
  public var deviceName: String

  public init(licenseKey: String, deviceID: String, deviceName: String) {
    self.licenseKey = licenseKey
    self.deviceID = deviceID
    self.deviceName = deviceName
  }
}

public struct LicenseActivationResponse: Codable, Equatable, Sendable {
  public var entitlement: SignedDocument
  public var deviceToken: String

  public init(entitlement: SignedDocument, deviceToken: String) {
    self.entitlement = entitlement
    self.deviceToken = deviceToken
  }
}

public struct LicenseDeviceRequest: Codable, Equatable, Sendable {
  public var deviceID: String

  public init(deviceID: String) {
    self.deviceID = deviceID
  }
}

public enum EntitlementState: Equatable, Sendable {
  case unlicensed
  case active(EntitlementClaims)
  case offlineGrace(EntitlementClaims)
  case expired(EntitlementClaims)
}

public enum CommercialError: Error, Equatable, LocalizedError {
  case invalidSignature
  case unknownSigningKey(String)
  case invalidDocument
  case deviceMismatch
  case invalidServerResponse(Int)
  case invalidRelease
  case insecureURL
  case missingDeviceCredential

  public var errorDescription: String? {
    switch self {
    case .invalidSignature: "The commercial document signature is invalid."
    case .unknownSigningKey(let keyID): "The signing key \(keyID) is not trusted."
    case .invalidDocument: "The commercial document could not be decoded."
    case .deviceMismatch: "The entitlement belongs to another device."
    case .invalidServerResponse(let status): "The commercial service returned HTTP \(status)."
    case .invalidRelease: "The update manifest contains an invalid release."
    case .insecureURL: "Commercial service and artifact URLs must use HTTPS."
    case .missingDeviceCredential: "The device activation credential is missing."
    }
  }
}

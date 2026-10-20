import Foundation

#if canImport(OttoSecurity)
  import OttoSecurity
#endif

public protocol EntitlementStore: Sendable {
  func load() async throws -> SignedDocument?
  func save(_ document: SignedDocument?) async throws
}

public protocol DeviceCredentialStore: Sendable {
  func load() async throws -> String?
  func save(_ token: String?) async throws
}

public actor InMemoryEntitlementStore: EntitlementStore {
  private var document: SignedDocument?

  public init(document: SignedDocument? = nil) {
    self.document = document
  }

  public func load() -> SignedDocument? {
    document
  }

  public func save(_ document: SignedDocument?) {
    self.document = document
  }
}

public actor InMemoryDeviceCredentialStore: DeviceCredentialStore {
  private var token: String?

  public init(token: String? = nil) {
    self.token = token
  }

  public func load() -> String? {
    token
  }

  public func save(_ token: String?) {
    self.token = token
  }
}

#if canImport(OttoSecurity)
  public actor KeychainEntitlementStore: EntitlementStore {
    private let secretStore: any SecretStore
    private let key: String

    public init(
      secretStore: any SecretStore = makeDefaultSecretStore(service: OttoSecretService.licensing),
      key: String = "signed-entitlement"
    ) {
      self.secretStore = secretStore
      self.key = key
    }

    public func load() async throws -> SignedDocument? {
      guard let encoded = try await secretStore.value(for: key),
        let data = Data(base64Encoded: encoded)
      else { return nil }
      do {
        return try JSONDecoder.commercial.decode(SignedDocument.self, from: data)
      } catch {
        throw CommercialError.invalidDocument
      }
    }

    public func save(_ document: SignedDocument?) async throws {
      guard let document else {
        try await secretStore.delete(key)
        return
      }
      let data = try JSONEncoder.commercial.encode(document)
      try await secretStore.set(data.base64EncodedString(), for: key)
    }
  }

  public actor KeychainDeviceCredentialStore: DeviceCredentialStore {
    private let secretStore: any SecretStore
    private let key: String

    public init(
      secretStore: any SecretStore = makeDefaultSecretStore(service: OttoSecretService.licensing),
      key: String = "device-token"
    ) {
      self.secretStore = secretStore
      self.key = key
    }

    public func load() async throws -> String? {
      try await secretStore.value(for: key)
    }

    public func save(_ token: String?) async throws {
      if let token {
        try await secretStore.set(token, for: key)
      } else {
        try await secretStore.delete(key)
      }
    }
  }
#endif

public actor LicenseManager {
  private let deviceID: String
  private let client: CommercialClient
  private let verifier: SignedDocumentVerifier
  private let store: any EntitlementStore
  private let credentialStore: any DeviceCredentialStore
  private let now: @Sendable () -> Date

  public init(
    deviceID: String,
    client: CommercialClient,
    verifier: SignedDocumentVerifier,
    store: any EntitlementStore,
    credentialStore: any DeviceCredentialStore = InMemoryDeviceCredentialStore(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.deviceID = deviceID
    self.client = client
    self.verifier = verifier
    self.store = store
    self.credentialStore = credentialStore
    self.now = now
  }

  public func cachedState() async throws -> EntitlementState {
    guard let document = try await store.load() else { return .unlicensed }
    return try state(for: document)
  }

  public func activate(licenseKey: String, deviceName: String) async throws -> EntitlementState {
    let response = try await client.activate(
      LicenseActivationRequest(
        licenseKey: licenseKey,
        deviceID: deviceID,
        deviceName: deviceName
      )
    )
    guard !response.deviceToken.isEmpty else { throw CommercialError.missingDeviceCredential }
    let state = try state(for: response.entitlement)
    try await store.save(response.entitlement)
    try await credentialStore.save(response.deviceToken)
    return state
  }

  public func refresh() async throws -> EntitlementState {
    do {
      guard let token = try await credentialStore.load() else {
        throw CommercialError.missingDeviceCredential
      }
      let document = try await client.refresh(deviceID: deviceID, deviceToken: token)
      let state = try state(for: document)
      try await store.save(document)
      return state
    } catch {
      let cached = try await cachedState()
      switch cached {
      case .active, .offlineGrace:
        return cached
      case .unlicensed, .expired:
        throw error
      }
    }
  }

  public func deactivate() async throws {
    guard let token = try await credentialStore.load() else {
      throw CommercialError.missingDeviceCredential
    }
    try await client.deactivate(deviceID: deviceID, deviceToken: token)
    try await store.save(nil)
    try await credentialStore.save(nil)
  }

  private func state(for document: SignedDocument) throws -> EntitlementState {
    let claims = try verifier.verify(document, as: EntitlementClaims.self)
    guard claims.deviceID == deviceID else { throw CommercialError.deviceMismatch }
    let current = now()
    if current <= claims.expiresAt { return .active(claims) }
    if current <= claims.offlineGraceEndsAt { return .offlineGrace(claims) }
    return .expired(claims)
  }
}

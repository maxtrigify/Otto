import CryptoKit
import Foundation
import OttoCommercial
import OttoSecurity
import Testing

@Suite("Commercial services")
struct CommercialTests {
  @Test("Signed entitlements validate and survive in the secure cache")
  func entitlementSignatureAndCache() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claims = EntitlementClaims(
      licenseID: "license-1",
      deviceID: "device-1",
      plan: "pro",
      features: ["voice", "updates"],
      issuedAt: now.addingTimeInterval(-60),
      expiresAt: now.addingTimeInterval(60),
      offlineGraceEndsAt: now.addingTimeInterval(3_600)
    )
    let document = try signed(claims, with: key)
    let secretStore = InMemorySecretStore()
    let store = KeychainEntitlementStore(secretStore: secretStore)
    try await store.save(document)

    let client = try CommercialClient(
      baseURL: #require(URL(string: "https://commercial.example/")),
      transport: StubTransport()
    )
    let manager = LicenseManager(
      deviceID: "device-1",
      client: client,
      verifier: SignedDocumentVerifier(
        publicKeys: ["test": key.publicKey.rawRepresentation]
      ),
      store: store,
      now: { now }
    )
    #expect(try await manager.cachedState() == .active(claims))
  }

  @Test("Expired online entitlement remains usable only during its signed offline grace")
  func offlineGrace() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claims = EntitlementClaims(
      licenseID: "license-1",
      deviceID: "device-1",
      plan: "pro",
      features: [],
      issuedAt: now.addingTimeInterval(-7_200),
      expiresAt: now.addingTimeInterval(-60),
      offlineGraceEndsAt: now.addingTimeInterval(3_600)
    )
    let document = try signed(claims, with: key)
    let transport = StubTransport(error: URLError(.notConnectedToInternet))
    let client = try CommercialClient(
      baseURL: #require(URL(string: "https://commercial.example/")),
      transport: transport
    )
    let manager = LicenseManager(
      deviceID: "device-1",
      client: client,
      verifier: SignedDocumentVerifier(
        publicKeys: ["test": key.publicKey.rawRepresentation]
      ),
      store: InMemoryEntitlementStore(document: document),
      now: { now }
    )
    #expect(try await manager.refresh() == .offlineGrace(claims))
  }

  @Test("Tampering and device substitution are rejected")
  func rejectsTamperingAndDeviceSubstitution() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let claims = EntitlementClaims(
      licenseID: "license-1",
      deviceID: "another-device",
      plan: "pro",
      features: [],
      issuedAt: .distantPast,
      expiresAt: .distantFuture,
      offlineGraceEndsAt: .distantFuture
    )
    var document = try signed(claims, with: key)
    document.payload.append(0)
    let verifier = SignedDocumentVerifier(publicKeys: ["test": key.publicKey.rawRepresentation])
    #expect(throws: CommercialError.invalidSignature) {
      try verifier.verify(document, as: EntitlementClaims.self)
    }

    let validDocument = try signed(claims, with: key)
    let client = try CommercialClient(
      baseURL: #require(URL(string: "https://commercial.example/")),
      transport: StubTransport()
    )
    let manager = LicenseManager(
      deviceID: "device-1",
      client: client,
      verifier: verifier,
      store: InMemoryEntitlementStore(document: validDocument)
    )
    await #expect(throws: CommercialError.deviceMismatch) {
      try await manager.cachedState()
    }
  }

  @Test("Signed update manifests enforce channel, rollout, version, OS, and artifact integrity")
  func updateSelection() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let release = UpdateRelease(
      version: "1.2.0",
      build: 120,
      artifactURL: try #require(URL(string: "https://downloads.example/Otto-1.2.0.zip")),
      sha256: String(repeating: "a", count: 64),
      byteCount: 4_096,
      minimumMacOSVersion: "15.0",
      changelog: "A safer release.",
      rolloutPercentage: 25
    )
    let document = try signed(
      UpdateManifest(generatedAt: Date(), releases: [.beta: release]),
      with: key
    )
    let transport = StubTransport(responseData: try JSONEncoder.commercial.encode(document))
    let client = try CommercialClient(
      baseURL: #require(URL(string: "https://commercial.example/")),
      transport: transport
    )
    let updates = UpdateManager(
      client: client,
      verifier: SignedDocumentVerifier(publicKeys: ["test": key.publicKey.rawRepresentation])
    )

    let available = try await updates.availableRelease(
      channel: .beta,
      currentVersion: "1.1.9",
      currentBuild: 119,
      macOSVersion: "15.1",
      rolloutBucket: 24
    )
    #expect(available == release)
    let outsideRollout = try await updates.availableRelease(
      channel: .beta,
      currentVersion: "1.1.9",
      currentBuild: 119,
      macOSVersion: "15.1",
      rolloutBucket: 25
    )
    #expect(outsideRollout == nil)
  }

  @Test("Commercial endpoints and artifacts require TLS")
  func requiresTLS() throws {
    #expect(throws: CommercialError.insecureURL) {
      try CommercialClient(baseURL: #require(URL(string: "http://commercial.example/")))
    }
  }

  @Test("Update manifest checks bypass local and edge caches")
  func updateManifestBypassesCaches() async throws {
    let document = SignedDocument(payload: Data(), signature: Data(), keyID: "test")
    let transport = StubTransport(responseData: try JSONEncoder.commercial.encode(document))
    let client = try CommercialClient(
      baseURL: #require(URL(string: "https://commercial.example/")),
      transport: transport
    )

    _ = try await client.updateManifest()
    let request = try #require(await transport.lastRequest())
    #expect(request.url?.path == "/v1/updates/manifest")
    #expect(request.url?.query?.contains("cache_bust=") == true)
    #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
  }

  @Test("Device mutations use a bearer credential rather than trusting the device ID")
  func deviceAuthentication() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let document = try signed(
      EntitlementClaims(
        licenseID: "license-1",
        deviceID: "device-1",
        plan: "pro",
        features: [],
        issuedAt: .now,
        expiresAt: .distantFuture,
        offlineGraceEndsAt: .distantFuture
      ),
      with: key
    )
    let transport = StubTransport(responseData: try JSONEncoder.commercial.encode(document))
    let client = try CommercialClient(
      baseURL: try #require(URL(string: "https://commercial.example/")),
      transport: transport
    )
    _ = try await client.refresh(deviceID: "device-1", deviceToken: "secret-device-token")
    let request = try #require(await transport.lastRequest())
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-device-token")
    #expect(request.url?.path == "/v1/licenses/refresh")
  }

  @Test("Downloaded update artifacts must match the signed size and digest")
  func artifactIntegrity() throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
      path: "otto-update-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let artifact = temporaryDirectory.appending(path: "Otto.zip")
    let data = Data("immutable update".utf8)
    try data.write(to: artifact)
    let release = UpdateRelease(
      version: "1.2.0",
      build: 120,
      artifactURL: try #require(URL(string: "https://downloads.example/Otto.zip")),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
      byteCount: Int64(data.count),
      minimumMacOSVersion: "15.0",
      changelog: "Integrity test"
    )
    try UpdateArtifactVerifier.verify(fileURL: artifact, release: release)

    try Data("tampered update".utf8).write(to: artifact)
    #expect(throws: CommercialError.invalidRelease) {
      try UpdateArtifactVerifier.verify(fileURL: artifact, release: release)
    }
  }

  private func signed<Value: Encodable>(_ value: Value, with key: Curve25519.Signing.PrivateKey)
    throws -> SignedDocument
  {
    let payload = try JSONEncoder.commercial.encode(value)
    return try SignedDocument(
      payload: payload, signature: key.signature(for: payload), keyID: "test")
  }
}

private actor StubTransport: CommercialTransport {
  private let responseData: Data
  private let error: (any Error)?
  private var requests: [URLRequest] = []

  init(responseData: Data = Data(), error: (any Error)? = nil) {
    self.responseData = responseData
    self.error = error
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if let error { throw error }
    let response = try #require(
      HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )
    )
    return (responseData, response)
  }

  func lastRequest() -> URLRequest? {
    requests.last
  }
}

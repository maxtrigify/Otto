import Foundation
import OttoHostRuntime
import OttoRPCContracts
import OttoRemote
import OttoServices
import Testing

@Suite("Mobile pairing adapter")
struct MobilePairingAdapterTests {
  @Test("Offer exchange is single-use and revocation closes existing credentials")
  func exchangeAndRevoke() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-pairing-adapter-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let environmentID = UUID()
    let store = try RemotePairingStore(
      stateDirectory: root,
      environmentName: "Test Mac",
      environmentPublicKey: "test-environment-public-key-material",
      environmentID: environmentID
    )
    let baseURL = try #require(URL(string: "https://test-mac.example/"))
    let adapter = ApplicationServicesMobilePairingAdapter(store: store, baseURL: baseURL)
    let payload = try await adapter.createPayload(
      scopes: [.environmentRead, .threadRead, .messageWrite, .runControl],
      now: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let input = OttoMobilePairingExchangeInput(
      offerID: payload.offerID,
      code: payload.code,
      deviceName: "Test iPhone",
      devicePublicKey: "test-device-public-key"
    )

    let paired = try await adapter.exchange(input)
    #expect(paired.environmentID == environmentID)
    #expect(paired.baseURL == baseURL)
    #expect(paired.scopes == payload.scopes)
    #expect(!paired.credential.isEmpty)

    await #expect(throws: RemotePairingError.invalidOffer) {
      try await adapter.exchange(input)
    }
    let client = try await adapter.authenticate(
      deviceID: paired.deviceID,
      credential: paired.credential,
      requiredScope: .threadRead
    )
    #expect(client.deviceID == paired.deviceID)
    #expect(client.scopes.contains(.threadRead))

    try await adapter.revoke(deviceID: paired.deviceID)
    await #expect(throws: RemotePairingError.unauthorized) {
      try await adapter.authenticate(
        deviceID: paired.deviceID,
        credential: paired.credential,
        requiredScope: .threadRead
      )
    }
    #expect(await adapter.listDevices().first?.revokedAt != nil)
  }

  @Test("Authenticated device push registration persists and revocation rejects updates")
  func pushRegistration() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-push-registration-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RemotePairingStore(
      stateDirectory: root,
      environmentName: "Test Mac",
      environmentPublicKey: "test-environment-public-key-material"
    )
    let offer = try await store.createOffer(scopes: [.readActivity])
    let paired = try await store.exchange(
      offerID: offer.id,
      code: offer.code,
      deviceName: "Test iPhone",
      devicePublicKey: "test-device-key"
    )
    let token = String(repeating: "ab", count: 32)

    try await store.registerPush(
      deviceID: paired.device.id,
      token: token,
      environment: .sandbox
    )
    let registered = try #require(await store.listDevices().first)
    #expect(registered.pushToken == token)
    #expect(registered.pushEnvironment == .sandbox)
    #expect(registered.pushRegisteredAt != nil)

    try await store.revoke(deviceID: paired.device.id)
    await #expect(throws: RemotePairingError.unauthorized) {
      try await store.registerPush(
        deviceID: paired.device.id,
        token: String(repeating: "cd", count: 32),
        environment: .sandbox
      )
    }
  }
}

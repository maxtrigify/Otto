import Foundation
import OttoRemote
import Testing

@Suite("Remote device pairing")
struct RemotePairingStoreTests {
  @Test("QR exchange is one-time, expiring, and contains no permanent credential")
  func oneTimeExchange() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RemotePairingStore(
      stateDirectory: root, environmentName: "Studio Mac", environmentPublicKey: "host-key")
    let now = Date(timeIntervalSince1970: 100)
    let offer = try await store.createOffer(
      scopes: [.readActivity, .readThreads, .sendMessages], now: now)
    let payload = await store.qrPayload(for: offer)
    let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    #expect(!encoded.contains("http://"))
    #expect(!encoded.contains("https://"))
    #expect(!encoded.contains("credential"))

    let result = try await store.exchange(
      offerID: offer.id, code: offer.code, deviceName: "Max's iPhone",
      devicePublicKey: "device-public-key", now: now.addingTimeInterval(1))
    #expect(!result.credential.isEmpty)
    #expect(result.device.credentialHash != result.credential)
    await #expect(throws: RemotePairingError.invalidOffer) {
      try await store.exchange(
        offerID: offer.id, code: offer.code, deviceName: "Replay",
        devicePublicKey: "another-key", now: now.addingTimeInterval(2))
    }
  }

  @Test("Device credentials are scope-bound, persistent, and immediately revocable")
  func scopedRevocation() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var store = try RemotePairingStore(
      stateDirectory: root, environmentName: "Studio Mac", environmentPublicKey: "host-key")
    let offer = try await store.createOffer(scopes: [.readActivity])
    let result = try await store.exchange(
      offerID: offer.id, code: offer.code, deviceName: "Phone", devicePublicKey: "phone-key")
    _ = try await store.authorize(
      deviceID: result.device.id, credential: result.credential, scope: .readActivity)
    await #expect(throws: RemotePairingError.unauthorized) {
      try await store.authorize(
        deviceID: result.device.id, credential: result.credential, scope: .respondApprovals)
    }

    store = try RemotePairingStore(
      stateDirectory: root, environmentName: "Ignored", environmentPublicKey: "ignored")
    #expect(await store.listDevices().count == 1)
    try await store.revoke(deviceID: result.device.id)
    await #expect(throws: RemotePairingError.unauthorized) {
      try await store.authorize(
        deviceID: result.device.id, credential: result.credential, scope: .readActivity)
    }
  }

  @Test("Expired offers fail closed")
  func expiration() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RemotePairingStore(
      stateDirectory: root, environmentName: "Mac", environmentPublicKey: "host-key")
    let now = Date(timeIntervalSince1970: 100)
    let offer = try await store.createOffer(scopes: [.readThreads], lifetime: 30, now: now)
    await #expect(throws: RemotePairingError.expiredOffer) {
      try await store.exchange(
        offerID: offer.id, code: offer.code, deviceName: "Phone", devicePublicKey: "phone-key",
        now: now.addingTimeInterval(31))
    }
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-pairing-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

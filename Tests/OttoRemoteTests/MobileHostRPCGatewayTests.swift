import Foundation
import OttoRemote
import Testing

@Suite("Mobile host RPC gateway")
struct MobileHostRPCGatewayTests {
  @Test("Every request is authorized against its method before dispatch")
  func scopedDispatch() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pairing = try RemotePairingStore(
      stateDirectory: root, environmentName: "Mac", environmentPublicKey: "host")
    let offer = try await pairing.createOffer(scopes: [.readThreads, .sendMessages])
    let paired = try await pairing.exchange(
      offerID: offer.id, code: offer.code, deviceName: "Phone", devicePublicKey: "phone")
    let handler = RecordingMobileHandler()
    let gateway = MobileHostRPCGateway(pairing: pairing, handler: handler)

    let allowed = MobileRPCRequest(method: .messageSend, params: Data("hello".utf8))
    let response = try await gateway.call(
      allowed, deviceID: paired.device.id, credential: paired.credential)
    #expect(response.id == allowed.id)
    #expect(await handler.methods == [.messageSend])

    await #expect(throws: RemotePairingError.unauthorized) {
      try await gateway.call(
        MobileRPCRequest(method: .approvalRespond), deviceID: paired.device.id,
        credential: paired.credential)
    }
    #expect(await handler.methods == [.messageSend])
  }

  @Test("Read access cannot revoke devices and revocation stops future calls")
  func revocationBoundary() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pairing = try RemotePairingStore(
      stateDirectory: root, environmentName: "Mac", environmentPublicKey: "host")
    let readOffer = try await pairing.createOffer(scopes: [.readActivity])
    let reader = try await pairing.exchange(
      offerID: readOffer.id, code: readOffer.code, deviceName: "Reader",
      devicePublicKey: "reader")
    let adminOffer = try await pairing.createOffer(scopes: [.readActivity, .manageDevices])
    let admin = try await pairing.exchange(
      offerID: adminOffer.id, code: adminOffer.code, deviceName: "Admin",
      devicePublicKey: "admin")
    let handler = RecordingMobileHandler()
    let gateway = MobileHostRPCGateway(pairing: pairing, handler: handler)

    await #expect(throws: RemotePairingError.unauthorized) {
      try await gateway.call(
        MobileRPCRequest(method: .deviceRevoke), deviceID: reader.device.id,
        credential: reader.credential)
    }
    _ = try await gateway.call(
      MobileRPCRequest(method: .deviceRevoke), deviceID: admin.device.id,
      credential: admin.credential)
    try await pairing.revoke(deviceID: admin.device.id)
    await #expect(throws: RemotePairingError.unauthorized) {
      try await gateway.call(
        MobileRPCRequest(method: .activityList), deviceID: admin.device.id,
        credential: admin.credential)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-gateway-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}

private actor RecordingMobileHandler: MobileRPCHandling {
  private(set) var methods: [MobileChatMethod] = []
  func handle(
    request: MobileRPCRequest, device: RemotePairedDevice
  ) async throws -> MobileRPCResponse {
    methods.append(request.method)
    return MobileRPCResponse(id: request.id, result: request.params)
  }
}

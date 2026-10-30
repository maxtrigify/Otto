import Foundation
import OttoHostRuntime
import OttoHostTransport
import OttoRPCContracts
import OttoRemote

public actor ApplicationServicesMobilePairingAdapter: OttoHostPairingHandling {
  private let store: RemotePairingStore
  private let baseURL: URL

  public init(store: RemotePairingStore, baseURL: URL) {
    self.store = store
    self.baseURL = baseURL
  }

  public func createPayload(
    scopes: Set<OttoRPCScope> = Set(OttoRPCScope.allCases),
    lifetime: TimeInterval = 300,
    now: Date = .now
  ) async throws -> OttoMobilePairingPayload {
    let offer = try await store.createOffer(
      scopes: Set(scopes.map(remoteScope)),
      lifetime: lifetime,
      now: now
    )
    return OttoMobilePairingPayload(
      offerID: offer.id,
      environmentID: offer.environmentID,
      environmentName: offer.environmentName,
      fingerprint: offer.fingerprint,
      baseURL: baseURL,
      code: offer.code,
      expiresAt: offer.expiresAt,
      scopes: scopes
    )
  }

  public func exchange(
    _ input: OttoMobilePairingExchangeInput
  ) async throws -> OttoMobilePairingExchangeOutput {
    let result = try await store.exchange(
      offerID: input.offerID,
      code: input.code,
      deviceName: input.deviceName,
      devicePublicKey: input.devicePublicKey
    )
    return OttoMobilePairingExchangeOutput(
      deviceID: result.device.id,
      credential: result.credential,
      environmentID: await store.environmentID,
      environmentName: await store.environmentName,
      baseURL: baseURL,
      fingerprint: await store.fingerprint,
      scopes: Set(result.device.scopes.compactMap(rpcScope))
    )
  }

  public func authenticate(
    deviceID: UUID,
    credential: String,
    requiredScope: OttoRPCScope
  ) async throws -> OttoHostClientContext {
    let device = try await store.authorize(
      deviceID: deviceID,
      credential: credential,
      scope: remoteScope(requiredScope)
    )
    return OttoHostClientContext(
      deviceID: device.id,
      scopes: Set(device.scopes.compactMap(rpcScope))
    )
  }

  public func listDevices() async -> [RemotePairedDevice] {
    await store.listDevices()
  }

  public func revoke(deviceID: UUID) async throws {
    try await store.revoke(deviceID: deviceID)
  }

  private nonisolated func remoteScope(_ scope: OttoRPCScope) -> RemoteDeviceScope {
    switch scope {
    case .environmentRead: .readActivity
    case .threadRead: .readThreads
    case .messageWrite: .sendMessages
    case .runControl: .interruptRuns
    case .approvalRespond: .respondApprovals
    case .secureLogin: .controlComputer
    // Owner-level: phones are never granted bot management (rpcScope maps nothing back to it).
    case .botManage: .manageDevices
    }
  }

  private nonisolated func rpcScope(_ scope: RemoteDeviceScope) -> OttoRPCScope? {
    switch scope {
    case .readActivity: .environmentRead
    case .readThreads: .threadRead
    case .sendMessages: .messageWrite
    case .interruptRuns: .runControl
    case .respondApprovals: .approvalRespond
    case .controlComputer: .secureLogin
    case .manageDevices: nil
    }
  }
}

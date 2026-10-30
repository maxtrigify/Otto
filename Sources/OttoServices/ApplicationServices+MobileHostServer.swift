import Foundation
import Hummingbird
import OttoCommercial
import OttoHostRuntime
import OttoHostTransport
import OttoModels
import OttoRPCContracts
import OttoRemote

extension ApplicationServices {
  /// Starts a loopback-only paired-device host by default. An explicit developer token remains
  /// available for diagnostics, while normal clients authenticate with their paired credential.
  public func startMobileHostIfConfigured(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async {
    guard mobileHostTask == nil, !isStartingMobileHost else { return }
    // Headless engines (otto-engine) serve their own client and must not claim the phone port.
    guard OttoEnvironment.value("MOBILE_HOST", in: environment) != "off" else { return }
    let attemptID = UUID()
    mobileHostAttemptID = attemptID
    isStartingMobileHost = true
    mobileHostError = nil
    mobilePairingPayload = nil
    mobileHostEndpoint = nil
    do {
      let token =
        OttoEnvironment.value("MOBILE_HOST_TOKEN", in: environment).flatMap {
          $0.isEmpty ? nil : $0
        }
        ?? RemoteTokenGenerator.generate()
      let allowLAN = OttoEnvironment.value("MOBILE_HOST_ALLOW_LAN", in: environment) == "1"
      let hostname =
        allowLAN
        ? (OttoEnvironment.value("MOBILE_HOST_BIND", in: environment) ?? "0.0.0.0") : "127.0.0.1"
      let isDevelopmentApp = Bundle.main.bundleIdentifier == OttoNames.developmentBundleIdentifier
      let defaultPort = isDevelopmentApp ? 7340 : 7338
      let port =
        Int(OttoEnvironment.value("MOBILE_HOST_PORT", in: environment) ?? "") ?? defaultPort
      let configuration = try OttoHostTransportConfiguration(
        hostname: hostname,
        port: port,
        allowLAN: allowLAN,
        token: token,
        certificateChainFile: OttoEnvironment.value("MOBILE_TLS_CERT", in: environment),
        privateKeyFile: OttoEnvironment.value("MOBILE_TLS_KEY", in: environment)
      )
      let stateDirectory = URL(fileURLWithPath: workspacePath, isDirectory: true)
        .appending(
          path: isDevelopmentApp ? ".otto/mobile-host-dev" : ".otto/mobile-host",
          directoryHint: .isDirectory)
      let environmentID = try mobileEnvironmentID(in: stateDirectory)
      let pairingStore = try RemotePairingStore(
        stateDirectory: stateDirectory.appending(path: "pairing", directoryHint: .isDirectory),
        environmentName: Host.current().localizedName ?? "This Mac",
        environmentPublicKey: try mobileHostIdentityMaterial(in: stateDirectory),
        environmentID: environmentID
      )
      let adapter = ApplicationServicesMobileHostAdapter(
        services: self,
        environmentID: environmentID,
        hostVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        pairingStore: pairingStore
      )
      let journal = try RunEventJournal(
        directory: stateDirectory.appending(path: "events", directoryHint: .isDirectory)
      )
      let host = OttoHostRuntime(dataSource: adapter, journal: journal)
      let pushWorker = try mobileAPNsWorker(
        environment: environment,
        stateDirectory: stateDirectory,
        pairingStore: pairingStore
      )
      let bridge = OttoMobileEventBridge(
        services: self,
        adapter: adapter,
        host: host,
        pushWorker: pushWorker
      )
      let baseURL = try mobileAdvertisedBaseURL(
        environment: environment,
        configuration: configuration
      )
      let pairing = ApplicationServicesMobilePairingAdapter(
        store: pairingStore,
        baseURL: baseURL
      )
      let pairingPayload = try await pairing.createPayload()
      guard mobileHostAttemptID == attemptID, !Task.isCancelled else {
        bridge.stop()
        return
      }
      let app = try OttoHostHTTPApplication.make(
        host: host,
        configuration: configuration,
        pairing: pairing,
        onServerRunning: { [weak self] in
          await MainActor.run {
            guard let self, self.mobileHostAttemptID == attemptID else { return }
            self.mobileHostEndpoint = baseURL
            self.mobilePairingPayload = pairingPayload
            self.isStartingMobileHost = false
          }
        }
      )
      await bridge.start()
      guard mobileHostAttemptID == attemptID, !Task.isCancelled else {
        bridge.stop()
        return
      }
      Task { await pushWorker?.drainAvailable() }
      mobileEventBridge = bridge
      mobilePairingAdapter = pairing
      mobileHostTask = Task { [weak self] in
        do {
          try await app.run()
        } catch is CancellationError {
          return
        } catch {
          await MainActor.run {
            guard let self, self.mobileHostAttemptID == attemptID else { return }
            self.mobileHostError =
              "Could not start the mobile host: \(error.localizedDescription). Check whether another Otto app is using this port, then retry."
            self.isStartingMobileHost = false
            self.mobileHostEndpoint = nil
            self.mobilePairingPayload = nil
            self.mobilePairingAdapter = nil
            self.mobileHostTask = nil
            self.mobileEventBridge?.stop()
            self.mobileEventBridge = nil
          }
        }
      }
      do {
        if let connector = try mobileManagedConnector(
          environment: environment,
          environmentID: environmentID,
          host: host
        ) {
          mobileManagedConnectorTask = Task { await connector.run() }
        }
        if let pairingClient = try mobileManagedPairingClient(environment: environment) {
          mobileManagedPairingClient = pairingClient
          do {
            managedRemoteSubscriptionStatus = try await pairingClient.subscriptionStatus()
            if managedRemoteSubscriptionStatus?.state == .active {
              managedMobilePairingPayload = try await pairingClient.createPayload()
            }
          } catch {
            errorMessage = "Remote pairing offer: \(error.localizedDescription)"
          }
        }
      } catch {
        errorMessage = "Remote host configuration: \(error.localizedDescription)"
      }
    } catch {
      guard mobileHostAttemptID == attemptID else { return }
      mobileHostError = "Mobile host configuration: \(error.localizedDescription)"
      isStartingMobileHost = false
      mobileHostEndpoint = nil
      mobilePairingPayload = nil
    }
  }

  private func mobileAPNsWorker(
    environment: [String: String],
    stateDirectory: URL,
    pairingStore: RemotePairingStore
  ) throws -> OttoAPNsDeliveryWorker? {
    let teamID = OttoEnvironment.value("APNS_TEAM_ID", in: environment)
    let keyID = OttoEnvironment.value("APNS_KEY_ID", in: environment)
    let topic = OttoEnvironment.value("APNS_TOPIC", in: environment)
    let keyFile = OttoEnvironment.value("APNS_PRIVATE_KEY_FILE", in: environment)
    guard [teamID, keyID, topic, keyFile].contains(where: { $0?.isEmpty == false }) else {
      return nil
    }
    guard let teamID, !teamID.isEmpty,
      let keyID, !keyID.isEmpty,
      let topic, !topic.isEmpty,
      let keyFile, !keyFile.isEmpty,
      let privateKey = try? String(contentsOfFile: keyFile, encoding: .utf8)
    else { throw OttoAPNsError.invalidConfiguration }
    let outbox = try OttoAPNsOutbox(
      stateDirectory: stateDirectory.appending(path: "apns", directoryHint: .isDirectory)
    )
    let client = OttoAPNsClient(
      configuration: OttoAPNsConfiguration(
        teamID: teamID,
        keyID: keyID,
        topic: topic,
        privateKeyPEM: privateKey
      ))
    return OttoAPNsDeliveryWorker(outbox: outbox, pairing: pairingStore, client: client)
  }

  private func mobileManagedConnector(
    environment: [String: String],
    environmentID: UUID,
    host: OttoHostRuntime
  ) throws -> ManagedRemoteHostConnector? {
    let controlPlane = OttoEnvironment.value("REMOTE_CONTROL_PLANE_URL", in: environment)
    let connectorCredential = OttoEnvironment.value("REMOTE_CONNECTOR_CREDENTIAL", in: environment)
    let signingKeyID = OttoEnvironment.value("REMOTE_SIGNING_KEY_ID", in: environment)
    let signingPublicKey = OttoEnvironment.value("REMOTE_SIGNING_PUBLIC_KEY", in: environment)
    let values = [controlPlane, connectorCredential, signingKeyID, signingPublicKey]
    guard values.contains(where: { $0?.isEmpty == false }) else { return nil }
    guard let controlPlane,
      let controlPlaneURL = URL(string: controlPlane),
      let connectorCredential, !connectorCredential.isEmpty,
      let signingKeyID, !signingKeyID.isEmpty,
      let signingPublicKey,
      let publicKey = Data(base64Encoded: signingPublicKey),
      publicKey.count == 32
    else { throw ManagedRemoteHostConnectorError.invalidConfiguration }
    let configuredCapabilities = OttoEnvironment.value("REMOTE_CAPABILITIES", in: environment)?
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let configuration = try ManagedRemoteHostConnectorConfiguration(
      controlPlaneURL: controlPlaneURL,
      environmentID: environmentID,
      connectorCredential: connectorCredential,
      trustedTicketKeys: [signingKeyID: publicKey],
      hostVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
      capabilities: configuredCapabilities
        ?? ["threads", "runs", "approvals", "attachments", "diagnostics"]
    )
    return ManagedRemoteHostConnector(configuration: configuration) { request, claims in
      let scopes = Set(claims.scopes.compactMap(OttoRPCScope.init(rawValue:)))
      return await host.handle(
        request,
        client: OttoHostClientContext(deviceID: claims.deviceID, scopes: scopes)
      )
    }
  }

  private func mobileManagedPairingClient(
    environment: [String: String]
  ) throws -> ManagedRemotePairingClient? {
    let controlPlane = OttoEnvironment.value("REMOTE_CONTROL_PLANE_URL", in: environment)
    let accountID = OttoEnvironment.value("REMOTE_ACCOUNT_ID", in: environment)
    let accountCredential = OttoEnvironment.value("REMOTE_ACCOUNT_CREDENTIAL", in: environment)
    let values = [controlPlane, accountID, accountCredential]
    guard values.contains(where: { $0?.isEmpty == false }) else { return nil }
    guard let controlPlane,
      let controlPlaneURL = URL(string: controlPlane),
      let accountID,
      let parsedAccountID = UUID(uuidString: accountID),
      let accountCredential, !accountCredential.isEmpty
    else { throw ManagedRemotePairingClientError.invalidConfiguration }
    let configuration = try ManagedRemotePairingClientConfiguration(
      controlPlaneURL: controlPlaneURL,
      accountID: parsedAccountID,
      accountCredential: accountCredential
    )
    return ManagedRemotePairingClient(configuration: configuration)
  }

  private func mobileEnvironmentID(in stateDirectory: URL) throws -> UUID {
    try FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let file = stateDirectory.appending(path: "environment-id")
    if let value = try? String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let id = UUID(uuidString: value)
    {
      return id
    }
    let id = UUID()
    try id.uuidString.lowercased().write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return id
  }

  public func refreshMobilePairingOffer(
    lifetime: TimeInterval = 300
  ) async throws -> OttoMobilePairingPayload {
    guard let mobilePairingAdapter else {
      throw OttoHostTransportError.invalidDeviceID
    }
    let payload = try await mobilePairingAdapter.createPayload(lifetime: lifetime)
    mobilePairingPayload = payload
    return payload
  }

  public func refreshManagedMobilePairingOffer(
    lifetime: TimeInterval = 300
  ) async throws -> ManagedRemotePairingPayload {
    guard let mobileManagedPairingClient else {
      throw ManagedRemotePairingClientError.invalidConfiguration
    }
    let payload = try await mobileManagedPairingClient.createPayload(lifetime: lifetime)
    managedMobilePairingPayload = payload
    return payload
  }

  public func refreshManagedRemoteSubscriptionStatus() async throws
    -> ManagedRemoteSubscriptionStatus
  {
    guard let mobileManagedPairingClient else {
      throw ManagedRemotePairingClientError.invalidConfiguration
    }
    let status = try await mobileManagedPairingClient.subscriptionStatus()
    managedRemoteSubscriptionStatus = status
    if status.state != .active { managedMobilePairingPayload = nil }
    return status
  }

  public func activateManagedRemoteSubscription(
    licenseKey: String
  ) async throws -> ManagedRemoteSubscriptionStatus {
    guard let mobileManagedPairingClient else {
      throw ManagedRemotePairingClientError.invalidConfiguration
    }
    let response = try await mobileManagedPairingClient.activateSubscription(
      licenseKey: licenseKey
    )
    try await secrets.set(response.deviceToken, for: "managed-remote-subscription-token")
    managedRemoteSubscriptionStatus = response.status
    if response.status.state == .active {
      managedMobilePairingPayload = try await mobileManagedPairingClient.createPayload()
    }
    return response.status
  }

  public func refreshManagedRemoteSubscription() async throws
    -> ManagedRemoteSubscriptionStatus
  {
    guard let mobileManagedPairingClient else {
      throw ManagedRemotePairingClientError.invalidConfiguration
    }
    guard let token = try await secrets.value(for: "managed-remote-subscription-token") else {
      throw CommercialError.missingDeviceCredential
    }
    let status = try await mobileManagedPairingClient.refreshSubscription(deviceToken: token)
    managedRemoteSubscriptionStatus = status
    if status.state == .active {
      managedMobilePairingPayload = try await mobileManagedPairingClient.createPayload()
    } else {
      managedMobilePairingPayload = nil
    }
    return status
  }

  public var managedMobilePairingIsConfigured: Bool {
    mobileManagedPairingClient != nil
  }

  private func mobileAdvertisedBaseURL(
    environment: [String: String],
    configuration: OttoHostTransportConfiguration
  ) throws -> URL {
    try configuration.advertisedBaseURL(
      override: OttoEnvironment.value("MOBILE_HOST_PUBLIC_URL", in: environment)
    )
  }

  private func mobileHostIdentityMaterial(in stateDirectory: URL) throws -> String {
    let file = stateDirectory.appending(path: "host-identity")
    if let value = try? String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      value.utf8.count >= 32
    {
      return value
    }
    let value = RemoteTokenGenerator.generate()
    try value.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return value
  }
}

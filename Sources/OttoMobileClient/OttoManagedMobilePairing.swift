import Foundation
import OttoCommercial

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

#if canImport(Security)
  import Security
#endif

public enum OttoManagedMobilePairingError: Error, LocalizedError, Equatable, Sendable {
  case expired
  case invalidResponse
  case subscriptionRequired
  case httpStatus(Int)
  case keychain(Int32)
  case keychainUnavailable

  public var errorDescription: String? {
    switch self {
    case .expired:
      "That managed Otto pairing code expired. Ask the Mac to create a new one."
    case .invalidResponse:
      "The Otto control plane returned invalid pairing details."
    case .subscriptionRequired:
      "Otto Remote needs an active subscription on the paired Mac. Local and Tailscale pairing remain available."
    case .httpStatus(let status):
      "The Otto control plane rejected pairing (HTTP \(status))."
    case .keychain(let status):
      "The managed-device credential could not be saved (\(status))."
    case .keychainUnavailable:
      "Secure credential storage is unavailable on this device."
    }
  }
}

public typealias OttoManagedMobilePairingPayload = ManagedRemotePairingPayload

public protocol OttoManagedMobileDeviceRecordStoring: Sendable {
  func save(_ record: OttoManagedMobileDeviceRecord) async throws
  func records() async throws -> [OttoManagedMobileDeviceRecord]
  func delete(deviceID: UUID) async throws
}

public actor OttoManagedMobileKeychainStore: OttoManagedMobileDeviceRecordStoring {
  public static let defaultService = "io.openotto.mobile.managed-pairing"
  /// Pairings saved before the Muse → Otto rename. Read (and copied forward) when the new
  /// service is empty; never deleted by migration. Keychain items belong to the app that wrote
  /// them, so this only helps builds that share the old keychain access group.
  public static let legacyService = "app.muse.mobile.managed-pairing"
  private let service: String
  private let legacyService: String?

  public init(
    service: String = defaultService,
    legacyService: String? = OttoManagedMobileKeychainStore.legacyService
  ) {
    self.service = service
    self.legacyService = service == Self.defaultService ? legacyService : nil
  }

  public func save(_ record: OttoManagedMobileDeviceRecord) throws {
    #if canImport(Security)
      let data = try JSONEncoder.commercial.encode(record)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: record.deviceID.uuidString.lowercased(),
      ]
      let attributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if update == errSecItemNotFound {
        var item = query
        for (key, value) in attributes {
          item[key] = value
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
          throw OttoManagedMobilePairingError.keychain(status)
        }
      } else if update != errSecSuccess {
        throw OttoManagedMobilePairingError.keychain(update)
      }
    #else
      throw OttoManagedMobilePairingError.keychainUnavailable
    #endif
  }

  public func records() throws -> [OttoManagedMobileDeviceRecord] {
    let current = try read(service: service)
    guard current.isEmpty, let legacyService else { return current }
    let legacy = (try? read(service: legacyService)) ?? []
    for record in legacy { try? save(record) }
    return legacy
  }

  private func read(service: String) throws -> [OttoManagedMobileDeviceRecord] {
    #if canImport(Security)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
      ]
      var value: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &value)
      if status == errSecItemNotFound { return [] }
      guard status == errSecSuccess else {
        throw OttoManagedMobilePairingError.keychain(status)
      }
      let values: [Data]
      if let data = value as? Data {
        values = [data]
      } else {
        values = (value as? [Data]) ?? []
      }
      return try values.map {
        try JSONDecoder.commercial.decode(OttoManagedMobileDeviceRecord.self, from: $0)
      }.sorted { $0.registeredAt > $1.registeredAt }
    #else
      throw OttoManagedMobilePairingError.keychainUnavailable
    #endif
  }

  public func delete(deviceID: UUID) throws {
    try delete(deviceID: deviceID, service: service)
    // An explicit unpair must not come back from the pre-rename copy.
    if let legacyService { try? delete(deviceID: deviceID, service: legacyService) }
  }

  private func delete(deviceID: UUID, service: String) throws {
    #if canImport(Security)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: deviceID.uuidString.lowercased(),
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw OttoManagedMobilePairingError.keychain(status)
      }
    #else
      throw OttoManagedMobilePairingError.keychainUnavailable
    #endif
  }
}

public actor OttoManagedMobilePairingClient {
  private let session: URLSession
  private let store: any OttoManagedMobileDeviceRecordStoring

  public init(
    session: URLSession = .shared,
    store: any OttoManagedMobileDeviceRecordStoring = OttoManagedMobileKeychainStore()
  ) {
    self.session = session
    self.store = store
  }

  public func pair(
    payload: OttoManagedMobilePairingPayload,
    deviceName: String,
    now: Date = .now
  ) async throws -> OttoManagedMobileDeviceRecord {
    guard payload.expiresAt > now else { throw OttoManagedMobilePairingError.expired }
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let input = ManagedPairingExchangeRequest(
      offerID: payload.offerID,
      secret: payload.secret,
      deviceName: deviceName,
      devicePublicKey: publicKey
    )
    var request = URLRequest(
      url: payload.controlPlaneURL.appending(path: "v1/managed/pairing-offers/exchange")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder.commercial.encode(input)
    let (data, response) = try await session.data(for: request)
    if response.statusCode == 402 { throw OttoManagedMobilePairingError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw OttoManagedMobilePairingError.httpStatus(response.statusCode)
    }
    guard
      let registration = try? JSONDecoder.commercial.decode(
        ManagedDeviceRegistration.self,
        from: data
      ),
      registration.device.kind == .iPhone,
      registration.device.publicKey == publicKey,
      registration.credential.utf8.count >= 32,
      registration.credential.utf8.count <= 1_024
    else { throw OttoManagedMobilePairingError.invalidResponse }

    let record = try OttoManagedMobileDeviceRecord(
      controlPlaneURL: payload.controlPlaneURL,
      accountID: registration.device.accountID,
      deviceID: registration.device.id,
      credential: registration.credential,
      devicePrivateKey: privateKey.rawRepresentation,
      registeredAt: now
    )
    do {
      _ = try await OttoManagedMobileControlPlaneClient(
        record: record,
        session: session
      ).environments()
    } catch let error as OttoManagedMobilePairingError {
      throw error
    } catch {
      throw OttoManagedMobilePairingError.invalidResponse
    }
    try await store.save(record)
    return record
  }
}

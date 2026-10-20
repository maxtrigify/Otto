import Foundation
import OttoRPCContracts

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(Security)
  import Security
#endif

public enum OttoMobilePairingError: Error, LocalizedError, Equatable, Sendable {
  case expired
  case invalidResponse
  case httpStatus(Int)
  case insecureEndpoint
  case hostVerificationFailed
  case keychain(Int32)
  case keychainUnavailable

  public var errorDescription: String? {
    switch self {
    case .expired: "That pairing code expired. Ask the Mac to create a new one."
    case .invalidResponse: "The Mac returned pairing details that did not match the QR code."
    case .httpStatus(let status): "The Mac rejected pairing (HTTP \(status))."
    case .insecureEndpoint:
      "That Mac address is not secure. Pair through HTTPS or local loopback development."
    case .hostVerificationFailed:
      "The paired Mac could not be verified at the address it advertised."
    case .keychain(let status): "The paired-device credential could not be saved (\(status))."
    case .keychainUnavailable: "Secure credential storage is unavailable on this device."
    }
  }
}

public struct OttoMobilePairingRecord: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { environmentID }
  public var environmentID: UUID
  public var environmentName: String
  public var baseURL: URL
  public var fingerprint: String
  public var deviceID: UUID
  public var credential: String
  public var devicePrivateKey: Data
  public var scopes: Set<OttoRPCScope>
  public var pairedAt: Date

  public init(
    environmentID: UUID,
    environmentName: String,
    baseURL: URL,
    fingerprint: String,
    deviceID: UUID,
    credential: String,
    devicePrivateKey: Data,
    scopes: Set<OttoRPCScope>,
    pairedAt: Date = .now
  ) {
    self.environmentID = environmentID
    self.environmentName = environmentName
    self.baseURL = baseURL
    self.fingerprint = fingerprint
    self.deviceID = deviceID
    self.credential = credential
    self.devicePrivateKey = devicePrivateKey
    self.scopes = scopes
    self.pairedAt = pairedAt
  }

  public var connectionConfiguration: OttoMobileConnectionConfiguration {
    OttoMobileConnectionConfiguration(
      baseURL: baseURL,
      token: credential,
      deviceID: deviceID
    )
  }
}

public protocol OttoMobilePairingRecordStoring: Sendable {
  func save(_ record: OttoMobilePairingRecord) async throws
  func records() async throws -> [OttoMobilePairingRecord]
  func delete(environmentID: UUID) async throws
}

public actor OttoMobileKeychainPairingStore: OttoMobilePairingRecordStoring {
  public static let defaultService = "io.openotto.mobile.pairing"
  /// Pairings saved before the Muse → Otto rename. Read (and copied forward) when the new
  /// service is empty; never deleted by migration. Keychain items belong to the app that wrote
  /// them, so this only helps builds that share the old keychain access group.
  public static let legacyService = "app.muse.mobile.pairing"
  private let service: String
  private let legacyService: String?

  public init(
    service: String = defaultService,
    legacyService: String? = OttoMobileKeychainPairingStore.legacyService
  ) {
    self.service = service
    self.legacyService = service == Self.defaultService ? legacyService : nil
  }

  public func save(_ record: OttoMobilePairingRecord) throws {
    #if canImport(Security)
      let data = try OttoRPCCodec.encoder.encode(record)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: record.environmentID.uuidString.lowercased(),
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
        guard status == errSecSuccess else { throw OttoMobilePairingError.keychain(status) }
      } else if update != errSecSuccess {
        throw OttoMobilePairingError.keychain(update)
      }
    #else
      throw OttoMobilePairingError.keychainUnavailable
    #endif
  }

  public func records() throws -> [OttoMobilePairingRecord] {
    let current = try read(service: service)
    guard current.isEmpty, let legacyService else { return current }
    let legacy = (try? read(service: legacyService)) ?? []
    for record in legacy { try? save(record) }
    return legacy
  }

  private func read(service: String) throws -> [OttoMobilePairingRecord] {
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
      guard status == errSecSuccess else { throw OttoMobilePairingError.keychain(status) }
      let values: [Data]
      if let data = value as? Data {
        values = [data]
      } else {
        values = (value as? [Data]) ?? []
      }
      return try values.map {
        try OttoRPCCodec.decoder.decode(OttoMobilePairingRecord.self, from: $0)
      }.sorted { $0.pairedAt > $1.pairedAt }
    #else
      throw OttoMobilePairingError.keychainUnavailable
    #endif
  }

  public func delete(environmentID: UUID) throws {
    try delete(environmentID: environmentID, service: service)
    // An explicit unpair must not come back from the pre-rename copy.
    if let legacyService { try? delete(environmentID: environmentID, service: legacyService) }
  }

  private func delete(environmentID: UUID, service: String) throws {
    #if canImport(Security)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: environmentID.uuidString.lowercased(),
      ]
      let status = SecItemDelete(query as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw OttoMobilePairingError.keychain(status)
      }
    #else
      throw OttoMobilePairingError.keychainUnavailable
    #endif
  }
}

public actor OttoMobilePairingClient {
  private let session: URLSession
  private let store: any OttoMobilePairingRecordStoring

  public init(
    session: URLSession = .shared,
    store: any OttoMobilePairingRecordStoring = OttoMobileKeychainPairingStore()
  ) {
    self.session = session
    self.store = store
  }

  public func pair(
    payload: OttoMobilePairingPayload,
    deviceName: String,
    now: Date = .now
  ) async throws -> OttoMobilePairingRecord {
    guard payload.expiresAt > now else { throw OttoMobilePairingError.expired }
    guard Self.isSafeEndpoint(payload.baseURL) else {
      throw OttoMobilePairingError.insecureEndpoint
    }
    let privateKey = Curve25519.Signing.PrivateKey()
    let input = OttoMobilePairingExchangeInput(
      offerID: payload.offerID,
      code: payload.code,
      deviceName: deviceName,
      devicePublicKey: privateKey.publicKey.rawRepresentation.base64EncodedString()
    )
    var request = URLRequest(url: payload.baseURL.appending(path: "v1/pairing/exchange"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try OttoRPCCodec.encoder.encode(input)
    let (data, http) = try await session.data(for: request)
    guard (200..<300).contains(http.statusCode) else {
      throw OttoMobilePairingError.httpStatus(http.statusCode)
    }
    let output = try OttoRPCCodec.decoder.decode(
      OttoMobilePairingExchangeOutput.self,
      from: data
    )
    guard output.environmentID == payload.environmentID,
      output.environmentName == payload.environmentName,
      output.baseURL == payload.baseURL,
      output.fingerprint == payload.fingerprint,
      output.scopes.isSubset(of: payload.scopes),
      output.scopes.contains(.environmentRead),
      output.credential.utf8.count >= 32
    else { throw OttoMobilePairingError.invalidResponse }
    let record = OttoMobilePairingRecord(
      environmentID: output.environmentID,
      environmentName: output.environmentName,
      baseURL: output.baseURL,
      fingerprint: output.fingerprint,
      deviceID: output.deviceID,
      credential: output.credential,
      devicePrivateKey: privateKey.rawRepresentation,
      scopes: output.scopes,
      pairedAt: now
    )
    do {
      let capabilities = try await OttoMobileConnection(
        configuration: record.connectionConfiguration,
        session: session
      ).capabilities()
      guard capabilities.environment.id == record.environmentID,
        capabilities.supportedProtocolVersions.contains(OttoRPCProtocol.currentVersion)
      else { throw OttoMobilePairingError.invalidResponse }
    } catch let error as OttoMobilePairingError {
      throw error
    } catch {
      throw OttoMobilePairingError.hostVerificationFailed
    }
    try await store.save(record)
    return record
  }

  private static func isSafeEndpoint(_ url: URL) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let hostname = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil
    else { return false }
    let loopback = hostname == "127.0.0.1" || hostname == "::1" || hostname == "localhost"
    return scheme == "https" || (scheme == "http" && loopback)
  }
}

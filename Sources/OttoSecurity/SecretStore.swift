import Foundation
import Security

public protocol SecretStore: Sendable {
  func set(_ value: String, for key: String) async throws
  func value(for key: String) async throws -> String?
  func delete(_ key: String) async throws
}

public enum SecretStoreError: Error, LocalizedError, Sendable {
  case keychain(OSStatus)
  case invalidEncoding
  case storageUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .keychain(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    case .invalidEncoding: "Secret was not valid UTF-8"
    case .storageUnavailable(let reason): "Secret storage unavailable: \(reason)"
    }
  }
}

/// Debug builds are signed ad-hoc or with a local self-signed certificate that has no Apple
/// Team ID, so the login keychain's partition list pins access to the exact build hash and
/// macOS demands the keychain password again after every rebuild. Development builds therefore
/// store secrets in a user-only file instead of the keychain; release builds, signed with a
/// stable Apple-issued identity, keep using the keychain.
///
/// Known Otto services also read their pre-rename `app.muse.*` service on a miss and copy the
/// value forward (see `LegacyFallbackSecretStore`).
public func makeDefaultSecretStore(service: String = OttoSecretService.credentials)
  -> any SecretStore
{
  #if DEBUG
    let primary = DevelopmentFileSecretStore(service: service)
    guard let legacy = OttoSecretService.legacyService(for: service) else { return primary }
    return LegacyFallbackSecretStore(
      primary: primary, legacy: DevelopmentFileSecretStore(service: legacy))
  #else
    makeKeychainSecretStore(service: service)
  #endif
}

/// A keychain store for `service` that lazily migrates items from its pre-rename service.
public func makeKeychainSecretStore(service: String) -> any SecretStore {
  let primary = KeychainSecretStore(service: service)
  guard let legacy = OttoSecretService.legacyService(for: service) else { return primary }
  return LegacyFallbackSecretStore(primary: primary, legacy: KeychainSecretStore(service: legacy))
}

/// Keychain service names. Items written before the rename live under the `app.muse.*` names
/// and are copied forward on first read; the legacy items are left in place.
public enum OttoSecretService {
  public static let credentials = "io.openotto.credentials"
  public static let licensing = "io.openotto.licensing"
  public static let accountAccess = "io.openotto.account-access"
  public static let websitePasswords = "io.openotto.website-passwords"
  public static let boat = "io.openotto.boat"
  public static let appConnections = "io.openotto.app-connections"
  public static let messaging = "io.openotto.messaging"
  public static let privatePhone = "io.openotto.private-phone"

  public static let legacyServices: [String: String] = [
    credentials: "app.muse.credentials",
    licensing: "app.muse.licensing",
    accountAccess: "app.muse.account-access",
    websitePasswords: "app.muse.website-passwords",
    boat: "app.muse.boat",
    appConnections: "app.muse.app-connections",
    messaging: "app.muse.messaging",
    privatePhone: "app.muse.private-phone",
  ]

  /// The pre-rename service for a current one; also maps any other `io.openotto.` name to its
  /// `app.muse.` twin so tests and tools that pass custom services keep the same behaviour.
  public static func legacyService(for service: String) -> String? {
    if let known = legacyServices[service] { return known }
    guard service.hasPrefix("io.openotto.") else { return nil }
    return "app.muse." + service.dropFirst("io.openotto.".count)
  }
}

/// Reads `primary` first; on a miss reads `legacy`, writes the value into `primary` and returns
/// it, so each secret migrates the first time Otto needs it. Legacy items are never removed by
/// migration. An explicit `delete` removes both copies so a signed-out credential cannot be
/// resurrected from the legacy service on the next read.
public actor LegacyFallbackSecretStore: SecretStore {
  private let primary: any SecretStore
  private let legacy: any SecretStore

  public init(primary: any SecretStore, legacy: any SecretStore) {
    self.primary = primary
    self.legacy = legacy
  }

  public func set(_ value: String, for key: String) async throws {
    try await primary.set(value, for: key)
  }

  public func value(for key: String) async throws -> String? {
    if let value = try await primary.value(for: key) { return value }
    guard let value = try? await legacy.value(for: key) else { return nil }
    try? await primary.set(value, for: key)
    return value
  }

  public func delete(_ key: String) async throws {
    try await primary.delete(key)
    try? await legacy.delete(key)
  }
}

public actor KeychainSecretStore: SecretStore {
  private let service: String

  public init(service: String = OttoSecretService.credentials) {
    self.service = service
  }

  public func set(_ value: String, for key: String) async throws {
    let data = Data(value.utf8)
    let query = baseQuery(key)
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = query
      insertion[kSecValueData as String] = data
      let insertStatus = SecItemAdd(insertion as CFDictionary, nil)
      guard insertStatus == errSecSuccess else { throw SecretStoreError.keychain(insertStatus) }
    } else if status != errSecSuccess {
      throw SecretStoreError.keychain(status)
    }
  }

  public func value(for key: String) async throws -> String? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw SecretStoreError.invalidEncoding
    }
    return value
  }

  public func delete(_ key: String) async throws {
    let status = SecItemDelete(baseQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError.keychain(status)
    }
  }

  private func baseQuery(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
  }
}

/// File-backed store for development builds: `~/Library/Application Support/Otto/dev-secrets.json`,
/// readable only by the current user (0600). Existing keychain secrets are imported at most once
/// per key — a denied keychain prompt is recorded so it is never shown again; the secret is then
/// simply absent until re-entered in settings.
public actor DevelopmentFileSecretStore: SecretStore {
  private struct Contents: Codable {
    var secrets: [String: [String: String]] = [:]
    var keychainImportAttempted: [String: [String]] = [:]
  }

  private let service: String
  private let fileURL: URL
  private let legacyKeychain: KeychainSecretStore

  public init(service: String = OttoSecretService.credentials) {
    self.service = service
    self.legacyKeychain = KeychainSecretStore(service: service)
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    self.fileURL = support.appendingPathComponent("Otto/dev-secrets.json")
  }

  public func set(_ value: String, for key: String) async throws {
    var contents = load()
    contents.secrets[service, default: [:]][key] = value
    markImportAttempted(&contents, key: key)
    try save(contents)
  }

  public func value(for key: String) async throws -> String? {
    var contents = load()
    if let value = contents.secrets[service]?[key] { return value }
    if contents.keychainImportAttempted[service]?.contains(key) ?? false { return nil }
    return try await importFromKeychain(key: key, contents: &contents)
  }

  public func delete(_ key: String) async throws {
    var contents = load()
    contents.secrets[service]?[key] = nil
    markImportAttempted(&contents, key: key)
    try save(contents)
    try? await legacyKeychain.delete(key)
  }

  private func importFromKeychain(key: String, contents: inout Contents) async throws -> String? {
    markImportAttempted(&contents, key: key)
    let migrated = try? await legacyKeychain.value(for: key)
    if let migrated {
      contents.secrets[service, default: [:]][key] = migrated
    }
    try save(contents)
    if migrated != nil {
      try? await legacyKeychain.delete(key)
    }
    return migrated
  }

  private func markImportAttempted(_ contents: inout Contents, key: String) {
    if !(contents.keychainImportAttempted[service]?.contains(key) ?? false) {
      contents.keychainImportAttempted[service, default: []].append(key)
    }
  }

  private func load() -> Contents {
    guard let data = try? Data(contentsOf: fileURL),
      let contents = try? JSONDecoder().decode(Contents.self, from: data)
    else { return Contents() }
    return contents
  }

  private func save(_ contents: Contents) throws {
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(contents)
    try data.write(to: fileURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }
}

public actor InMemorySecretStore: SecretStore {
  private var values: [String: String] = [:]
  public init() {}

  public func set(_ value: String, for key: String) async throws { values[key] = value }
  public func value(for key: String) async throws -> String? { values[key] }
  public func delete(_ key: String) async throws { values[key] = nil }
}

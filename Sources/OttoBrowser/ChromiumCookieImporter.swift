import CommonCrypto
import CryptoKit
import Foundation
import SQLite3
import Security

/// A sign-in cookie read from another browser, ready to hand to WebKit.
public struct ImportedBrowserCookie: Equatable, Sendable {
  public enum SameSite: Sendable { case unspecified, none, lax, strict }

  public var name: String
  public var value: String
  /// Chromium's `host_key`: a leading dot marks a cookie shared with subdomains.
  public var domain: String
  public var path: String
  /// `nil` for session cookies.
  public var expires: Date?
  public var isSecure: Bool
  public var isHTTPOnly: Bool
  public var sameSite: SameSite

  public init(
    name: String, value: String, domain: String, path: String, expires: Date?,
    isSecure: Bool, isHTTPOnly: Bool, sameSite: SameSite
  ) {
    self.name = name
    self.value = value
    self.domain = domain
    self.path = path
    self.expires = expires
    self.isSecure = isSecure
    self.isHTTPOnly = isHTTPOnly
    self.sameSite = sameSite
  }

  /// Session cookies would vanish when Otto quits, which signs people out of most sites. Chromium
  /// browsers restore them on relaunch, so imported ones are kept for `sessionLifetime`.
  public func httpCookie(sessionLifetime: TimeInterval = 30 * 24 * 60 * 60, now: Date = Date())
    -> HTTPCookie?
  {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path.isEmpty ? "/" : path,
      .expires: expires ?? now.addingTimeInterval(sessionLifetime),
    ]
    if isSecure { properties[.secure] = "TRUE" }
    if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    switch sameSite {
    case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
    case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
    case .none, .unspecified: break
    }
    return HTTPCookie(properties: properties)
  }
}

public enum ChromiumCookieImportError: Error, LocalizedError, Equatable {
  case keyUnavailable(String)
  case unreadable(String)

  public var errorDescription: String? {
    switch self {
    case .keyUnavailable(let browser):
      "Otto could not unlock \(browser) sign-ins. Choose Always Allow when macOS asks."
    case .unreadable(let browser): "Otto could not read \(browser) sign-ins."
    }
  }
}

/// Reads cookies from a Chromium profile (Chrome, Dia, Arc, Brave, Edge, …).
///
/// Chromium encrypts cookie values on macOS with AES-128-CBC. The key is derived from a random
/// password kept in the login Keychain as "<Browser> Safe Storage", so reading it shows the
/// standard macOS prompt; Otto never sees or stores the user's own password.
public enum ChromiumCookieImporter {
  /// Reads the browser's Safe Storage password. Blocks while macOS asks the user for access, so
  /// call this off the main thread.
  public static func safeStoragePassword(service: String, browser: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data,
      let password = String(data: data, encoding: .utf8)
    else { throw ChromiumCookieImportError.keyUnavailable(browser) }
    return password
  }

  public static func derivedKey(password: String) -> Data {
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    _ = password.withCString { passwordPointer in
      CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        passwordPointer, strlen(passwordPointer),
        salt, salt.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
        1003,
        &key, key.count
      )
    }
    return Data(key)
  }

  /// Decrypts one `encrypted_value`. Databases at schema version 24 or later prefix the plaintext
  /// with SHA-256 of the host, which binds the value to its domain.
  public static func decrypt(
    _ encrypted: Data, key: Data, hostKey: String, databaseVersion: Int
  ) -> String? {
    guard encrypted.count > 3, encrypted.prefix(3) == Data("v10".utf8) else { return nil }
    let ciphertext = encrypted.dropFirst(3)
    guard let plaintext = crypt(CCOperation(kCCDecrypt), ciphertext, key: key) else { return nil }
    var value = plaintext
    if databaseVersion >= 24 {
      let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
      guard value.count >= digest.count, value.prefix(digest.count) == digest else { return nil }
      value = value.dropFirst(digest.count)
    }
    return String(data: value, encoding: .utf8)
  }

  /// The inverse of `decrypt`, used by tests to build fixture databases.
  public static func encrypt(
    _ value: String, key: Data, hostKey: String, databaseVersion: Int
  ) -> Data? {
    var plaintext = Data()
    if databaseVersion >= 24 { plaintext += Data(SHA256.hash(data: Data(hostKey.utf8))) }
    plaintext += Data(value.utf8)
    guard let ciphertext = crypt(CCOperation(kCCEncrypt), plaintext, key: key) else { return nil }
    return Data("v10".utf8) + ciphertext
  }

  /// Reads every unexpired cookie. The database is copied first because the browser may hold it
  /// open and locked.
  public static func readCookies(
    databaseURL: URL, password: String, browser: String, now: Date = Date()
  ) throws -> [ImportedBrowserCookie] {
    let fileManager = FileManager.default
    let scratch = fileManager.temporaryDirectory.appending(
      path: "otto-cookie-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }
    let copy = scratch.appending(path: "Cookies")
    do {
      try fileManager.copyItem(at: databaseURL, to: copy)
    } catch {
      throw ChromiumCookieImportError.unreadable(browser)
    }
    for suffix in ["-wal", "-journal"] {
      let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
      if fileManager.fileExists(atPath: sidecar.path) {
        try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
      }
    }

    var database: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else {
      if let database { sqlite3_close(database) }
      throw ChromiumCookieImportError.unreadable(browser)
    }
    defer { sqlite3_close(database) }

    let version = metaVersion(database)
    let key = derivedKey(password: password)
    let sql = """
      SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly,
        has_expires, samesite
      FROM cookies
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw ChromiumCookieImportError.unreadable(browser)
    }
    defer { sqlite3_finalize(statement) }

    var cookies: [ImportedBrowserCookie] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let host = text(statement, 0)
      let name = text(statement, 1)
      guard !host.isEmpty, !name.isEmpty else { continue }
      var value = text(statement, 2)
      if value.isEmpty {
        let encrypted = blob(statement, 3)
        guard !encrypted.isEmpty else { continue }
        guard
          let decrypted = decrypt(encrypted, key: key, hostKey: host, databaseVersion: version)
        else { continue }
        value = decrypted
      }
      var expires: Date?
      if sqlite3_column_int(statement, 8) != 0 {
        expires = chromiumDate(sqlite3_column_int64(statement, 5))
        if let expires, expires <= now { continue }
      }
      let sameSite: ImportedBrowserCookie.SameSite =
        switch sqlite3_column_int(statement, 9) {
        case 0: .none
        case 1: .lax
        case 2: .strict
        default: .unspecified
        }
      cookies.append(
        ImportedBrowserCookie(
          name: name,
          value: value,
          domain: host,
          path: text(statement, 4),
          expires: expires,
          isSecure: sqlite3_column_int(statement, 6) != 0,
          isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
          sameSite: sameSite
        ))
    }
    return cookies
  }

  /// Chromium stores times as microseconds since 1 January 1601 UTC.
  static func chromiumDate(_ microseconds: Int64) -> Date {
    let secondsFrom1601To1970: Double = 11_644_473_600
    return Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - secondsFrom1601To1970)
  }

  private static func crypt(_ operation: CCOperation, _ input: Data, key: Data) -> Data? {
    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: input.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var written = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
      input.withUnsafeBytes { inputBytes in
        key.withUnsafeBytes { keyBytes in
          CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            keyBytes.baseAddress, key.count, iv,
            inputBytes.baseAddress, input.count,
            outputBytes.baseAddress, outputCapacity, &written
          )
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    return output.prefix(written)
  }

  private static func metaVersion(_ database: OpaquePointer) -> Int {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil)
        == SQLITE_OK
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
    return Int(text(statement, 0)) ?? 0
  }

  private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: pointer)
  }

  private static func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return Data() }
    return Data(bytes: pointer, count: count)
  }
}

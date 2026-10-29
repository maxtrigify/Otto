import CryptoKit
import Foundation
import OttoSecurity

/// Outgoing mail over SMTP. Sending is delegated to the system `curl`, which already speaks
/// implicit TLS (smtps) and STARTTLS, so Otto carries no SMTP protocol code of its own.
/// The password is kept in the secret store (the Keychain in release builds, the user-only dev
/// secrets file in development builds) and reaches curl through a 0600 config file in a 0700
/// directory that is deleted straight after the call; it never appears in argv.
public struct SMTPConfiguration: Codable, Equatable, Sendable {
  public enum Security: String, Codable, Sendable {
    /// Implicit TLS, usually port 465.
    case tls
    /// Plain connection upgraded with STARTTLS, usually port 587.
    case startTLS
  }
  public var host: String
  public var port: Int
  public var username: String
  public var fromAddress: String
  public var security: Security

  public init(
    host: String, port: Int, username: String, fromAddress: String, security: Security
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.fromAddress = fromAddress
    self.security = security
  }
}

public enum SMTPError: Error, LocalizedError, Equatable {
  case notConfigured
  case invalidField(String)
  case sendFailed(String)
  case checkFailed(String)
  case saveFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured: "SMTP is not set up. Add the server and password under Connectors."
    case .invalidField(let field): "\(field) is missing or contains line breaks."
    case .sendFailed(let detail): "SMTP send failed. \(detail)"
    case .checkFailed(let detail): "Could not reach the mail server. \(detail)"
    case .saveFailed(let detail): "Could not save SMTP settings. \(detail)"
    }
  }
}

public actor SMTPConnector {
  private let fileURL: URL
  private let secrets: any SecretStore
  private let passwordKey: String
  public private(set) var configuration: SMTPConfiguration?

  public init(
    workspacePath: String,
    // Development builds use the same user-only secrets file as other dev connectors; release
    // builds use the Keychain.
    secrets: any SecretStore = makeDefaultSecretStore(service: OttoSecretService.appConnections)
  ) {
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/smtp.json")
    self.secrets = secrets
    let digest = SHA256.hash(
      data: Data(URL(fileURLWithPath: workspacePath).standardizedFileURL.path.utf8))
    passwordKey = "smtp-" + digest.map { String(format: "%02x", $0) }.joined()
    configuration = try? WorkspaceJSONFile.load(
      SMTPConfiguration.self, from: fileURL, fileManager: .default)
  }

  public var isConfigured: Bool { configuration != nil }

  /// Saves the server settings and the password. The password is rejected if it contains a
  /// line break because the curl config format is line based.
  public func save(_ configuration: SMTPConfiguration, password: String) async throws {
    try Self.validate(configuration)
    guard !password.isEmpty, !password.contains(where: \.isNewline) else {
      throw SMTPError.invalidField("Password")
    }
    do {
      try await secrets.set(password, for: passwordKey)
    } catch {
      throw SMTPError.saveFailed("Password storage: \(error.localizedDescription)")
    }
    do {
      try WorkspaceJSONFile.save(configuration, to: fileURL, fileManager: .default)
    } catch {
      throw SMTPError.saveFailed(
        "Settings file \(fileURL.path): \(error.localizedDescription)")
    }
    self.configuration = configuration
  }

  public func disconnect() async throws {
    try await secrets.delete(passwordKey)
    try? FileManager.default.removeItem(at: fileURL)
    configuration = nil
  }

  /// Connects, authenticates and disconnects with the saved settings. No mail is sent.
  public func testConnection() async throws {
    guard let configuration else { throw SMTPError.notConfigured }
    guard let password = try await secrets.value(for: passwordKey) else {
      throw SMTPError.notConfigured
    }
    try await Self.withCurlLogin(username: configuration.username, password: password) {
      _, configURL in
      // NOOP makes curl log in and then ask the server to acknowledge, without sending mail.
      var arguments = [
        "--silent", "--show-error", "--max-time", "30",
        "--config", configURL.path,
        "--url", Self.serverURL(configuration),
        "--request", "NOOP",
      ]
      if configuration.security == .startTLS { arguments.append("--ssl-reqd") }
      let result = try await Self.runCurl(arguments)
      guard result.status == 0 else {
        throw SMTPError.checkFailed(String(result.stderr.prefix(200)))
      }
    }
  }

  /// Sends one plain-text message. Callers must have obtained Otto's confirmation first.
  public func send(to: String, subject: String, body: String) async throws {
    guard let configuration else { throw SMTPError.notConfigured }
    guard let password = try await secrets.value(for: passwordKey) else {
      throw SMTPError.notConfigured
    }
    guard Self.isBareAddress(to) else { throw SMTPError.invalidField("Recipient") }
    let message = try Self.message(
      from: configuration.fromAddress, to: to, subject: subject, body: body,
      date: .now, messageID: "<\(UUID().uuidString)@\(Self.domain(of: configuration.fromAddress))>")
    try await Self.deliver(
      message: message, recipient: to, configuration: configuration, password: password)
  }

  // MARK: Message construction

  /// Builds an RFC 5322 plain-text message. Recipient and header values are rejected when they
  /// contain CR or LF so a caller cannot inject extra headers or recipients.
  static func message(
    from: String, to: String, subject: String, body: String, date: Date, messageID: String
  ) throws -> String {
    for (name, value) in [("From", from), ("To", to), ("Subject", subject)] {
      guard !value.isEmpty, !value.contains(where: \.isNewline) else {
        throw SMTPError.invalidField(name)
      }
    }
    let encodedSubject =
      subject.allSatisfy(\.isASCII)
      ? subject
      : "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
    let normalizedBody =
      body
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\n", with: "\r\n")
    let headers = [
      "From: \(from)",
      "To: \(to)",
      "Subject: \(encodedSubject)",
      "Date: \(rfc2822(date))",
      "Message-ID: \(messageID)",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: 8bit",
    ]
    return headers.joined(separator: "\r\n") + "\r\n\r\n" + normalizedBody + "\r\n"
  }

  static func validate(_ configuration: SMTPConfiguration) throws {
    let fields = [
      ("Host", configuration.host), ("Username", configuration.username),
      ("From address", configuration.fromAddress),
    ]
    for (name, value) in fields where value.isEmpty || value.contains(where: \.isNewline) {
      throw SMTPError.invalidField(name)
    }
    // The host and sender go into curl's URL and envelope, so only plain values are accepted.
    guard isHostName(configuration.host) else { throw SMTPError.invalidField("Host") }
    guard isBareAddress(configuration.fromAddress) else {
      throw SMTPError.invalidField("From address")
    }
    guard (1...65535).contains(configuration.port) else { throw SMTPError.invalidField("Port") }
  }

  /// A DNS name or IPv4 address: letters, digits, dots and hyphens, at most 253 characters.
  static func isHostName(_ value: String) -> Bool {
    guard (1...253).contains(value.count), !value.hasPrefix("."), !value.hasPrefix("-") else {
      return false
    }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "." || $0 == "-"
    }
  }

  private static func domain(of address: String) -> String {
    let domain = address.split(separator: "@").last.map(String.init) ?? "localhost"
    return domain.contains(where: { $0 == " " || $0 == "<" }) ? "localhost" : domain
  }

  private static func rfc2822(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '+0000'"
    return formatter.string(from: date)
  }

  // MARK: Delivery

  /// A plain addr-spec: one @, no spaces, no angle brackets, no line breaks.
  static func isBareAddress(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
      && !value.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" })
  }

  private static func deliver(
    message: String, recipient: String, configuration: SMTPConfiguration, password: String
  ) async throws {
    try await withCurlLogin(username: configuration.username, password: password) {
      directory, configURL in
      let messageURL = directory.appending(path: "message.eml")
      try Data(message.utf8).write(to: messageURL)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: messageURL.path)
      var arguments = [
        "--silent", "--show-error", "--max-time", "60",
        "--config", configURL.path,
        "--url", serverURL(configuration),
        "--mail-from", configuration.fromAddress,
        "--mail-rcpt", recipient,
        "--upload-file", messageURL.path,
      ]
      if configuration.security == .startTLS { arguments.append("--ssl-reqd") }
      let result = try await runCurl(arguments)
      guard result.status == 0 else {
        throw SMTPError.sendFailed(String(result.stderr.prefix(200)))
      }
    }
  }

  /// Runs `body` with a private 0700 directory holding a 0600 curl config for the login. The
  /// directory is removed afterwards, so the password never outlives the call.
  private static func withCurlLogin(
    username: String, password: String,
    _ body: (_ directory: URL, _ configURL: URL) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-smtp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appending(path: "curl.conf")
    let config = "user = \"\(username.escapedForCurlConfig):\(password.escapedForCurlConfig)\"\n"
    try Data(config.utf8).write(to: configURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    try await body(directory, configURL)
  }

  private static func serverURL(_ configuration: SMTPConfiguration) -> String {
    let scheme = configuration.security == .tls ? "smtps" : "smtp"
    return "\(scheme)://\(configuration.host):\(configuration.port)"
  }

  private static func runCurl(_ arguments: [String]) async throws -> (status: Int32, stderr: String)
  {
    try await Task.detached(priority: .utility) {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
      process.arguments = arguments
      let errors = Pipe()
      process.standardError = errors
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      let data = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
  }
}

extension String {
  /// Escapes a value for a double-quoted curl config string.
  fileprivate var escapedForCurlConfig: String {
    replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
}

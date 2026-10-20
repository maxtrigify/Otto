import Crypto
import Foundation

public struct WebhookRoute: Codable, Sendable, Equatable {
  public var routineID: UUID
  public var slug: String
  public var enabled: Bool
  public init(routineID: UUID, slug: String, enabled: Bool) {
    self.routineID = routineID
    self.slug = slug
    self.enabled = enabled
  }
}

public struct WebhookEnvelope: Codable, Sendable, Equatable {
  public var slug: String
  public var headers: [String: String]
  public var body: String
  public var receivedAt: Date
  public var idempotencyKey: String
  public init(
    slug: String, headers: [String: String], body: String, receivedAt: Date,
    idempotencyKey: String
  ) {
    self.slug = slug
    self.headers = headers
    self.body = body
    self.receivedAt = receivedAt
    self.idempotencyKey = idempotencyKey
  }
}

public enum WebhookRejection: Error, LocalizedError, Equatable, Sendable {
  case notFound, missingSecret, oversized, invalidSignature, replayedTimestamp, rateLimited,
    duplicate
  public var errorDescription: String? {
    switch self {
    case .notFound: "Not found"
    case .missingSecret: "Webhook secret is unavailable"
    case .oversized: "Request body is too large"
    case .invalidSignature: "Signature verification failed"
    case .replayedTimestamp: "Timestamp is outside the replay window"
    case .rateLimited: "Rate limit exceeded"
    case .duplicate: "Duplicate delivery"
    }
  }
}

public enum WebhookSignatureVerifier {
  public static let maximumBodyBytes = 65_536
  public static let replayWindow: TimeInterval = 300

  public static func verify(
    body: Data, secret: String, signatureHeader: String?, timestampHeader: String?,
    now: Date = .now
  ) throws {
    guard body.count <= maximumBodyBytes else { throw WebhookRejection.oversized }
    guard !secret.isEmpty else { throw WebhookRejection.missingSecret }
    guard let raw = signatureHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    else { throw WebhookRejection.invalidSignature }
    let supplied = raw.replacingOccurrences(of: "sha256=", with: "")
      .replacingOccurrences(of: "v1=", with: "")
    let signed: Data
    if let timestampHeader {
      guard let seconds = TimeInterval(timestampHeader),
        abs(now.timeIntervalSince1970 - seconds) <= replayWindow
      else { throw WebhookRejection.replayedTimestamp }
      signed = Data("\(timestampHeader).".utf8) + body
    } else {
      signed = body
    }
    let expected = HMAC<SHA256>.authenticationCode(
      for: signed, using: SymmetricKey(data: Data(secret.utf8))
    )
    .map { String(format: "%02x", $0) }.joined()
    guard constantTimeEqual(expected, supplied.lowercased()) else {
      throw WebhookRejection.invalidSignature
    }
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    var difference = UInt8(truncatingIfNeeded: a.count ^ b.count)
    for index in 0..<max(a.count, b.count) {
      difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
    }
    return difference == 0
  }
}

public actor WebhookAdmission {
  private struct Window {
    var start: Date
    var count: Int
  }
  private var windows: [String: Window] = [:]
  private var seen: [String: Date] = [:]
  public init() {}

  public func admit(route: String, idempotencyKey: String, now: Date = .now) throws {
    var window = windows[route] ?? Window(start: now, count: 0)
    if now.timeIntervalSince(window.start) >= 60 { window = Window(start: now, count: 0) }
    guard window.count < 30 else { throw WebhookRejection.rateLimited }
    window.count += 1
    windows[route] = window
    seen = seen.filter { $0.value > now }
    let key = "\(route):\(idempotencyKey)"
    guard seen[key] == nil else { throw WebhookRejection.duplicate }
    seen[key] = now.addingTimeInterval(3_600)
  }
}

public enum WebhookConfiguration {
  public static func validateLoopbackHost(_ host: String) throws {
    guard host == "127.0.0.1" || host == "localhost" || host == "::1" else {
      throw WebhookRejection.notFound
    }
  }

  public static func idempotencyKey(slug: String, headers: [String: String], body: Data) -> String {
    if let value = headers["x-github-delivery"] ?? headers["svix-id"], !value.isEmpty {
      return value
    }
    let stableBody: Data
    if let object = try? JSONSerialization.jsonObject(with: body),
      JSONSerialization.isValidJSONObject(object),
      let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    {
      stableBody = canonical
    } else {
      stableBody = body
    }
    return SHA256.hash(data: Data("\(slug):".utf8) + stableBody)
      .map { String(format: "%02x", $0) }.joined()
  }
}

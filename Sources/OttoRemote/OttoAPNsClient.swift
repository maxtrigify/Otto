import Foundation
import OttoModels

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public struct OttoAPNsConfiguration: Sendable, Equatable {
  public var teamID: String
  public var keyID: String
  public var topic: String
  public var privateKeyPEM: String

  public init(teamID: String, keyID: String, topic: String, privateKeyPEM: String) {
    self.teamID = teamID
    self.keyID = keyID
    self.topic = topic
    self.privateKeyPEM = privateKeyPEM
  }
}

public struct OttoAPNsNotification: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { eventID }
  public var eventID: UUID
  public var threadID: UUID
  public var kind: RunEventNotification
  public var title: String
  public var body: String

  public init?(
    event: RunEvent,
    threadTitle: String
  ) {
    guard event.content.notification != .none else { return nil }
    eventID = event.id
    threadID = event.threadID
    kind = event.content.notification
    title =
      switch kind {
      case .completion: "\(threadTitle) finished"
      case .failure: "\(threadTitle) failed"
      case .needsUser: "\(threadTitle) needs you"
      case .approval: "\(threadTitle) needs approval"
      case .none: "Otto update"
      }
    let fallback =
      switch kind {
      case .completion: "Open Otto to review the result."
      case .failure: "Open Otto to inspect the failure and continue."
      case .needsUser: "Open Otto to answer and keep the run moving."
      case .approval: "Open Otto to review the requested action."
      case .none: ""
      }
    body = event.content.detail ?? fallback
  }
}

public struct OttoAPNsResponse: Equatable, Sendable {
  public var apnsID: String?
  public init(apnsID: String?) { self.apnsID = apnsID }
}

public enum OttoAPNsError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case deviceNotRegistered
  case httpStatus(Int, reason: String?)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "The APNs provider configuration is invalid."
    case .deviceNotRegistered: "The paired device has no APNs registration."
    case .httpStatus(let status, let reason):
      "APNs returned HTTP \(status)\(reason.map { ": \($0)" } ?? "")."
    case .invalidResponse: "APNs returned an invalid response."
    }
  }
}

public actor OttoAPNsClient {
  private let configuration: OttoAPNsConfiguration
  private let session: URLSession
  private var cachedProviderToken: (value: String, issuedAt: Date)?

  public init(
    configuration: OttoAPNsConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func send(
    _ notification: OttoAPNsNotification,
    to device: RemotePairedDevice,
    now: Date = .now
  ) async throws -> OttoAPNsResponse {
    guard let deviceToken = device.pushToken,
      let environment = device.pushEnvironment
    else { throw OttoAPNsError.deviceNotRegistered }
    let host =
      environment == .sandbox
      ? "api.sandbox.push.apple.com"
      : "api.push.apple.com"
    guard let url = URL(string: "https://\(host)/3/device/\(deviceToken)") else {
      throw OttoAPNsError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = try payload(notification)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("bearer \(try providerToken(now: now))", forHTTPHeaderField: "Authorization")
    request.setValue("alert", forHTTPHeaderField: "apns-push-type")
    request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
    request.setValue(notification.eventID.uuidString.lowercased(), forHTTPHeaderField: "apns-id")
    request.setValue(
      notification.eventID.uuidString.lowercased(), forHTTPHeaderField: "apns-collapse-id")
    request.setValue(
      notification.kind == .needsUser || notification.kind == .approval ? "10" : "5",
      forHTTPHeaderField: "apns-priority"
    )
    request.setValue(
      String(Int(now.addingTimeInterval(86_400).timeIntervalSince1970)),
      forHTTPHeaderField: "apns-expiration"
    )
    let (data, response) = try await session.data(for: request)
    let http = response
    guard http.statusCode == 200 else {
      let reason = (try? JSONDecoder().decode(APNsFailure.self, from: data))?.reason
      throw OttoAPNsError.httpStatus(http.statusCode, reason: reason)
    }
    return OttoAPNsResponse(apnsID: http.value(forHTTPHeaderField: "apns-id"))
  }

  private func providerToken(now: Date) throws -> String {
    if let cachedProviderToken,
      now.timeIntervalSince(cachedProviderToken.issuedAt) < 50 * 60
    {
      return cachedProviderToken.value
    }
    guard !configuration.teamID.isEmpty, !configuration.keyID.isEmpty,
      !configuration.topic.isEmpty
    else { throw OttoAPNsError.invalidConfiguration }
    let header = try JSONSerialization.data(
      withJSONObject: [
        "alg": "ES256", "kid": configuration.keyID,
      ], options: [.sortedKeys])
    let claims = try JSONSerialization.data(
      withJSONObject: [
        "iat": Int(now.timeIntervalSince1970), "iss": configuration.teamID,
      ], options: [.sortedKeys])
    let unsigned = "\(base64URL(header)).\(base64URL(claims))"
    let key = try P256.Signing.PrivateKey(pemRepresentation: configuration.privateKeyPEM)
    let signature = try key.signature(for: Data(unsigned.utf8))
    let value = "\(unsigned).\(base64URL(signature.rawRepresentation))"
    cachedProviderToken = (value, now)
    return value
  }

  private func payload(_ notification: OttoAPNsNotification) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "aps": [
          "alert": ["title": notification.title, "body": notification.body],
          "sound": "default",
          "thread-id": notification.threadID.uuidString.lowercased(),
        ],
        "event_id": notification.eventID.uuidString,
        "thread_id": notification.threadID.uuidString,
      ], options: [.sortedKeys])
  }

  private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

private struct APNsFailure: Decodable { var reason: String }

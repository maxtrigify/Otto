import Foundation
import OttoCommercial

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum ManagedRemotePairingClientError: Error, LocalizedError, Equatable, Sendable {
  case invalidConfiguration
  case subscriptionRequired
  case requestRejected(Int)
  case invalidResponse

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "Managed Remote Access is not configured for this Mac."
    case .subscriptionRequired:
      "An active Otto Remote subscription is required for hosted access. Local and Tailscale access are still available."
    case .requestRejected(let status):
      "The control plane rejected the pairing offer (HTTP \(status))."
    case .invalidResponse:
      "The control plane returned an invalid pairing offer."
    }
  }
}

public struct ManagedRemotePairingClientConfiguration: Sendable {
  public var controlPlaneURL: URL
  public var accountID: UUID
  public var accountCredential: String

  public init(
    controlPlaneURL: URL,
    accountID: UUID,
    accountCredential: String
  ) throws {
    guard let components = URLComponents(url: controlPlaneURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      !accountCredential.isEmpty,
      accountCredential.utf8.count <= 1_024,
      scheme == "https" || (scheme == "http" && Self.isLoopback(host))
    else { throw ManagedRemotePairingClientError.invalidConfiguration }
    self.controlPlaneURL = controlPlaneURL
    self.accountID = accountID
    self.accountCredential = accountCredential
  }

  private static func isLoopback(_ host: String) -> Bool {
    host == "127.0.0.1" || host == "::1" || host == "localhost"
  }
}

public actor ManagedRemotePairingClient {
  private let configuration: ManagedRemotePairingClientConfiguration
  private let session: URLSession
  private let now: @Sendable () -> Date

  public init(
    configuration: ManagedRemotePairingClientConfiguration,
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.configuration = configuration
    self.session = session
    self.now = now
  }

  public func createPayload(lifetime: TimeInterval = 300) async throws
    -> ManagedRemotePairingPayload
  {
    let input = ManagedPairingOfferRequest(
      accountID: configuration.accountID,
      lifetime: lifetime
    )
    var request = URLRequest(
      url: configuration.controlPlaneURL.appending(path: "v1/managed/pairing-offers")
    )
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Bearer \(configuration.accountCredential)",
      forHTTPHeaderField: "Authorization"
    )
    request.httpBody = try JSONEncoder.commercial.encode(input)
    let (data, response) = try await session.data(for: request)
    if response.statusCode == 402 { throw ManagedRemotePairingClientError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw ManagedRemotePairingClientError.requestRejected(response.statusCode)
    }
    guard let offer = try? JSONDecoder.commercial.decode(ManagedPairingOffer.self, from: data),
      offer.accountID == configuration.accountID,
      offer.expiresAt > now()
    else { throw ManagedRemotePairingClientError.invalidResponse }
    return try ManagedRemotePairingPayload(
      controlPlaneURL: configuration.controlPlaneURL,
      offerID: offer.id,
      secret: offer.secret,
      expiresAt: offer.expiresAt
    )
  }

  public func activateSubscription(
    licenseKey: String
  ) async throws -> ManagedRemoteSubscriptionActivationResponse {
    try await send(
      path: "v1/managed/subscription/activate",
      body: ManagedRemoteSubscriptionActivationRequest(
        accountID: configuration.accountID,
        licenseKey: licenseKey
      ),
      decoding: ManagedRemoteSubscriptionActivationResponse.self
    )
  }

  public func refreshSubscription(
    deviceToken: String
  ) async throws -> ManagedRemoteSubscriptionStatus {
    try await send(
      path: "v1/managed/subscription/refresh",
      body: ManagedRemoteSubscriptionRefreshRequest(
        accountID: configuration.accountID,
        deviceToken: deviceToken
      ),
      decoding: ManagedRemoteSubscriptionStatus.self
    )
  }

  public func subscriptionStatus() async throws -> ManagedRemoteSubscriptionStatus {
    var components = URLComponents(
      url: configuration.controlPlaneURL.appending(path: "v1/managed/subscription"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "account_id", value: configuration.accountID.uuidString)
    ]
    guard let url = components?.url else {
      throw ManagedRemotePairingClientError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    addAuthentication(to: &request)
    let (data, response) = try await session.data(for: request)
    return try decode(data, response: response, as: ManagedRemoteSubscriptionStatus.self)
  }

  private func send<Body: Encodable, Output: Decodable>(
    path: String,
    body: Body,
    decoding _: Output.Type
  ) async throws -> Output {
    var request = URLRequest(url: configuration.controlPlaneURL.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    addAuthentication(to: &request)
    request.httpBody = try JSONEncoder.commercial.encode(body)
    let (data, response) = try await session.data(for: request)
    return try decode(data, response: response, as: Output.self)
  }

  private func decode<Output: Decodable>(
    _ data: Data,
    response: HTTPURLResponse,
    as _: Output.Type
  ) throws -> Output {
    if response.statusCode == 402 { throw ManagedRemotePairingClientError.subscriptionRequired }
    guard (200..<300).contains(response.statusCode) else {
      throw ManagedRemotePairingClientError.requestRejected(response.statusCode)
    }
    guard let output = try? JSONDecoder.commercial.decode(Output.self, from: data) else {
      throw ManagedRemotePairingClientError.invalidResponse
    }
    return output
  }

  private func addAuthentication(to request: inout URLRequest) {
    request.setValue(
      "Bearer \(configuration.accountCredential)",
      forHTTPHeaderField: "Authorization"
    )
  }
}

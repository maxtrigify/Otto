import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public protocol CommercialTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: CommercialTransport {
  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request, delegate: nil)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CommercialError.invalidServerResponse(0)
    }
    return (data, httpResponse)
  }
}

public struct CommercialClient: Sendable {
  private let baseURL: URL
  private let transport: any CommercialTransport

  public init(baseURL: URL, transport: any CommercialTransport = URLSession.shared) throws {
    guard baseURL.scheme?.lowercased() == "https" else {
      throw CommercialError.insecureURL
    }
    self.baseURL = baseURL
    self.transport = transport
  }

  public func activate(_ activation: LicenseActivationRequest) async throws
    -> LicenseActivationResponse
  {
    try await request(path: "v1/licenses/activate", method: "POST", body: activation)
  }

  public func deactivate(deviceID: String, deviceToken: String) async throws {
    let _: EmptyResponse = try await request(
      path: "v1/licenses/deactivate",
      method: "POST",
      body: LicenseDeviceRequest(deviceID: deviceID),
      bearerToken: deviceToken
    )
  }

  public func entitlements(deviceID: String, deviceToken: String) async throws -> SignedDocument {
    try await request(
      path: "v1/licenses/entitlements?device_id=\(try encoded(deviceID))",
      method: "GET",
      body: Optional<LicenseDeviceRequest>.none,
      bearerToken: deviceToken
    )
  }

  public func refresh(deviceID: String, deviceToken: String) async throws -> SignedDocument {
    try await request(
      path: "v1/licenses/refresh",
      method: "POST",
      body: LicenseDeviceRequest(deviceID: deviceID),
      bearerToken: deviceToken
    )
  }

  public func updateManifest() async throws -> SignedDocument {
    // GitHub Pages advertises a ten-minute edge cache. A timestamped query prevents a newly
    // published release from remaining invisible across several of Otto's five-minute checks.
    let cacheBust = Int(Date().timeIntervalSince1970 * 1_000)
    let document: SignedDocument = try await request(
      path: "v1/updates/manifest?cache_bust=\(cacheBust)",
      method: "GET",
      body: Optional<LicenseDeviceRequest>.none,
      bypassCache: true
    )
    return document
  }

  private func request<Response: Decodable, Body: Encodable>(
    path: String,
    method: String,
    body: Body?,
    bearerToken: String? = nil,
    bypassCache: Bool = false
  ) async throws -> Response {
    guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
      throw CommercialError.invalidDocument
    }
    var request = URLRequest(url: url)
    if bypassCache {
      request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      request.setValue("no-cache", forHTTPHeaderField: "Pragma")
    }
    request.httpMethod = method
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let bearerToken {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    if let body {
      request.httpBody = try JSONEncoder.commercial.encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await transport.data(for: request)
    guard (200..<300).contains(response.statusCode) else {
      throw CommercialError.invalidServerResponse(response.statusCode)
    }
    if Response.self == EmptyResponse.self, data.isEmpty {
      return EmptyResponse() as! Response
    }
    do {
      return try JSONDecoder.commercial.decode(Response.self, from: data)
    } catch {
      throw CommercialError.invalidDocument
    }
  }

  private func encoded(_ value: String) throws -> String {
    guard
      let encoded = value.addingPercentEncoding(
        withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
      )
    else {
      throw CommercialError.invalidDocument
    }
    return encoded
  }
}

private struct EmptyResponse: Codable {}

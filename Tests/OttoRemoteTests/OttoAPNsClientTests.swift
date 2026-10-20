import Foundation
import OttoModels
import OttoRemote
import Testing

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Otto APNs client", .serialized)
struct OttoAPNsClientTests {
  @Test("ES256 provider request uses the paired device environment and canonical deep link")
  func request() async throws {
    let event = RunEvent(
      threadID: UUID(),
      sequence: 7,
      kind: .runCompleted,
      content: RunEventContent(notification: .completion)
    )
    let notification = try #require(OttoAPNsNotification(event: event, threadTitle: "Ada"))
    let key = P256.Signing.PrivateKey()
    let configuration = OttoAPNsConfiguration(
      teamID: "TEAM123456",
      keyID: "KEY1234567",
      topic: "io.openotto.mobile.dev",
      privateKeyPEM: key.pemRepresentation
    )
    APNsStubURLProtocol.handler = { request in
      #expect(request.url?.host == "api.sandbox.push.apple.com")
      #expect(request.url?.path.hasSuffix(String(repeating: "ab", count: 32)) == true)
      #expect(request.value(forHTTPHeaderField: "apns-topic") == configuration.topic)
      #expect(request.value(forHTTPHeaderField: "apns-push-type") == "alert")
      #expect(request.value(forHTTPHeaderField: "apns-priority") == "5")
      #expect(request.value(forHTTPHeaderField: "Authorization")?.split(separator: ".").count == 3)
      let payload = try requestBody(request)
      let json = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
      #expect(json["thread_id"] as? String == event.threadID.uuidString)
      return (200, ["apns-id": event.id.uuidString], Data())
    }
    let urlConfiguration = URLSessionConfiguration.ephemeral
    urlConfiguration.protocolClasses = [APNsStubURLProtocol.self]
    let client = OttoAPNsClient(
      configuration: configuration,
      session: URLSession(configuration: urlConfiguration)
    )
    let device = RemotePairedDevice(
      name: "Phone",
      publicKey: "key",
      credentialHash: "hash",
      scopes: [.readActivity],
      pushToken: String(repeating: "ab", count: 32),
      pushEnvironment: .sandbox
    )

    #expect(try await client.send(notification, to: device).apnsID == event.id.uuidString)
  }

  @Test("APNs rejection preserves status and reason")
  func rejection() async throws {
    let event = RunEvent(
      threadID: UUID(),
      sequence: 1,
      kind: .runFailed,
      content: RunEventContent(notification: .failure)
    )
    let notification = try #require(OttoAPNsNotification(event: event, threadTitle: "Ada"))
    APNsStubURLProtocol.handler = { _ in
      (410, [:], Data(#"{"reason":"Unregistered"}"#.utf8))
    }
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [APNsStubURLProtocol.self]
    let client = OttoAPNsClient(
      configuration: OttoAPNsConfiguration(
        teamID: "TEAM123456",
        keyID: "KEY1234567",
        topic: "io.openotto.mobile",
        privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation
      ),
      session: URLSession(configuration: sessionConfiguration)
    )
    let device = RemotePairedDevice(
      name: "Phone", publicKey: "key", credentialHash: "hash", scopes: [.readActivity],
      pushToken: String(repeating: "cd", count: 32), pushEnvironment: .production)

    await #expect(throws: OttoAPNsError.httpStatus(410, reason: "Unregistered")) {
      try await client.send(notification, to: device)
    }
  }
}

private func requestBody(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  let stream = try #require(request.httpBodyStream)
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? OttoAPNsError.invalidResponse }
    if count == 0 { break }
    data.append(buffer, count: count)
  }
  return data
}

private final class APNsStubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let (status, headers, data) = try handler(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url, statusCode: status,
          httpVersion: "HTTP/2", headerFields: headers))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

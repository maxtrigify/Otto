import Foundation
import OttoRuntime
import Testing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite("Hermes remote profile catalog", .serialized)
struct HermesRemoteProfileCatalogTests {
  @Test("Loads authenticated profiles and preserves a gateway path prefix")
  func loadsProfiles() async throws {
    let session = makeSession { request in
      #expect(request.url?.path == "/hermes/api/profiles")
      #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secret")
      let payload = #"""
        {"profiles":[
          {"name":" silco ","is_default":false,"model":"gpt-5.6-terra","provider":"openai-codex"},
          {"name":"default","is_default":true,"model":"claude-opus-4-6","provider":"anthropic"},
          {"name":"silco","is_default":false}
        ]}
        """#
      return (200, Data(payload.utf8))
    }

    let profiles = try await HermesRemoteProfileCatalog(session: session).profiles(
      baseURL: try #require(URL(string: "https://example.com/hermes")),
      sessionToken: "secret"
    )

    #expect(profiles.map(\.name) == ["default", "silco"])
    #expect(profiles[0].isDefault)
    #expect(profiles[1].provider == "openai-codex")
    #expect(profiles[1].model == "gpt-5.6-terra")
  }

  @Test("Surfaces authentication failures without decoding their body")
  func authenticationFailure() async throws {
    let session = makeSession { _ in (401, Data("not authorized".utf8)) }
    await #expect(throws: HermesRemoteProfileCatalogError.self) {
      _ = try await HermesRemoteProfileCatalog(session: session).profiles(
        baseURL: try #require(URL(string: "https://example.com")),
        sessionToken: "expired"
      )
    }
  }

  private func makeSession(
    handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)
  ) -> URLSession {
    StubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler:
    (@Sendable (URLRequest) throws -> (status: Int, data: Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
      let result = try handler(request)
      let url = try #require(request.url)
      let response = try #require(
        HTTPURLResponse(
          url: url,
          statusCode: result.status,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"]
        ))
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

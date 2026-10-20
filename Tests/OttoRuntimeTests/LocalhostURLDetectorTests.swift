import OttoRuntime
import Testing

@Suite("Localhost URL detection")
struct LocalhostURLDetectorTests {
  @Test("Detects, normalizes, deduplicates, and limits local preview URLs")
  func detectsSafeLocalURLs() {
    let text = """
      Ready at http://localhost:3000.
      Also http://localhost:3000 and https://127.0.0.1:8443/app?q=1)
      IPv6: http://[::1]:5173/dashboard
      """
    let urls = LocalhostURLDetector.urls(in: text, limit: 3).map(\.absoluteString)
    #expect(
      urls
        == [
          "http://localhost:3000",
          "https://127.0.0.1:8443/app?q=1",
          "http://[::1]:5173/dashboard",
        ]
    )
  }

  @Test("Rejects lookalike hosts, credentials, invalid ports, and non-HTTP schemes")
  func rejectsUnsafeURLs() {
    let text = """
      https://localhost.evil.example:3000
      http://user:password@localhost:3000
      http://localhost:99999
      file://localhost/private
      """
    #expect(LocalhostURLDetector.urls(in: text).isEmpty)
  }
}

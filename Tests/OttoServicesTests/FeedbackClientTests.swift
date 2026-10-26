import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import OttoServices

@Suite("Send feedback")
struct FeedbackClientTests {
  static let installID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  static let environment = FeedbackEnvironment(
    appVersion: "0.2.0", build: "42", macOS: "26.1", architecture: "arm64", model: "Mac15,6")

  func client(
    _ transport: @escaping FeedbackClient.Transport = { _ in throw URLError(.unknown) }
  ) -> FeedbackClient {
    FeedbackClient(
      endpoint: URL(string: "https://feedback.example.test/v1/feedback")!,
      installID: Self.installID, environment: Self.environment, transport: transport)
  }

  static func response(_ status: Int, _ body: String) -> (Data, URLResponse) {
    (
      Data(body.utf8),
      HTTPURLResponse(
        url: URL(string: "https://feedback.example.test/v1/feedback")!, statusCode: status,
        httpVersion: nil, headerFields: nil)!
    )
  }

  @Test func encodesTheRequest() throws {
    let screenshot = FeedbackScreenshot(
      mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]), pixelWidth: 1, pixelHeight: 1)
    let draft = FeedbackDraft(
      kind: .idea, title: "  Dark docs  ", description: "\n Please add a dark document theme. \n",
      screenshot: screenshot)
    let request = try client().request(for: draft)
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == 30)
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let httpBody = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
    #expect(
      Set(json.keys) == ["kind", "title", "description", "screenshot", "environment", "installID"])
    #expect(json["kind"] as? String == "idea")
    #expect(json["title"] as? String == "Dark docs")
    #expect(json["description"] as? String == "Please add a dark document theme.")
    #expect(json["installID"] as? String == Self.installID)
    let image = try #require(json["screenshot"] as? [String: String])
    #expect(image == ["mediaType": "image/png", "base64": "iVBORw=="])
    let environment = try #require(json["environment"] as? [String: String])
    #expect(
      environment == [
        "appVersion": "0.2.0", "build": "42", "macOS": "26.1", "architecture": "arm64",
        "model": "Mac15,6",
      ])
  }

  @Test func leavesOutEnvironmentAndScreenshotWhenNotChosen() throws {
    let draft = FeedbackDraft(
      kind: .bug, description: "Something broke here.", includeEnvironment: false)
    let body =
      try JSONSerialization.jsonObject(
        with: try #require(try client().request(for: draft).httpBody)) as? [String: Any]
    #expect(body?["environment"] == nil)
    #expect(body?["screenshot"] == nil)
    #expect(body?["kind"] as? String == "bug")
  }

  @Test func validatesTheDraft() {
    #expect(FeedbackDraft(description: "too short").validationMessage != nil)
    #expect(FeedbackDraft(description: "        short      ").validationMessage != nil)
    #expect(
      FeedbackDraft(description: String(repeating: "x", count: 5_001)).validationMessage != nil)
    #expect(
      FeedbackDraft(title: String(repeating: "t", count: 121), description: "Long enough text")
        .validationMessage != nil)
    #expect(FeedbackDraft(description: "Long enough text").validationMessage == nil)
    #expect(
      FeedbackDraft(description: String(repeating: "x", count: 5_000)).validationMessage == nil)
    #expect(throws: FeedbackError.self) {
      try client().request(for: FeedbackDraft(description: "no"))
    }
  }

  @Test func environmentContainsOnlyVersionsAndModel() throws {
    let current = FeedbackEnvironment.current()
    let data = try JSONEncoder().encode(current)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
    #expect(
      Set(object.keys).isSubset(of: ["appVersion", "build", "macOS", "architecture", "model"]))
    #expect(current.macOS.wholeMatch(of: /[0-9]{1,3}(\.[0-9]{1,3}){0,2}/) != nil)
    #expect(["arm64", "x86_64"].contains(current.architecture))
    let text = String(decoding: data, as: UTF8.self)
    // Compare against the values only: a short host name such as "mac" would otherwise match
    // the "macOS" key itself.
    let values = Array(object.values)
    let identifying = [
      NSUserName(), NSFullUserName(), NSHomeDirectory(), ProcessInfo.processInfo.hostName,
    ].filter { $0.count >= 4 }
    for value in identifying {
      #expect(!values.contains { $0.localizedCaseInsensitiveContains(value) }, "leaked \(value)")
    }
    #expect(!text.contains("/"))
    // Unexpected characters never pass through.
    let odd = FeedbackEnvironment(
      appVersion: "1.0 /Users/max", build: "", macOS: "26.1", architecture: "arm64",
      model: "Max's Mac")
    #expect(odd.appVersion == "1.0Usersmax")
    #expect(odd.build == "unknown")
    #expect(odd.model == nil)
    #expect(
      Self.environment.summaryLines == [
        "Otto 0.2.0 (build 42)", "macOS 26.1", "Mac15,6 · Apple silicon",
      ])
  }

  @Test func installIDIsStableAndAnonymous() throws {
    let defaults = try #require(UserDefaults(suiteName: "feedback-\(UUID())"))
    let first = FeedbackInstallID.current(defaults: defaults)
    #expect(UUID(uuidString: first) != nil)
    #expect(FeedbackInstallID.current(defaults: defaults) == first)
    #expect(defaults.string(forKey: "otto.feedback.installID") == first)
  }

  @Test func endpointConfiguration() {
    let custom = FeedbackClient.configuredEndpoint(
      bundle: .main, processEnvironment: ["OTTO_FEEDBACK_URL": "http://127.0.0.1:8792/v1/feedback"])
    #expect(custom.absoluteString == "http://127.0.0.1:8792/v1/feedback")
    let rejected = FeedbackClient.configuredEndpoint(
      bundle: .main, processEnvironment: ["OTTO_FEEDBACK_URL": "http://evil.example/v1/feedback"])
    #expect(rejected == FeedbackClient.configuredEndpoint(bundle: .main, processEnvironment: [:]))
    #expect(
      FeedbackClient.configuredEndpoint(bundle: .main, processEnvironment: [:]).scheme == "https")
    #expect(
      FeedbackClient.fallbackEndpoint.absoluteString == "https://feedback.openotto.io/v1/feedback")
  }

  @Test func decodesSuccess() async throws {
    let submission = try await client { request in
      #expect(request.url?.path == "/v1/feedback")
      return Self.response(
        201, #"{"issueNumber":17,"issueURL":"https://github.com/maxtrigify/Otto/issues/17"}"#)
    }.send(FeedbackDraft(description: "Something broke here."))
    #expect(submission.issueNumber == 17)
    #expect(submission.issueURL.absoluteString == "https://github.com/maxtrigify/Otto/issues/17")
  }

  @Test func mapsErrors() async {
    let draft = FeedbackDraft(description: "Something broke here.")
    let cases: [(FeedbackClient.Transport, FeedbackError)] = [
      ({ _ in throw URLError(.notConnectedToInternet) }, .offline),
      ({ _ in throw URLError(.cannotFindHost) }, .offline),
      ({ _ in throw URLError(.timedOut) }, .timedOut),
      ({ _ in Self.response(429, #"{"error":"Too many"}"#) }, .rateLimited),
      (
        { _ in Self.response(400, #"{"error":"description is required."}"#) },
        .rejected("description is required.")
      ),
      (
        { _ in Self.response(503, #"{"error":"Screenshots are not configured yet."}"#) },
        .unavailable("Screenshots are not configured yet.")
      ),
      ({ _ in Self.response(502, #"{"error":"GitHub"}"#) }, .server),
      ({ _ in Self.response(201, #"{"unexpected":true}"#) }, .server),
      (
        { _ in Self.response(201, #"{"issueNumber":1,"issueURL":"javascript:alert(1)"}"#) }, .server
      ),
    ]
    for (transport, expected) in cases {
      await #expect(throws: expected) { try await client(transport).send(draft) }
    }
    #expect(!FeedbackError.offline.userMessage.isEmpty)
  }

  @Test func downscalesAndCapsImages() throws {
    let large = try Self.noiseImage(width: 3_200, height: 1_800)
    let prepared = try FeedbackScreenshot.prepare(image: large)
    #expect(max(prepared.pixelWidth, prepared.pixelHeight) <= 1_600)
    #expect(abs(Double(prepared.pixelWidth) / Double(prepared.pixelHeight) - 16.0 / 9.0) < 0.01)
    #expect(prepared.data.count <= FeedbackLimits.maximumImageBytes)
    #expect(["image/png", "image/jpeg"].contains(prepared.mediaType))
    // Noise doesn't compress as PNG, so a tight cap forces JPEG.
    let capped = try FeedbackScreenshot.prepare(image: large, maximumBytes: 400_000)
    #expect(capped.mediaType == "image/jpeg")
    #expect(capped.data.count <= 400_000)
    #expect(Array(capped.data.prefix(3)) == [0xFF, 0xD8, 0xFF])

    let small = try Self.noiseImage(width: 300, height: 200)
    let kept = try FeedbackScreenshot.prepare(image: small)
    #expect(kept.pixelWidth == 300 && kept.pixelHeight == 200)
    #expect(kept.mediaType == "image/png")
    #expect(Array(kept.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

    #expect(throws: FeedbackImageError.tooLarge) {
      try FeedbackScreenshot.prepare(image: large, maximumBytes: 100)
    }
  }

  @Test func preparesImageFilesAndRejectsJunk() throws {
    let image = try Self.noiseImage(width: 2_000, height: 500)
    let output = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let prepared = try FeedbackScreenshot.prepare(imageData: output as Data)
    #expect(prepared.pixelWidth == 1_600 && prepared.pixelHeight == 400)
    #expect(throws: FeedbackImageError.unreadable) {
      try FeedbackScreenshot.prepare(imageData: Data("not an image".utf8))
    }
  }

  static func noiseImage(width: Int, height: Int) throws -> CGImage {
    var generator = SystemRandomNumberGenerator()
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = UInt8.random(in: 0...255, using: &generator)
      pixels[index + 1] = UInt8.random(in: 0...255, using: &generator)
      pixels[index + 2] = UInt8.random(in: 0...255, using: &generator)
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    return try #require(
      CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
  }
}

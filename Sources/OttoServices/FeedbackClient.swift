import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import OttoModels

#if canImport(ImageIO)
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
#endif

/// Bug reports and ideas sent from the app. The feedback service files them as public GitHub
/// issues, so everything here is deliberately minimal: what the person typed, an optional
/// screenshot, an optional version summary and an anonymous install ID used only for rate
/// limiting.
public enum FeedbackKind: String, Codable, CaseIterable, Sendable {
  case bug
  case idea
}

public enum FeedbackLimits {
  public static let minimumDescription = 10
  public static let maximumDescription = 5_000
  public static let maximumTitle = 120
  public static let maximumImagePixels = 1_600
  public static let maximumImageBytes = 2_500_000
  public static let requestTimeout: TimeInterval = 30
}

/// The app and Mac versions that may be attached to a report. Nothing else: no paths, user or
/// host names, locale or hardware serials.
public struct FeedbackEnvironment: Codable, Equatable, Sendable {
  public var appVersion: String
  public var build: String
  public var macOS: String
  public var architecture: String
  public var model: String?

  public init(
    appVersion: String, build: String, macOS: String, architecture: String, model: String? = nil
  ) {
    self.appVersion = Self.token(appVersion, allowing: "+-")
    self.build = Self.token(build, allowing: "-")
    self.macOS = macOS
    self.architecture = architecture
    self.model = model.flatMap(Self.validModel)
  }

  /// This copy of Otto on this Mac.
  public static func current(bundle: Bundle = .main) -> FeedbackEnvironment {
    let info = bundle.infoDictionary ?? [:]
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let macOS =
      os.patchVersion == 0
      ? "\(os.majorVersion).\(os.minorVersion)"
      : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    #if arch(arm64)
      let architecture = "arm64"
    #else
      let architecture = "x86_64"
    #endif
    return FeedbackEnvironment(
      appVersion: info["CFBundleShortVersionString"] as? String ?? "",
      build: info["CFBundleVersion"] as? String ?? "",
      macOS: macOS, architecture: architecture, model: hardwareModel())
  }

  /// Human-readable lines showing exactly what is sent.
  public var summaryLines: [String] {
    let chip = architecture == "arm64" ? "Apple silicon" : "Intel"
    return [
      "Otto \(appVersion) (build \(build))",
      "macOS \(macOS)",
      [model, chip].compactMap { $0 }.joined(separator: " · "),
    ]
  }

  private static func token(_ value: String, allowing extra: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "." + extra))
    let cleaned = String(
      value.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }.prefix(32))
    return cleaned.isEmpty ? "unknown" : cleaned
  }

  /// A model identifier such as `Mac15,6` or `MacBookPro18,3`; anything else is dropped.
  static func validModel(_ value: String) -> String? {
    value.wholeMatch(of: /[A-Za-z]{1,24}[0-9]{1,3},[0-9]{1,3}/) != nil ? value : nil
  }

  private static func hardwareModel() -> String? {
    #if canImport(Darwin)
      var size = 0
      guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size < 128 else {
        return nil
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
      let value = String(
        decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return validModel(value)
    #else
      return nil
    #endif
  }
}

/// One encoded image, ready to send.
public struct FeedbackScreenshot: Equatable, Sendable {
  public var mediaType: String
  public var data: Data
  public var pixelWidth: Int
  public var pixelHeight: Int

  public init(mediaType: String, data: Data, pixelWidth: Int, pixelHeight: Int) {
    self.mediaType = mediaType
    self.data = data
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

public enum FeedbackImageError: Error, Equatable, Sendable {
  case unreadable
  case tooLarge
}

#if canImport(ImageIO)
  extension FeedbackScreenshot {
    /// Reads a PNG, JPEG or HEIC file's bytes, applies its orientation, drops its metadata
    /// (EXIF, GPS) and re-encodes it within the size limits.
    public static func prepare(imageData: Data) throws -> FeedbackScreenshot {
      guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
        CGImageSourceGetCount(source) > 0
      else { throw FeedbackImageError.unreadable }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: FeedbackLimits.maximumImagePixels,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
      else { throw FeedbackImageError.unreadable }
      return try prepare(image: image)
    }

    /// Downscales to at most 1600 px on the longest side, then encodes PNG, falling back to
    /// progressively smaller JPEGs until the result is at most 2.5 MB.
    public static func prepare(
      image: CGImage, maximumPixels: Int = FeedbackLimits.maximumImagePixels,
      maximumBytes: Int = FeedbackLimits.maximumImageBytes
    ) throws -> FeedbackScreenshot {
      var limit = maximumPixels
      while limit >= 400 {
        guard let scaled = downscale(image, longestSide: limit) else {
          throw FeedbackImageError.unreadable
        }
        if let png = encode(scaled, type: .png, quality: nil), png.count <= maximumBytes {
          return FeedbackScreenshot(
            mediaType: "image/png", data: png, pixelWidth: scaled.width,
            pixelHeight: scaled.height)
        }
        for quality in [0.85, 0.7, 0.55] {
          if let jpeg = encode(scaled, type: .jpeg, quality: quality), jpeg.count <= maximumBytes {
            return FeedbackScreenshot(
              mediaType: "image/jpeg", data: jpeg, pixelWidth: scaled.width,
              pixelHeight: scaled.height)
          }
        }
        limit = limit * 3 / 4
      }
      throw FeedbackImageError.tooLarge
    }

    static func downscale(_ image: CGImage, longestSide: Int) -> CGImage? {
      let longest = max(image.width, image.height)
      let scale = longest > longestSide ? Double(longestSide) / Double(longest) : 1
      let width = max(1, Int((Double(image.width) * scale).rounded()))
      let height = max(1, Int((Double(image.height) * scale).rounded()))
      guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
      let output = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          output, type.identifier as CFString, 1, nil)
      else { return nil }
      var properties: [CFString: Any] = [:]
      if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return output as Data
    }
  }
#endif

/// What the person filled in.
public struct FeedbackDraft: Equatable, Sendable {
  public var kind: FeedbackKind
  public var title: String
  public var description: String
  public var screenshot: FeedbackScreenshot?
  public var includeEnvironment: Bool

  public init(
    kind: FeedbackKind = .bug, title: String = "", description: String = "",
    screenshot: FeedbackScreenshot? = nil, includeEnvironment: Bool = true
  ) {
    self.kind = kind
    self.title = title
    self.description = description
    self.screenshot = screenshot
    self.includeEnvironment = includeEnvironment
  }

  public var trimmedDescription: String {
    description.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Nil when the draft can be sent; otherwise a short message for the person.
  public var validationMessage: String? {
    let length = trimmedDescription.count
    if length < FeedbackLimits.minimumDescription {
      return "Add a little more detail (at least \(FeedbackLimits.minimumDescription) characters)."
    }
    if length > FeedbackLimits.maximumDescription {
      return "Keep it under \(FeedbackLimits.maximumDescription.formatted()) characters."
    }
    if trimmedTitle.count > FeedbackLimits.maximumTitle {
      return "Keep the title under \(FeedbackLimits.maximumTitle) characters."
    }
    if let screenshot, screenshot.data.count > FeedbackLimits.maximumImageBytes {
      return "The screenshot is too large."
    }
    return nil
  }
}

/// The JSON the feedback service accepts.
public struct FeedbackRequestBody: Codable, Equatable, Sendable {
  public struct Screenshot: Codable, Equatable, Sendable {
    public var mediaType: String
    public var base64: String
  }

  public var kind: FeedbackKind
  public var title: String
  public var description: String
  public var screenshot: Screenshot?
  public var environment: FeedbackEnvironment?
  public var installID: String
}

/// The filed issue.
public struct FeedbackSubmission: Codable, Equatable, Sendable {
  public var issueNumber: Int
  public var issueURL: URL

  public init(issueNumber: Int, issueURL: URL) {
    self.issueNumber = issueNumber
    self.issueURL = issueURL
  }
}

public enum FeedbackError: Error, Equatable, Sendable {
  case invalid(String)
  case offline
  case timedOut
  case rateLimited
  case rejected(String?)
  case unavailable(String?)
  case server

  /// A friendly sentence for the sheet.
  public var userMessage: String {
    switch self {
    case .invalid(let message): message
    case .offline:
      "You seem to be offline. Check your internet connection and try again."
    case .timedOut: "Sending took too long. Check your connection and try again."
    case .rateLimited: "You've sent a few reports in a row. Wait a minute, then try again."
    case .rejected(let message):
      message.map { "The report wasn't accepted: \($0)" }
        ?? "The report wasn't accepted. Check it and try again."
    case .unavailable(let message):
      message ?? "Feedback isn't available right now. Please try again later."
    case .server: "Something went wrong on our side. Please try again in a little while."
    }
  }
}

/// The anonymous, per-install ID the service rate-limits on. Never shown on GitHub.
public enum FeedbackInstallID {
  public static let defaultsKey = "otto.feedback.installID"

  public static func current(defaults: UserDefaults = .standard) -> String {
    if let stored = defaults.string(forKey: defaultsKey), let uuid = UUID(uuidString: stored) {
      return uuid.uuidString.lowercased()
    }
    let value = UUID().uuidString.lowercased()
    defaults.set(value, forKey: defaultsKey)
    return value
  }
}

public struct FeedbackClient: Sendable {
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public static let infoPlistKey = "OttoFeedbackURL"
  public static let fallbackEndpoint = URL(string: "https://feedback.openotto.io/v1/feedback")!

  public var endpoint: URL
  public var installID: String
  public var environment: FeedbackEnvironment
  private let transport: Transport

  public init(
    endpoint: URL = FeedbackClient.configuredEndpoint(),
    installID: String = FeedbackInstallID.current(),
    environment: FeedbackEnvironment = .current(),
    transport: @escaping Transport = FeedbackClient.urlSessionTransport
  ) {
    self.endpoint = endpoint
    self.installID = installID
    self.environment = environment
    self.transport = transport
  }

  public static let urlSessionTransport: Transport = { request in
    try await URLSession.shared.data(for: request, delegate: nil)
  }

  /// `OTTO_FEEDBACK_URL` (for testing against a local worker), then the bundle's
  /// `OttoFeedbackURL`, then the production service.
  public static func configuredEndpoint(
    bundle: Bundle = .main,
    processEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let value = OttoEnvironment.nonEmptyValue("FEEDBACK_URL", in: processEnvironment),
      let url = URL(string: value), isAllowed(url, development: true)
    {
      return url
    }
    if let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
      let url = URL(string: value), isAllowed(url, development: false)
    {
      return url
    }
    return fallbackEndpoint
  }

  static func isAllowed(_ url: URL, development: Bool) -> Bool {
    guard url.host != nil, url.user == nil, url.password == nil, url.query == nil,
      url.fragment == nil
    else { return false }
    if url.scheme == "https" { return true }
    return development && url.scheme == "http"
      && ["127.0.0.1", "localhost"].contains(url.host ?? "")
  }

  public func body(for draft: FeedbackDraft) throws -> FeedbackRequestBody {
    if let message = draft.validationMessage { throw FeedbackError.invalid(message) }
    return FeedbackRequestBody(
      kind: draft.kind,
      title: String(draft.trimmedTitle.prefix(FeedbackLimits.maximumTitle)),
      description: draft.trimmedDescription,
      screenshot: draft.screenshot.map {
        .init(mediaType: $0.mediaType, base64: $0.data.base64EncodedString())
      },
      environment: draft.includeEnvironment ? environment : nil,
      installID: installID)
  }

  public func request(for draft: FeedbackDraft) throws -> URLRequest {
    var request = URLRequest(url: endpoint, timeoutInterval: FeedbackLimits.requestTimeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    request.httpBody = try encoder.encode(body(for: draft))
    return request
  }

  public func send(_ draft: FeedbackDraft) async throws -> FeedbackSubmission {
    let request = try request(for: draft)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      throw Self.map(error)
    }
    return try Self.decode(data: data, response: response)
  }

  static func map(_ error: any Error) -> FeedbackError {
    if let feedback = error as? FeedbackError { return feedback }
    guard let urlError = error as? URLError else { return .server }
    switch urlError.code {
    case .timedOut: return .timedOut
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
      return .offline
    default: return .server
    }
  }

  static func decode(data: Data, response: URLResponse) throws -> FeedbackSubmission {
    guard let http = response as? HTTPURLResponse else { throw FeedbackError.server }
    struct ServiceError: Decodable { var error: String }
    let message = (try? JSONDecoder().decode(ServiceError.self, from: data))
      .map { String($0.error.prefix(200)) }
    switch http.statusCode {
    case 200...299:
      guard let submission = try? JSONDecoder().decode(FeedbackSubmission.self, from: data),
        submission.issueURL.scheme == "https"
      else { throw FeedbackError.server }
      return submission
    case 429: throw FeedbackError.rateLimited
    case 400, 413, 415, 422: throw FeedbackError.rejected(message)
    case 503: throw FeedbackError.unavailable(message)
    default: throw FeedbackError.server
    }
  }
}

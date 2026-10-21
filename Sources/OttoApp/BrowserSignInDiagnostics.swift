import OSLog
import WebKit

/// Explicit local troubleshooting mode. Never logs URLs, page text, or message payloads.
@MainActor
enum BrowserSignInDiagnostics {
  static let enabled =
    ProcessInfo.processInfo.arguments.contains("--browser-diagnostics")
    || Bundle.main.object(forInfoDictionaryKey: "OttoBrowserDiagnosticsEnabled") as? Bool == true
  private static let logger = Logger(subsystem: "io.openotto.desktop", category: "BrowserSignIn")

  static func configure(_ page: WKWebView) {
    page.isInspectable = enabled
  }

  static func record(_ event: String, code: Int = 0) {
    guard enabled else { return }
    logger.notice("\(event, privacy: .public) code=\(code)")
  }
}

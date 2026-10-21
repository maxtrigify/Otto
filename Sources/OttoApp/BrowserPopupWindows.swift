import AppKit
import WebKit

/// Own the child WebKit views for window.open, including the opener supplied by WebKit.
@MainActor
final class BrowserPopupWindows: NSObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
  private(set) var windows: [ObjectIdentifier: NSWindowController] = [:]

  func webView(
    _ opener: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    guard navigationAction.targetFrame == nil else { return nil }
    // Replacing this configuration or navigating the parent would break window.opener.
    let popup = WKWebView(frame: .zero, configuration: configuration)
    BrowserSignInDiagnostics.configure(popup)
    BrowserPasswordBridge.register(popup)
    popup.uiDelegate = self
    popup.navigationDelegate = self
    BrowserSignInDiagnostics.record("popup.created")
    let width = windowFeatures.width?.doubleValue ?? 520
    let height = windowFeatures.height?.doubleValue ?? 680
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: max(width, 360), height: max(height, 480)),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "Sign in"
    window.contentView = popup
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.center()
    let controller = NSWindowController(window: window)
    windows[ObjectIdentifier(popup)] = controller
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    return popup
  }
  func webViewDidClose(_ webView: WKWebView) {
    BrowserSignInDiagnostics.record("popup.scriptClosed")
    guard let controller = windows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
    controller.close()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    BrowserSignInDiagnostics.record("popup.navigationFinished")
  }
  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
  ) {
    BrowserSignInDiagnostics.record("popup.navigationFailed", code: (error as NSError).code)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: any Error
  ) {
    BrowserSignInDiagnostics.record(
      "popup.provisionalNavigationFailed", code: (error as NSError).code)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    BrowserSignInDiagnostics.record("popup.processTerminated")
  }
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    windows = windows.filter { $0.value.window !== window }
  }
  func closeAll() {
    let controllers = Array(windows.values)
    windows.removeAll()
    for controller in controllers {
      controller.window?.delegate = nil
      controller.close()
    }
  }
}

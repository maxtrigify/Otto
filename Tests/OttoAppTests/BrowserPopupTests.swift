import AppKit
import Foundation
import Testing
import WebKit

@testable import OttoApp

@Suite("Browser popup handoff", .serialized) @MainActor
struct BrowserPopupTests {
  @Test func iframePopupReturnsMessageBeforeClosing() async throws {
    _ = NSApplication.shared
    let server = try PopupFixtureServer()
    defer { server.stop() }
    let popups = BrowserPopupWindows()
    defer { popups.closeAll() }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    // Only the disposable fixture enables script-opened windows without a real mouse gesture.
    config.preferences.javaScriptCanOpenWindowsAutomatically = true
    let opener = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
    opener.uiDelegate = popups
    let window = NSWindow(
      contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = opener
    window.orderFront(nil)
    defer { window.close() }
    opener.load(URLRequest(url: server.url))
    for _ in 0..<200 {
      if (try? await opener.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    _ = try await opener.evaluateJavaScript(
      "document.querySelector('iframe').contentWindow.postMessage('open', '*')")
    for _ in 0..<300 {
      if (try? await opener.evaluateJavaScript("window.returned === true")) as? Bool == true {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    let returned = try await opener.evaluateJavaScript("window.returned === true") as? Bool
    #expect(returned == true)
    #expect(popups.windows.isEmpty)
  }
}

private final class PopupFixtureServer {
  let process = Process()
  let url: URL
  init() throws {
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-u", "-c",
      #"""
      from http.server import HTTPServer,BaseHTTPRequestHandler
      class H(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
          p=self.server.server_port
          self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
          if self.path=='/frame':
            body=f'''<script>addEventListener('message',e=>{{if(e.data==='open')window.open('/provider','signin');if(e.data==='done')parent.postMessage('done','http://127.0.0.1:{p}')}});parent.postMessage('ready','http://127.0.0.1:{p}')</script>'''
          elif self.path=='/provider':
            body="<script>window.opener.postMessage('done',location.origin);window.close()</script>"
          else:
            body=f'''<iframe src="http://localhost:{p}/frame"></iframe><script>window.returned=false;addEventListener('message',e=>{{if(e.origin!=='http://localhost:{p}')return;if(e.data==='ready')window.fixtureReady=true;if(e.data==='done')window.returned=true}})</script>'''
          self.wfile.write(body.encode())
      s=HTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()
      """#,
    ]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: "http://127.0.0.1:" + port), Int(port) != nil else {
      process.terminate()
      throw CocoaError(.fileReadUnknown)
    }
    self.url = url
  }
  func stop() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
  }
}

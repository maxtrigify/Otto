import Foundation
import OttoMCP
import Testing

@Suite("MCP request scheduling")
struct MCPRequestDispatcherTests {
  @Test("A parked browser request does not block unrelated tools; queued cancellation is honored")
  func parkedRequestAndCancellation() throws {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let unrelated = DispatchSemaphore(value: 0)
    let probe = DispatcherProbe()
    let dispatcher = MCPRequestDispatcher(
      handle: { line, _ in
        probe.record(line)
        if line.contains("first") {
          entered.signal()
          _ = release.wait(timeout: .now() + 5)
        } else if line.contains("other") {
          unrelated.signal()
        }
        return line
      },
      write: { _ in }
    )
    dispatcher.submit(line: request(id: "first", name: "browser.click"))
    #expect(entered.wait(timeout: .now() + 2) == .success)
    dispatcher.submit(line: request(id: "second", name: "browser_click"))
    dispatcher.submit(line: request(id: "other", name: "node.list"))
    #expect(unrelated.wait(timeout: .now() + 2) == .success)
    #expect(!probe.lines.contains { $0.contains("second") })
    dispatcher.submit(
      line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"second"}}"#
    )
    dispatcher.submit(line: request(id: "third", name: "browser.click"))
    // A cancelled middle operation must not break the ordering dependency on the first.
    Thread.sleep(forTimeInterval: 0.05)
    #expect(!probe.lines.contains { $0.contains("third") })
    release.signal()
    dispatcher.waitUntilFinished()
    #expect(probe.lines.count == 3)
    #expect(!probe.lines.contains { $0.contains("second") })
  }

  @Test("Notifications receive no response")
  func notificationsAreSilent() {
    let probe = DispatcherProbe()
    let dispatcher = MCPRequestDispatcher(
      handle: { line, _ in
        probe.record(line)
        return line
      }, write: { probe.record($0) })
    dispatcher.submit(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    dispatcher.waitUntilFinished()
    #expect(probe.lines.isEmpty)
  }

  private func request(id: String, name: String) -> String {
    """
    {"jsonrpc":"2.0","id":"\(id)","method":"tools/call","params":{"name":"\(name)","arguments":{"nodeID":"page"}}}
    """
  }
}

private final class DispatcherProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  var lines: [String] { lock.withLock { storage } }
  func record(_ value: String) { lock.withLock { storage.append(value) } }
}

import Foundation
import OttoControl
import OttoMCP
import OttoModels

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@main
struct OttoMCPCommand {
  private static let usage = """
    Usage: otto-mcp

    Runs the Otto Model Context Protocol bridge over standard input and output.
    Otto launches this helper with a scoped control socket and token.
    """

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
      return
    }
    guard arguments.isEmpty else {
      FileHandle.standardError.write(Data("\(usage)\n".utf8))
      Foundation.exit(64)
    }
    let environment = ProcessInfo.processInfo.environment
    // Voice thinks with whichever harness the person chose, and every harness reaches Otto's
    // tools through this helper. For voice the tools are served by the voice engine itself, so
    // that what it does carries the person's own privileges rather than a background agent's.
    if let address = OttoEnvironment.value("VOICE_BRIDGE_URL", in: environment),
      let url = URL(string: address),
      let token = OttoEnvironment.value("VOICE_BRIDGE_TOKEN", in: environment)
    {
      runVoiceBridge(url: url, token: token)
      return
    }
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment),
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment)
    else {
      FileHandle.standardError.write(Data("Missing Otto control environment.\n".utf8))
      Foundation.exit(2)
    }

    let client = ControlClient(
      socketPath: socket,
      token: token,
      sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
        UUID.init(uuidString:)),
      sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
        UUID.init(uuidString:))
    )
    let dispatcher = MCPRequestDispatcher(
      handle: { line, cancellation in
        MCPBridge(client: client, isCancelled: { cancellation.isCancelled }).handle(line: line)
      },
      write: { response in
        print(response)
        #if os(Linux)
          // Glibc declares `stdout` as a mutable global, which Swift 6 rejects in this
          // concurrent closure. fflush(nil) flushes every output stream, stdout included.
          fflush(nil)
        #else
          fflush(stdout)
        #endif
      }
    )
    while let line = readLine() {
      dispatcher.submit(line: line)
    }
    dispatcher.waitUntilFinished()
  }

  /// Passes each request to the voice engine's loopback tool server and prints its answer.
  private static func runVoiceBridge(url: URL, token: String) {
    let dispatcher = MCPRequestDispatcher(
      handle: { line, _ in forward(line, to: url, token: token) },
      write: { response in
        print(response)
        #if os(Linux)
          fflush(nil)
        #else
          fflush(stdout)
        #endif
      }
    )
    while let line = readLine() {
      dispatcher.submit(line: line)
    }
    dispatcher.waitUntilFinished()
  }

  private static func forward(_ line: String, to url: URL, token: String) -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data(line.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    // A tool may wait on the person, for example for a confirmation.
    request.timeoutInterval = 3_600
    let finished = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
      if let data, !data.isEmpty { box.set(String(decoding: data, as: UTF8.self)) }
      finished.signal()
    }
    task.resume()
    finished.wait()
    if let body = box.value { return body }
    // The engine has gone away; answer in the protocol so the harness stops waiting.
    let id =
      (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["id"]
    let failure: [String: Any] = [
      "jsonrpc": "2.0", "id": id ?? NSNull(),
      "error": ["code": -32000, "message": "Otto voice is no longer listening."],
    ]
    return (try? JSONSerialization.data(withJSONObject: failure)).map {
      String(decoding: $0, as: UTF8.self)
    } ?? "{}"
  }

  private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
  }
}

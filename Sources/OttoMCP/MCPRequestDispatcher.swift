import Foundation
import OttoTools

/// Reads can continue while a tool waits for a human. Browser operations on the same node
/// stay ordered, so a later click cannot change the page underneath a pending confirmation.
/// Each handler owns its encoder/decoder; the output lock keeps JSON lines from interleaving.
public final class MCPRequestDispatcher: @unchecked Sendable {
  private let queue = OperationQueue()
  private let lock = NSLock()
  private let outputLock = NSLock()
  private var browserTails: [String: Operation] = [:]
  private struct PendingRequest {
    let operation: Operation
    let cancellation: MCPRequestCancellation
  }
  private var requests: [String: PendingRequest] = [:]
  private let handle: @Sendable (String, MCPRequestCancellation) -> String
  private let write: @Sendable (String) -> Void

  public init(
    handle: @escaping @Sendable (String, MCPRequestCancellation) -> String,
    write: @escaping @Sendable (String) -> Void
  ) {
    self.handle = handle
    self.write = write
    queue.name = "io.openotto.mcp.requests"
    queue.maxConcurrentOperationCount = 16
    queue.qualityOfService = .userInitiated
  }

  public func submit(line: String) {
    let request = try? JSONDecoder().decode(MCPRequest.self, from: Data(line.utf8))
    if let request, request.id == nil {
      if request.method == "notifications/cancelled",
        let id = request.params?["requestId"], let key = Self.key(id)
      {
        lock.withLock {
          requests[key]?.cancellation.cancel()
        }
      }
      // JSON-RPC notifications never receive responses.
      return
    }
    let requestKey = request?.id.flatMap(Self.key)
    let name = request?.params?["name"]?.stringValue ?? ""
    let browserKey: String? =
      request?.method == "tools/call"
        && (name.hasPrefix("browser.") || name.hasPrefix("browser_"))
      ? request?.params?["arguments"]?["nodeID"]?.stringValue?.lowercased() ?? "browser"
      : nil
    let operation = BlockOperation()
    let cancellation = MCPRequestCancellation()
    // Keep cancelled operations in their dependency chain until their predecessor finishes.
    // Operation.cancel() could otherwise let a later browser call overtake a parked click.
    operation.addExecutionBlock { [weak self] in
      guard let self, !cancellation.isCancelled else { return }
      let response = self.handle(line, cancellation)
      self.outputLock.withLock {
        if !cancellation.isCancelled { self.write(response) }
      }
    }
    operation.completionBlock = { [weak self, weak operation] in
      guard let self, let operation else { return }
      self.lock.withLock {
        if let requestKey, self.requests[requestKey]?.operation === operation {
          self.requests.removeValue(forKey: requestKey)
        }
        if let browserKey, self.browserTails[browserKey] === operation {
          self.browserTails.removeValue(forKey: browserKey)
        }
      }
    }
    lock.withLock {
      if let browserKey {
        if let previous = browserTails[browserKey] { operation.addDependency(previous) }
        browserTails[browserKey] = operation
      }
      if let requestKey {
        requests[requestKey] = PendingRequest(operation: operation, cancellation: cancellation)
      }
      queue.addOperation(operation)
    }
  }

  public func waitUntilFinished() {
    queue.waitUntilAllOperationsAreFinished()
  }

  private static func key(_ id: JSONValue) -> String? {
    guard let data = try? JSONEncoder().encode(id) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Cancellation cannot undo an action already sent, but it prevents an approval received later
/// from replaying an abandoned browser click.
public final class MCPRequestCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  public init() {}
  public var isCancelled: Bool { lock.withLock { cancelled } }
  public func cancel() { lock.withLock { cancelled = true } }
}

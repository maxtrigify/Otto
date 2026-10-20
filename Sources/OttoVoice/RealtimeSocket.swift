import Foundation

public protocol RealtimeSocket: Sendable {
  var messages: AsyncStream<String> { get }
  func connect(request: URLRequest) async throws
  func send(text: String) async throws
  func disconnect() async
}

public final class URLSessionRealtimeSocket: RealtimeSocket, @unchecked Sendable {
  public let messages: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private let session: URLSession
  private let lock = NSLock()
  private var task: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?

  public init(session: URLSession = .shared) {
    self.session = session
    var continuation: AsyncStream<String>.Continuation!
    messages = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  public func connect(request: URLRequest) async throws {
    let task = session.webSocketTask(with: request)
    lock.withLock { self.task = task }
    task.resume()
    receiveTask = Task { [weak self] in
      await self?.receiveLoop(task)
    }
  }

  public func send(text: String) async throws {
    guard let task = lock.withLock({ task }) else {
      throw URLError(.notConnectedToInternet)
    }
    try await task.send(.string(text))
  }

  public func disconnect() async {
    receiveTask?.cancel()
    receiveTask = nil
    lock.withLock {
      task?.cancel(with: .normalClosure, reason: nil)
      task = nil
    }
    continuation.finish()
  }

  private func receiveLoop(_ task: URLSessionWebSocketTask) async {
    do {
      while !Task.isCancelled {
        let message = try await task.receive()
        switch message {
        case .string(let text): continuation.yield(text)
        case .data(let data): continuation.yield(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      }
    } catch {
      continuation.finish()
    }
  }
}

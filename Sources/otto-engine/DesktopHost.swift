import Foundation
import OttoModels
import OttoRPCContracts

/// The engine's line back to Otto Desktop. Most traffic is the desktop asking the engine; this
/// carries the other direction: calls the engine needs the desktop to perform (run a page script
/// in a browser tab, take a screenshot) and events it should react to (a bot opened a tab).
///
/// Wire format, one JSON object per line on stdout:
///   `{"host": {"id", "method", "params"}}`  a call; the desktop answers on stdin with
///   `{"token", "hostReply": {"id", "result"} | {"id", "error"}}`
///   `{"event": {"kind", "payload"}}`        fire and forget
actor DesktopHost {
  struct Reply: Decodable {
    var id: String
    var result: OpaqueCodableValue?
    var error: String?
  }

  enum HostError: Error, LocalizedError {
    case unavailable(String)
    case timedOut(String)
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .unavailable(let method): "Otto Desktop is not connected (\(method))."
      case .timedOut(let method): "Otto Desktop did not answer \(method) in time."
      case .failed(let message): message
      }
    }
  }

  private struct Call<Params: Encodable>: Encodable {
    struct Body: Encodable {
      var id: String
      var method: String
      var params: Params
    }
    var host: Body
  }

  private struct Event<Payload: Encodable>: Encodable {
    struct Body: Encodable {
      var kind: String
      var payload: Payload
    }
    var event: Body
  }

  private let output: ResponseWriter
  private var pending: [String: CheckedContinuation<OpaqueCodableValue, any Error>] = [:]

  init(output: ResponseWriter) { self.output = output }

  /// Sends `method` to the desktop and waits for its answer.
  func call<Params: Encodable & Sendable, Result: Decodable>(
    _ method: String, _ params: Params, as type: Result.Type, timeout: Duration = .seconds(30)
  ) async throws -> Result {
    let id = UUID().uuidString
    let line = try OttoRPCCodec.encoder.encode(Call(host: .init(id: id, method: method, params: params)))
    let value: OpaqueCodableValue = try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      Task {
        await output.writeLine(line)
        try? await Task.sleep(for: timeout)
        self.expire(id, method: method)
      }
    }
    return try OttoRPCCodec.decode(type, from: value)
  }

  func emit<Payload: Encodable>(_ kind: String, _ payload: Payload) async {
    guard let line = try? OttoRPCCodec.encoder.encode(Event(event: .init(kind: kind, payload: payload)))
    else { return }
    await output.writeLine(line)
  }

  func receive(_ reply: Reply) {
    guard let continuation = pending.removeValue(forKey: reply.id) else { return }
    if let error = reply.error {
      continuation.resume(throwing: HostError.failed(error))
    } else {
      continuation.resume(returning: reply.result ?? .null)
    }
  }

  private func expire(_ id: String, method: String) {
    pending.removeValue(forKey: id)?.resume(throwing: HostError.timedOut(method))
  }
}

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import ucrt
#endif
import Dispatch
import Foundation
import OttoTools

public final class ControlServer: @unchecked Sendable {
  public let socketPath: String

  private let registry: ToolRegistry
  private let authenticator: ControlAuthenticator
  private let listener: SocketHandle
  #if !os(Windows)
    private let source: DispatchSourceRead
  #endif
  private let connectionQueue: OperationQueue
  private let stateLock = NSLock()
  private var stopped = false

  public init(
    socketPath: String,
    registry: ToolRegistry,
    authenticator: ControlAuthenticator
  ) throws {
    self.socketPath = socketPath
    self.registry = registry
    self.authenticator = authenticator
    let connectionQueue = OperationQueue()
    connectionQueue.name = "io.openotto.control.connections"
    connectionQueue.qualityOfService = .userInitiated
    connectionQueue.maxConcurrentOperationCount = 16
    self.connectionQueue = connectionQueue

    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    #if !os(Windows)
      chmod(directory.path, 0o700)
    #endif
    try? FileManager.default.removeItem(atPath: socketPath)

    let listener = try UnixSocket.create()
    do {
      try UnixSocket.bind(listener, path: socketPath)
      guard Posix.listen(listener) == 0 else { throw UnixSocket.socketError() }
      #if !os(Windows)
        try UnixSocket.setNonBlocking(listener)
        chmod(socketPath, 0o600)
      #endif
    } catch {
      Posix.close(listener)
      throw error
    }
    self.listener = listener
    #if os(Windows)
      // A blocking accept on its own thread; closing the listener in stop() ends it.
      Thread.detachNewThread { [weak self] in self?.acceptConnections() }
    #else
      self.source = DispatchSource.makeReadSource(
        fileDescriptor: listener,
        queue: DispatchQueue(label: "io.openotto.control.accept", qos: .userInitiated)
      )
      self.source.setEventHandler { [weak self] in self?.acceptConnections() }
      self.source.setCancelHandler {}
      self.source.resume()
    #endif
  }

  deinit {
    stop()
  }

  public func stop() {
    stateLock.withLock {
      guard !stopped else { return }
      stopped = true
      #if !os(Windows)
        source.cancel()
      #endif
      Posix.close(listener)
      try? FileManager.default.removeItem(atPath: socketPath)
    }
  }

  private func acceptConnections() {
    while true {
      let client = Posix.accept(listener)
      if !Posix.isValid(client) {
        if Posix.interrupted() { continue }
        return
      }
      do {
        try UnixSocket.setNonBlocking(client)
        try UnixSocket.setCloseOnExec(client)
      } catch {
        Posix.close(client)
        continue
      }
      connectionQueue.addOperation { [weak self] in
        self?.readAndHandle(client)
      }
    }
  }

  private func readAndHandle(_ client: SocketHandle) {
    let request: ControlRequest
    do {
      request = try UnixSocket.readMessage(ControlRequest.self, from: client)
    } catch {
      try? UnixSocket.writeMessage(
        ControlResponse(
          id: "unknown",
          error: ControlFailure(code: "invalid_request", message: error.localizedDescription)
        ),
        to: client
      )
      Posix.close(client)
      return
    }
    Task { [weak self] in
      guard let self else {
        Posix.close(client)
        return
      }
      await handle(request, client: client)
    }
  }

  private func handle(_ request: ControlRequest, client: SocketHandle) async {
    defer { Posix.close(client) }
    let response = await process(request)
    try? UnixSocket.writeMessage(response, to: client)
  }

  private func process(_ request: ControlRequest) async -> ControlResponse {
    guard let grant = await authenticator.resolve(request.token) else {
      return ControlResponse(
        id: request.id,
        error: ControlFailure(code: "unauthorized", message: "Invalid or expired control token")
      )
    }

    let context = ToolContext(
      actorID: grant.actorID, scopes: grant.scopes, confirmed: request.confirmed,
      source: grant.source, sourceNodeID: grant.sourceNodeID ?? request.sourceNodeID,
      sourceCanvasID: grant.sourceCanvasID ?? request.sourceCanvasID,
      targetCanvasID: grant.sourceCanvasID ?? request.targetCanvasID,
      interactionPrivileges: grant.interactionPrivileges)
    do {
      switch request.method {
      case .toolsList:
        return ControlResponse(
          id: request.id, result: try JSONValue.encode(await registry.definitions(for: context)))
      case .toolsCall:
        guard let name = request.toolName else {
          throw ControlProtocolError.invalidRequest("tools/call requires toolName")
        }
        let result = try await registry.call(
          name: name,
          input: request.arguments ?? .object([:]),
          context: context,
          requestID: request.id
        )
        return ControlResponse(id: request.id, result: result)
      }
    } catch {
      return ControlResponse(
        id: request.id,
        error: ControlFailure(code: "tool_error", message: error.localizedDescription)
      )
    }
  }
}

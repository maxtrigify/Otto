import Dispatch
import Foundation
import OttoTools

#if canImport(Darwin)
  import Darwin
#else
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#endif

public final class RemoteSocketServer: @unchecked Sendable {
  public let socketPath: String
  private let daemon: RemoteDaemon
  private let listener: Int32
  private let source: DispatchSourceRead
  private let connectionQueue: OperationQueue
  private let stateLock = NSLock()
  private var stopped = false

  public init(socketPath: String, daemon: RemoteDaemon) throws {
    self.socketPath = socketPath
    self.daemon = daemon
    let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    unlink(socketPath)
    listener = try RemoteUnixSocket.create()
    do {
      try RemoteUnixSocket.bind(listener, path: socketPath)
      guard listen(listener, SOMAXCONN) == 0 else {
        throw RemoteUnixSocket.error()
      }
      try RemoteUnixSocket.setNonBlocking(listener)
      chmod(socketPath, 0o600)
    } catch {
      systemClose(listener)
      throw error
    }
    let queue = OperationQueue()
    queue.name = "io.openotto.remote.connections"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 16
    connectionQueue = queue
    source = DispatchSource.makeReadSource(
      fileDescriptor: listener,
      queue: DispatchQueue(label: "io.openotto.remote.accept", qos: .userInitiated)
    )
    let listenerDescriptor = listener
    let socketPathToRemove = socketPath
    source.setEventHandler { [weak self] in self?.acceptConnections() }
    source.setCancelHandler {
      systemClose(listenerDescriptor)
      unlink(socketPathToRemove)
    }
    source.resume()
  }

  deinit { stop() }

  public func stop() {
    stateLock.withLock {
      guard !stopped else { return }
      stopped = true
      source.cancel()
    }
  }

  public func waitUntilStopped() async {
    while !stateLock.withLock({ stopped }) {
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
    }
  }

  private func acceptConnections() {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 {
        if errno == EINTR { continue }
        return
      }
      do {
        try RemoteUnixSocket.configure(client)
      } catch {
        systemClose(client)
        continue
      }
      connectionQueue.addOperation { [weak self] in self?.readAndHandle(client) }
    }
  }

  private func readAndHandle(_ client: Int32) {
    let request: RemoteRequest
    do {
      request = try RemoteUnixSocket.read(RemoteRequest.self, from: client)
    } catch {
      try? RemoteUnixSocket.write(
        RemoteResponse(
          id: "unknown",
          error: RemoteFailure(code: "invalid_request", message: "Invalid remote request.")
        ),
        to: client
      )
      systemClose(client)
      return
    }
    Task { [weak self] in
      guard let self else {
        systemClose(client)
        return
      }
      let response = await daemon.handle(request)
      try? RemoteUnixSocket.write(response, to: client)
      systemClose(client)
    }
  }
}

public struct RemoteSocketClient: Sendable {
  public let socketPath: String
  public let token: String

  private static let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "io.openotto.remote.client"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 8
    return queue
  }()

  public init(socketPath: String, token: String) {
    self.socketPath = socketPath
    self.token = token
  }

  public func request(
    _ method: RemoteMethod,
    parameters: (any Encodable & Sendable)? = nil,
    requestID: String = UUID().uuidString
  ) async throws -> JSONValue {
    let value: JSONValue?
    if let parameters {
      value = try JSONValue.encode(AnyRemoteEncodable(parameters))
    } else {
      value = nil
    }
    let request = RemoteRequest(
      id: requestID,
      token: token,
      method: method,
      parameters: value
    )
    let maximumAttempts: Int
    switch method {
    case .hello, .heartbeat, .events, .fileRead: maximumAttempts = 3
    case .launch, .input, .resize, .stop, .fileWrite, .tokenRotate: maximumAttempts = 1
    }
    var response: RemoteResponse?
    var lastError: (any Error)?
    for attempt in 0..<maximumAttempts {
      do {
        let candidate: RemoteResponse = try await withCheckedThrowingContinuation { continuation in
          Self.queue.addOperation {
            continuation.resume(with: Result { try send(request) })
          }
        }
        if candidate.error?.code == "invalid_request", attempt + 1 < maximumAttempts {
          lastError = RemoteError.invalidInput("server abandoned an incomplete transport frame")
          try await Task.sleep(for: .milliseconds(25))
          continue
        }
        response = candidate
        break
      } catch {
        lastError = error
        if attempt + 1 < maximumAttempts { try await Task.sleep(for: .milliseconds(25)) }
      }
    }
    guard let response else {
      throw RemoteError.invalidInput(
        "\(method.rawValue) transport failed: \(lastError?.localizedDescription ?? "unknown error")"
      )
    }
    if let failure = response.error {
      throw RemoteError.invalidInput("\(failure.code): \(failure.message)")
    }
    guard let result = response.result else {
      throw RemoteError.invalidInput("remote response contained no result")
    }
    return result
  }

  private func send(_ request: RemoteRequest) throws -> RemoteResponse {
    let descriptor = try RemoteUnixSocket.create()
    defer { systemClose(descriptor) }
    try RemoteUnixSocket.connect(descriptor, path: socketPath)
    try RemoteUnixSocket.setNonBlocking(descriptor)
    try RemoteUnixSocket.write(request, to: descriptor)
    return try RemoteUnixSocket.read(
      RemoteResponse.self,
      from: descriptor,
      timeoutMilliseconds: RemoteUnixSocket.clientResponseTimeout
    )
  }
}

private struct AnyRemoteEncodable: Encodable, @unchecked Sendable {
  private let encodeValue: (Encoder) throws -> Void

  init(_ value: any Encodable & Sendable) {
    encodeValue = value.encode
  }

  func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

private enum RemoteUnixSocket {
  static let limit = 8 * 1_024 * 1_024
  static let timeout: Int32 = 10_000
  static let clientResponseTimeout: Int32 = 10_000

  static func create() throws -> Int32 {
    #if os(Linux)
      #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
      #else
        let socketType = SOCK_STREAM
      #endif
      let descriptor = socket(AF_UNIX, socketType, 0)
    #else
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw error() }
    do { try configure(descriptor) } catch {
      systemClose(descriptor)
      throw error
    }
    return descriptor
  }

  static func configure(_ descriptor: Int32) throws {
    #if !os(Linux)
      var noSignal: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout<Int32>.size)
        ) == 0
      else { throw error() }
    #endif
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    guard descriptorFlags >= 0,
      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else { throw error() }
  }

  static func setNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw error()
    }
  }

  static func address(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count + 1 < capacity else {
      throw RemoteError.invalidInput("remote socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    return address
  }

  static func bind(_ descriptor: Int32, path: String) throws {
    var address = try address(path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw error() }
  }

  static func connect(_ descriptor: Int32, path: String) throws {
    var address = try address(path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw error() }
  }

  static func write<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    var data = try JSONEncoder.remote.encode(value)
    data.append(0x0a)
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let count = systemWrite(descriptor, base.advanced(by: offset), buffer.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          try wait(descriptor, event: Int16(POLLOUT))
        } else {
          throw error()
        }
      }
    }
  }

  static func read<T: Decodable>(
    _ type: T.Type,
    from descriptor: Int32,
    timeoutMilliseconds: Int32 = timeout
  ) throws -> T {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while data.count <= limit {
      let count = systemRead(descriptor, &bytes, bytes.count)
      if count > 0 {
        data.append(contentsOf: bytes.prefix(count))
        if let newline = data.firstIndex(of: 0x0a) {
          return try JSONDecoder.remote.decode(type, from: Data(data[..<newline]))
        }
      } else if count == 0 {
        break
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        try wait(
          descriptor,
          event: Int16(POLLIN),
          timeoutMilliseconds: timeoutMilliseconds
        )
      } else {
        throw error()
      }
    }
    guard data.count <= limit else {
      throw RemoteError.resourceLimit("remote frame exceeds eight MiB")
    }
    return try JSONDecoder.remote.decode(type, from: data)
  }

  static func wait(
    _ descriptor: Int32,
    event: Int16,
    timeoutMilliseconds: Int32 = timeout
  ) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: event, revents: 0)
    while true {
      let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
      if result > 0 { return }
      if result < 0, errno == EINTR { continue }
      if result == 0 { throw RemoteError.invalidInput("remote socket I/O timed out") }
      throw error()
    }
  }

  static func error() -> RemoteError {
    RemoteError.invalidInput(decodeRemoteCString(strerror(errno)))
  }
}

private func systemClose(_ descriptor: Int32) {
  #if os(Linux)
    _ = close(descriptor)
  #else
    _ = Darwin.close(descriptor)
  #endif
}

private func systemBind(
  _ descriptor: Int32,
  _ address: UnsafePointer<sockaddr>,
  _ length: socklen_t
) -> Int32 {
  #if os(Linux)
    bind(descriptor, address, length)
  #else
    Darwin.bind(descriptor, address, length)
  #endif
}

private func systemConnect(
  _ descriptor: Int32,
  _ address: UnsafePointer<sockaddr>,
  _ length: socklen_t
) -> Int32 {
  #if os(Linux)
    connect(descriptor, address, length)
  #else
    Darwin.connect(descriptor, address, length)
  #endif
}

private func systemWrite(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer,
  _ count: Int
) -> Int {
  #if os(Linux)
    send(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
  #else
    Darwin.write(descriptor, buffer, count)
  #endif
}

private func systemRead(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer,
  _ count: Int
) -> Int {
  #if os(Linux)
    read(descriptor, buffer, count)
  #else
    Darwin.read(descriptor, buffer, count)
  #endif
}

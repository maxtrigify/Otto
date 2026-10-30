#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
import Foundation

enum UnixSocket {
  static let messageLimit = 1_048_576
  static let ioTimeoutMilliseconds: Int32 = 10_000
  static let clientResponseTimeoutMilliseconds: Int32 = 10_000

  static func create() throws -> Int32 {
    let descriptor = Posix.socket(AF_UNIX, Posix.streamType, 0)
    guard descriptor >= 0 else { throw socketError() }
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      guard
        setsockopt(
          descriptor,
          SOL_SOCKET,
          SO_NOSIGPIPE,
          &noSignal,
          socklen_t(MemoryLayout<Int32>.size)
        ) == 0
      else {
        let error = socketError()
        Posix.close(descriptor)
        throw error
      }
    #else
      // Linux has no SO_NOSIGPIPE; a peer hanging up must not kill the process.
      _ = signal(SIGPIPE, SIG_IGN)
    #endif
    do {
      try setCloseOnExec(descriptor)
    } catch {
      Posix.close(descriptor)
      throw error
    }
    return descriptor
  }

  static func address(for path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count + 1 < capacity else {
      throw ControlProtocolError.socket("Unix socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      for (index, byte) in bytes.enumerated() {
        buffer[index] = byte
      }
    }
    return address
  }

  static func bind(_ descriptor: Int32, path: String) throws {
    var address = try address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Posix.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw socketError() }
  }

  static func connect(_ descriptor: Int32, path: String) throws {
    var address = try address(for: path)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Posix.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw socketError() }
  }

  static func setNonBlocking(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw socketError()
    }
  }

  static func setCloseOnExec(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFD)
    guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
      throw socketError()
    }
  }

  static func writeMessage<T: Encodable>(_ value: T, to descriptor: Int32) throws {
    var data = try JSONEncoder.control.encode(value)
    data.append(0x0a)
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var remaining = buffer.count
      var offset = 0
      while remaining > 0 {
        let written = Posix.write(descriptor, base.advanced(by: offset), remaining)
        if written < 0 {
          if errno == EINTR { continue }
          if errno == EAGAIN || errno == EWOULDBLOCK {
            try waitFor(descriptor, event: Int16(POLLOUT))
            continue
          }
          throw socketError()
        }
        remaining -= written
        offset += written
      }
    }
  }

  static func readMessage<T: Decodable>(
    _ type: T.Type,
    from descriptor: Int32,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws -> T {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while data.count <= messageLimit {
      let count = Posix.read(descriptor, &bytes, bytes.count)
      if count < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          try waitFor(
            descriptor,
            event: Int16(POLLIN),
            timeoutMilliseconds: timeoutMilliseconds
          )
          continue
        }
        throw socketError()
      }
      if count == 0 { break }
      data.append(contentsOf: bytes.prefix(count))
      if let newline = data.firstIndex(of: 0x0a) {
        data = data[..<newline]
        break
      }
    }
    guard data.count <= messageLimit else { throw ControlProtocolError.responseTooLarge }
    do {
      return try JSONDecoder.control.decode(type, from: data)
    } catch {
      throw ControlProtocolError.invalidRequest(error.localizedDescription)
    }
  }

  static func socketError() -> ControlProtocolError {
    ControlProtocolError.socket(String(cString: strerror(errno)))
  }

  private static func waitFor(
    _ descriptor: Int32,
    event: Int16,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: event, revents: 0)
    while true {
      let result = poll(&pollDescriptor, 1, timeoutMilliseconds)
      if result > 0 { return }
      if result < 0, errno == EINTR { continue }
      if result == 0 {
        throw ControlProtocolError.socket("Unix socket I/O timed out")
      }
      throw socketError()
    }
  }
}

extension JSONEncoder {
  fileprivate static var control: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var control: JSONDecoder { JSONDecoder() }
}

/// The libc calls used by the control socket, named once so call sites stay platform-neutral.
enum Posix {
  #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    static func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
      Darwin.socket(domain, type, proto)
    }
    @discardableResult static func close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
      Darwin.bind(fd, address, length)
    }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t)
      -> Int32
    { Darwin.connect(fd, address, length) }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func accept(
      _ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?,
      _ length: UnsafeMutablePointer<socklen_t>?
    ) -> Int32 { Darwin.accept(fd, address, length) }
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
      Darwin.read(fd, buffer, count)
    }
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
      Darwin.write(fd, buffer, count)
    }
  #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    static func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
      Glibc.socket(domain, type, proto)
    }
    @discardableResult static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
      Glibc.bind(fd, address, length)
    }
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t)
      -> Int32
    { Glibc.connect(fd, address, length) }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func accept(
      _ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?,
      _ length: UnsafeMutablePointer<socklen_t>?
    ) -> Int32 { Glibc.accept(fd, address, length) }
    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
      Glibc.read(fd, buffer, count)
    }
    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
      Glibc.write(fd, buffer, count)
    }
  #endif
}

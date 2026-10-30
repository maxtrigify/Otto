#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif
import Foundation

/// A connected or listening socket: a file descriptor on POSIX, a Winsock SOCKET on Windows.
#if os(Windows)
  typealias SocketHandle = SOCKET
#else
  typealias SocketHandle = Int32
#endif

enum UnixSocket {
  static let messageLimit = 1_048_576
  static let ioTimeoutMilliseconds: Int32 = 10_000
  static let clientResponseTimeoutMilliseconds: Int32 = 10_000

  static func create() throws -> SocketHandle {
    let descriptor = Posix.socket()
    guard Posix.isValid(descriptor) else { throw socketError() }
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
    #elseif !os(Windows)
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

  /// `sockaddr_un` bytes: a 16-bit family followed by a NUL-terminated path (108 bytes on
  /// Linux and Windows, 104 on Darwin).
  static func address(for path: String) throws -> [UInt8] {
    #if canImport(Darwin)
      let pathCapacity = 104
      var address = [UInt8](repeating: 0, count: 2 + pathCapacity)
      address[0] = UInt8(2 + pathCapacity)  // sun_len
      address[1] = UInt8(AF_UNIX)
    #else
      let pathCapacity = 108
      var address = [UInt8](repeating: 0, count: 2 + pathCapacity)
      address[0] = 1  // AF_UNIX, little-endian
    #endif
    let bytes = Array(path.utf8)
    guard bytes.count + 1 < pathCapacity else {
      throw ControlProtocolError.socket("Unix socket path is too long")
    }
    address.replaceSubrange(2..<(2 + bytes.count), with: bytes)
    return address
  }

  static func bind(_ descriptor: SocketHandle, path: String) throws {
    let address = try address(for: path)
    let result = address.withUnsafeBytes { raw in
      Posix.bind(descriptor, raw.baseAddress!, Int32(raw.count))
    }
    guard result == 0 else { throw socketError() }
  }

  static func connect(_ descriptor: SocketHandle, path: String) throws {
    let address = try address(for: path)
    let result = address.withUnsafeBytes { raw in
      Posix.connect(descriptor, raw.baseAddress!, Int32(raw.count))
    }
    guard result == 0 else { throw socketError() }
  }

  static func setNonBlocking(_ descriptor: SocketHandle) throws {
    #if os(Windows)
      var enabled: u_long = 1
      // FIONBIO is a function-like macro (_IOW('f', 126, u_long)) that Swift does not import.
      guard ioctlsocket(descriptor, Int32(bitPattern: 0x8004_667E), &enabled) == 0 else {
        throw socketError()
      }
    #else
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw socketError()
      }
    #endif
  }

  /// Windows sockets are never inherited unless a child is created with inheritance on.
  static func setCloseOnExec(_ descriptor: SocketHandle) throws {
    #if !os(Windows)
      let flags = fcntl(descriptor, F_GETFD)
      guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
        throw socketError()
      }
    #endif
  }

  static func writeMessage<T: Encodable>(_ value: T, to descriptor: SocketHandle) throws {
    var data = try JSONEncoder.control.encode(value)
    data.append(0x0a)
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var remaining = buffer.count
      var offset = 0
      while remaining > 0 {
        let written = Posix.write(descriptor, base.advanced(by: offset), remaining)
        if written < 0 {
          if Posix.interrupted() { continue }
          if Posix.wouldBlock() {
            try waitFor(descriptor, readable: false)
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
    from descriptor: SocketHandle,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws -> T {
    var data = Data()
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while data.count <= messageLimit {
      let count = Posix.read(descriptor, &bytes, bytes.count)
      if count < 0 {
        if Posix.interrupted() { continue }
        if Posix.wouldBlock() {
          try waitFor(descriptor, readable: true, timeoutMilliseconds: timeoutMilliseconds)
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
    ControlProtocolError.socket(Posix.lastErrorDescription())
  }

  private static func waitFor(
    _ descriptor: SocketHandle,
    readable: Bool,
    timeoutMilliseconds: Int32 = ioTimeoutMilliseconds
  ) throws {
    while true {
      let result = Posix.poll(descriptor, readable: readable, timeoutMilliseconds: timeoutMilliseconds)
      if result > 0 { return }
      if result < 0, Posix.interrupted() { continue }
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

/// The socket calls used by the control socket, named once so call sites stay platform-neutral.
enum Posix {
  #if os(Windows)
    private static let started: Bool = {
      var data = WSADATA()
      return WSAStartup(0x0202, &data) == 0
    }()

    static func socket() -> SocketHandle {
      _ = started
      return WinSDK.socket(AF_UNIX, SOCK_STREAM, 0)
    }
    static func isValid(_ socket: SocketHandle) -> Bool { socket != INVALID_SOCKET }
    @discardableResult static func close(_ socket: SocketHandle) -> Int32 { closesocket(socket) }
    static func bind(_ socket: SocketHandle, _ address: UnsafeRawPointer, _ length: Int32) -> Int32 {
      WinSDK.bind(socket, address.assumingMemoryBound(to: sockaddr.self), length)
    }
    static func connect(_ socket: SocketHandle, _ address: UnsafeRawPointer, _ length: Int32)
      -> Int32
    { WinSDK.connect(socket, address.assumingMemoryBound(to: sockaddr.self), length) }
    static func listen(_ socket: SocketHandle) -> Int32 { WinSDK.listen(socket, SOMAXCONN) }
    static func accept(_ socket: SocketHandle) -> SocketHandle { WinSDK.accept(socket, nil, nil) }
    static func read(_ socket: SocketHandle, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
      Int(recv(socket, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
    }
    static func write(_ socket: SocketHandle, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
      Int(send(socket, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: count), 0))
    }
    static func poll(_ socket: SocketHandle, readable: Bool, timeoutMilliseconds: Int32) -> Int32 {
      // POLLRDNORM / POLLWRNORM: the plain-data events WSAPoll accepts.
      var descriptor = WSAPOLLFD(fd: socket, events: readable ? 0x0100 : 0x0010, revents: 0)
      return WSAPoll(&descriptor, 1, timeoutMilliseconds)
    }
    static func interrupted() -> Bool { WSAGetLastError() == WSAEINTR }
    static func wouldBlock() -> Bool { WSAGetLastError() == WSAEWOULDBLOCK }
    static func lastErrorDescription() -> String { "Winsock error \(WSAGetLastError())" }
  #else
    #if canImport(Darwin)
      private static let streamType = SOCK_STREAM
    #else
      private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    static func socket() -> SocketHandle {
      #if canImport(Darwin)
        Darwin.socket(AF_UNIX, streamType, 0)
      #else
        Glibc.socket(AF_UNIX, streamType, 0)
      #endif
    }
    static func isValid(_ descriptor: SocketHandle) -> Bool { descriptor >= 0 }
    @discardableResult static func close(_ fd: SocketHandle) -> Int32 {
      #if canImport(Darwin)
        Darwin.close(fd)
      #else
        Glibc.close(fd)
      #endif
    }
    static func bind(_ fd: SocketHandle, _ address: UnsafeRawPointer, _ length: Int32) -> Int32 {
      let socketAddress = address.assumingMemoryBound(to: sockaddr.self)
      #if canImport(Darwin)
        return Darwin.bind(fd, socketAddress, socklen_t(length))
      #else
        return Glibc.bind(fd, socketAddress, socklen_t(length))
      #endif
    }
    static func connect(_ fd: SocketHandle, _ address: UnsafeRawPointer, _ length: Int32) -> Int32 {
      let socketAddress = address.assumingMemoryBound(to: sockaddr.self)
      #if canImport(Darwin)
        return Darwin.connect(fd, socketAddress, socklen_t(length))
      #else
        return Glibc.connect(fd, socketAddress, socklen_t(length))
      #endif
    }
    static func listen(_ fd: SocketHandle) -> Int32 {
      #if canImport(Darwin)
        Darwin.listen(fd, SOMAXCONN)
      #else
        Glibc.listen(fd, SOMAXCONN)
      #endif
    }
    static func accept(_ fd: SocketHandle) -> SocketHandle {
      #if canImport(Darwin)
        Darwin.accept(fd, nil, nil)
      #else
        Glibc.accept(fd, nil, nil)
      #endif
    }
    static func read(_ fd: SocketHandle, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
      #if canImport(Darwin)
        Darwin.read(fd, buffer, count)
      #else
        Glibc.read(fd, buffer, count)
      #endif
    }
    static func write(_ fd: SocketHandle, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
      #if canImport(Darwin)
        Darwin.write(fd, buffer, count)
      #else
        Glibc.write(fd, buffer, count)
      #endif
    }
    static func poll(_ fd: SocketHandle, readable: Bool, timeoutMilliseconds: Int32) -> Int32 {
      var descriptor = pollfd(fd: fd, events: Int16(readable ? POLLIN : POLLOUT), revents: 0)
      #if canImport(Darwin)
        return Darwin.poll(&descriptor, 1, timeoutMilliseconds)
      #else
        return Glibc.poll(&descriptor, 1, timeoutMilliseconds)
      #endif
    }
    static func interrupted() -> Bool { errno == EINTR }
    static func wouldBlock() -> Bool { errno == EAGAIN || errno == EWOULDBLOCK }
    static func lastErrorDescription() -> String { String(cString: strerror(errno)) }
  #endif
}

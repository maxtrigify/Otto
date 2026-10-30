import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

/// A non-blocking, exclusive lock on a file, held until `release()`: `flock` on POSIX, and on
/// Windows a handle opened with no sharing, so a second writer gets a sharing violation.
final class ProcessFileLock {
  #if os(Windows)
    private var handle: HANDLE?
  #else
    private var descriptor: Int32 = -1
  #endif

  enum Failure: Error { case unavailable, busy }

  init(path: String) throws {
    #if os(Windows)
      let wide = Array(path.utf16) + [0]
      let opened = CreateFileW(
        wide, GENERIC_READ | GENERIC_WRITE, 0, nil, DWORD(OPEN_ALWAYS),
        DWORD(FILE_ATTRIBUTE_NORMAL), nil)
      guard let opened, opened != INVALID_HANDLE_VALUE else {
        throw GetLastError() == DWORD(ERROR_SHARING_VIOLATION) ? Failure.busy : Failure.unavailable
      }
      handle = opened
    #else
      let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw Failure.unavailable }
      guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        throw Failure.busy
      }
      descriptor = fd
    #endif
  }

  func release() {
    #if os(Windows)
      if let handle { CloseHandle(handle) }
      handle = nil
    #else
      guard descriptor >= 0 else { return }
      flock(descriptor, LOCK_UN)
      close(descriptor)
      descriptor = -1
    #endif
  }

  deinit { release() }
}

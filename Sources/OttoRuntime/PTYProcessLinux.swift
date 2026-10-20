#if os(Linux)
  import Dispatch
  import Foundation
  #if canImport(Glibc)
    import Glibc

    @_silgen_name("posix_openpt")
    private func linuxPosixOpenPT(_ flags: Int32) -> Int32

    @_silgen_name("grantpt")
    private func linuxGrantPT(_ fileDescriptor: Int32) -> Int32

    @_silgen_name("unlockpt")
    private func linuxUnlockPT(_ fileDescriptor: Int32) -> Int32

    @_silgen_name("ptsname_r")
    private func linuxPTSName(
      _ fileDescriptor: Int32,
      _ buffer: UnsafeMutablePointer<CChar>,
      _ bufferSize: Int
    ) -> Int32
  #elseif canImport(Musl)
    import Musl
  #endif

  public final class PTYProcess: @unchecked Sendable {
    private static let spawnLock = NSLock()

    public let processIdentifier: pid_t
    public let output: AsyncStream<Data>
    public let exit: AsyncStream<Int32>

    private let masterFileDescriptor: Int32
    private var setupSlaveFileDescriptor: Int32?
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Int32>.Continuation
    private let readQueue: DispatchQueue
    private let readSource: DispatchSourceRead
    private let stateLock = NSLock()
    private var isClosed = false
    private var hasReaped = false
    private var columns: UInt16
    private var rows: UInt16

    private init(
      processIdentifier: pid_t,
      masterFileDescriptor: Int32,
      setupSlaveFileDescriptor: Int32,
      columns: UInt16,
      rows: UInt16
    ) {
      self.processIdentifier = processIdentifier
      self.masterFileDescriptor = masterFileDescriptor
      self.setupSlaveFileDescriptor = setupSlaveFileDescriptor
      self.columns = columns
      self.rows = rows

      var outputContinuation: AsyncStream<Data>.Continuation!
      self.output = AsyncStream { outputContinuation = $0 }
      self.outputContinuation = outputContinuation

      var exitContinuation: AsyncStream<Int32>.Continuation!
      self.exit = AsyncStream { exitContinuation = $0 }
      self.exitContinuation = exitContinuation

      readQueue = DispatchQueue(label: "io.openotto.pty.read.\(processIdentifier)")
      readSource = DispatchSource.makeReadSource(
        fileDescriptor: masterFileDescriptor,
        queue: readQueue
      )
      readSource.setEventHandler { [weak self] in self?.drainOutput() }
      readSource.setCancelHandler { _ = close(masterFileDescriptor) }
      readSource.resume()
    }

    deinit { closeIfNeeded() }

    public static func spawn(_ specification: ProcessLaunchSpec) throws -> PTYProcess {
      spawnLock.lock()
      defer { spawnLock.unlock() }

      let setsid = "/usr/bin/setsid"
      let environmentCommand = "/usr/bin/env"
      guard FileManager.default.isExecutableFile(atPath: setsid),
        FileManager.default.isExecutableFile(atPath: environmentCommand)
      else {
        throw RuntimeError.launchFailed(
          "Linux PTY launch requires /usr/bin/setsid and /usr/bin/env")
      }
      let arguments =
        [
          setsid, "--wait", "--ctty", environmentCommand,
          "--chdir=\(specification.workingDirectory)", specification.executable,
        ] + specification.arguments
      let cArguments = arguments.map { strdup($0) }
      defer { for argument in cArguments { free(argument) } }
      let argumentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
        capacity: cArguments.count + 1
      )
      defer { argumentVector.deallocate() }
      for (index, argument) in cArguments.enumerated() { argumentVector[index] = argument }
      argumentVector[cArguments.count] = nil

      let environment = specification.resolvedEnvironment(
        inheriting: ProcessInfo.processInfo.environment)
      let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
      defer { for value in cEnvironment { free(value) } }
      let environmentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
        capacity: cEnvironment.count + 1
      )
      defer { environmentVector.deallocate() }
      for (index, value) in cEnvironment.enumerated() { environmentVector[index] = value }
      environmentVector[cEnvironment.count] = nil

      #if canImport(Glibc)
        let master = linuxPosixOpenPT(O_RDWR | O_NOCTTY | O_CLOEXEC)
        let grantResult = master >= 0 ? linuxGrantPT(master) : -1
        let unlockResult = grantResult == 0 ? linuxUnlockPT(master) : -1
      #else
        let master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        let grantResult = master >= 0 ? grantpt(master) : -1
        let unlockResult = grantResult == 0 ? unlockpt(master) : -1
      #endif
      guard master >= 0, grantResult == 0, unlockResult == 0 else {
        if master >= 0 { _ = close(master) }
        throw RuntimeError.launchFailed("Could not allocate a pseudo-terminal")
      }
      var slavePathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
      let slavePathResult = slavePathBytes.withUnsafeMutableBufferPointer { buffer in
        #if canImport(Glibc)
          linuxPTSName(master, buffer.baseAddress!, buffer.count)
        #else
          ptsname_r(master, buffer.baseAddress!, buffer.count)
        #endif
      }
      guard slavePathResult == 0 else {
        _ = close(master)
        throw RuntimeError.launchFailed("Could not resolve the pseudo-terminal slave")
      }
      let slavePathLength = slavePathBytes.firstIndex(of: 0) ?? slavePathBytes.endIndex
      let slavePath = String(
        decoding: slavePathBytes[..<slavePathLength].map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
      var windowSize = winsize(
        ws_row: specification.rows,
        ws_col: specification.columns,
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      let setupSlave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
      guard setupSlave >= 0, ioctl(setupSlave, UInt(TIOCSWINSZ), &windowSize) == 0 else {
        if setupSlave >= 0 { _ = close(setupSlave) }
        _ = close(master)
        throw RuntimeError.launchFailed("Could not set pseudo-terminal dimensions")
      }
      var transferredSetupSlave = false
      defer {
        if !transferredSetupSlave { _ = close(setupSlave) }
      }

      var fileActions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
      guard posix_spawn_file_actions_init(&fileActions) == 0,
        posix_spawnattr_init(&attributes) == 0
      else {
        _ = close(master)
        throw RuntimeError.launchFailed("Could not initialize process spawn attributes")
      }
      defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
      }
      let openResult = posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        slavePath,
        O_RDWR,
        0
      )
      let stdoutResult = posix_spawn_file_actions_adddup2(
        &fileActions, STDIN_FILENO, STDOUT_FILENO)
      let stderrResult = posix_spawn_file_actions_adddup2(
        &fileActions, STDIN_FILENO, STDERR_FILENO)
      let closeResult = posix_spawn_file_actions_addclose(&fileActions, master)
      guard openResult == 0, stdoutResult == 0, stderrResult == 0, closeResult == 0 else {
        _ = close(master)
        throw RuntimeError.launchFailed("Could not configure pseudo-terminal process actions")
      }

      var emptySignalSet = sigset_t()
      sigemptyset(&emptySignalSet)
      var defaultSignals = sigset_t()
      sigemptyset(&defaultSignals)
      for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaultSignals, signal) }
      let flags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setsigmask(&attributes, &emptySignalSet) == 0,
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
      else {
        _ = close(master)
        throw RuntimeError.launchFailed("Could not configure process signal attributes")
      }

      var pid: pid_t = 0
      let spawnResult = posix_spawn(
        &pid,
        setsid,
        &fileActions,
        &attributes,
        argumentVector,
        environmentVector
      )
      guard spawnResult == 0, pid > 0 else {
        _ = close(master)
        throw RuntimeError.launchFailed(decodeLinuxCString(strerror(spawnResult)))
      }
      let descriptorFlags = fcntl(master, F_GETFD)
      let statusFlags = fcntl(master, F_GETFL)
      guard descriptorFlags >= 0,
        fcntl(master, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
        statusFlags >= 0,
        fcntl(master, F_SETFL, statusFlags | O_NONBLOCK) == 0
      else {
        _ = close(master)
        _ = kill(pid, SIGTERM)
        throw RuntimeError.launchFailed("Could not configure nonblocking PTY transport")
      }
      let process = PTYProcess(
        processIdentifier: pid,
        masterFileDescriptor: master,
        setupSlaveFileDescriptor: setupSlave,
        columns: specification.columns,
        rows: specification.rows
      )
      process.observeExit()
      transferredSetupSlave = true
      return process
    }

    public func send(_ data: Data) throws {
      try stateLock.withLock {
        guard !isClosed else { throw RuntimeError.transportClosed }
        try data.withUnsafeBytes { buffer in
          guard let baseAddress = buffer.baseAddress else { return }
          var remaining = buffer.count
          var offset = 0
          while remaining > 0 {
            let written = write(
              masterFileDescriptor,
              baseAddress.advanced(by: offset),
              remaining
            )
            if written < 0 {
              if errno == EINTR { continue }
              if errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(
                  fd: masterFileDescriptor, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 1_000) > 0 else { throw RuntimeError.transportClosed }
                continue
              }
              throw RuntimeError.transportClosed
            }
            remaining -= written
            offset += written
          }
        }
      }
    }

    public func send(text: String) throws {
      guard let data = text.data(using: .utf8) else { return }
      try send(data)
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
      let unchanged = try stateLock.withLock {
        guard !isClosed else { throw RuntimeError.transportClosed }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFileDescriptor, UInt(TIOCSWINSZ), &size) == 0 else {
          throw RuntimeError.transportClosed
        }
        let unchanged = self.columns == columns && self.rows == rows
        self.columns = columns
        self.rows = rows
        return unchanged
      }
      if unchanged { try signalForegroundProcessGroup(SIGWINCH) }
    }

    public func interrupt() throws { try send(Data([0x03])) }
    public func terminate() throws { try signalForegroundProcessGroup(SIGTERM) }
    public func forceTerminate() throws { try signalForegroundProcessGroup(SIGKILL) }

    private func drainOutput(final: Bool = false) {
      while true {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var readError: Int32 = 0
        let count = stateLock.withLock {
          guard !isClosed else { return Int.min }
          let value = read(masterFileDescriptor, &bytes, bytes.count)
          readError = errno
          return value
        }
        if count == Int.min { return }
        if count > 0 {
          outputContinuation.yield(Data(bytes.prefix(count)))
          continue
        }
        if count == 0 || (readError != EAGAIN && readError != EINTR) {
          finishOutput()
        } else if readError == EINTR {
          continue
        } else if final {
          finishOutput()
        }
        return
      }
    }

    private func observeExit() {
      ChildProcessReaper.shared.observe(pid: processIdentifier) { [weak self] status in
        self?.readQueue.async { [weak self] in self?.completeExit(status) }
      }
    }

    private func completeExit(_ status: Int32) {
      guard !hasReaped else { return }
      hasReaped = true
      let terminationSignal = status & 0x7f
      let code: Int32
      if terminationSignal == 0 {
        code = (status >> 8) & 0xff
      } else if terminationSignal != 0x7f {
        code = 128 + terminationSignal
      } else {
        code = status
      }
      // Drain buffered output while our slave descriptor still keeps the tty
      // alive: closing the last slave fd can discard unread master-side data.
      drainOutput()
      closeSetupSlaveIfNeeded()
      drainOutput()
      exitContinuation.yield(code)
      exitContinuation.finish()
      scheduleFinalOutputDrain()
    }

    private func scheduleFinalOutputDrain(remainingAttempts: Int = 20) {
      readQueue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
        guard let self else { return }
        self.drainOutput(final: remainingAttempts == 0)
        if remainingAttempts > 0, !self.transportIsClosed {
          self.scheduleFinalOutputDrain(remainingAttempts: remainingAttempts - 1)
        }
      }
    }

    private var transportIsClosed: Bool {
      stateLock.withLock { isClosed }
    }

    private func finishOutput() {
      outputContinuation.finish()
      closeIfNeeded()
    }

    private func closeSetupSlaveIfNeeded() {
      stateLock.withLock {
        guard let descriptor = setupSlaveFileDescriptor else { return }
        setupSlaveFileDescriptor = nil
        _ = close(descriptor)
      }
    }

    private func signalForegroundProcessGroup(_ signal: Int32) throws {
      var foregroundGroup: pid_t = 0
      if ioctl(masterFileDescriptor, UInt(TIOCGPGRP), &foregroundGroup) == 0,
        foregroundGroup > 0,
        kill(-foregroundGroup, signal) == 0
      {
        return
      }
      guard kill(processIdentifier, signal) == 0 || errno == ESRCH else {
        throw RuntimeError.transportClosed
      }
    }

    private func closeIfNeeded() {
      stateLock.withLock {
        guard !isClosed else { return }
        isClosed = true
        if let descriptor = setupSlaveFileDescriptor {
          setupSlaveFileDescriptor = nil
          _ = close(descriptor)
        }
        readSource.cancel()
      }
    }
  }

  private func decodeLinuxCString(_ pointer: UnsafePointer<CChar>) -> String {
    let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return String(
      decoding: UnsafeBufferPointer(start: bytes, count: strlen(pointer)),
      as: UTF8.self
    )
  }
#endif

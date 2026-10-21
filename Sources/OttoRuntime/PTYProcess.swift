#if !os(Linux)
  import Darwin
  import Dispatch
  import Foundation

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
    private var supervisorLifetimeWriteFileDescriptor: Int32?
    private var columns: UInt16
    private var rows: UInt16

    /// The background monitor owns the read end of a pipe whose write end exists only in Otto.
    /// If Otto crashes or is force-quit, the kernel closes that write end and the monitor kills
    /// the provider's process group. A double fork keeps the monitor out of the provider's child
    /// list so an otherwise-idle terminal is not mistaken for a shell with live work.
    private static let supervisorLifetimeWatchdogScript = """
      watchdog_fd=$1
      shift
      target=$$
      (
        (
          trap '' HUP INT TERM
          eval "IFS= read -r _ <&$watchdog_fd"
          kill -TERM -- "-$target" 2>/dev/null || exit 0
          sleep 2
          kill -KILL -- "-$target" 2>/dev/null || true
        ) &
      ) &
      eval "exec $watchdog_fd<&-"
      exec "$@"
      """

    private init(
      processIdentifier: pid_t,
      masterFileDescriptor: Int32,
      setupSlaveFileDescriptor: Int32,
      supervisorLifetimeWriteFileDescriptor: Int32,
      columns: UInt16,
      rows: UInt16
    ) {
      self.processIdentifier = processIdentifier
      self.masterFileDescriptor = masterFileDescriptor
      self.setupSlaveFileDescriptor = setupSlaveFileDescriptor
      self.supervisorLifetimeWriteFileDescriptor = supervisorLifetimeWriteFileDescriptor
      self.columns = columns
      self.rows = rows

      var outputContinuation: AsyncStream<Data>.Continuation!
      self.output = AsyncStream { outputContinuation = $0 }
      self.outputContinuation = outputContinuation

      var exitContinuation: AsyncStream<Int32>.Continuation!
      self.exit = AsyncStream { exitContinuation = $0 }
      self.exitContinuation = exitContinuation

      self.readQueue = DispatchQueue(label: "io.openotto.pty.read.\(processIdentifier)")
      self.readSource = DispatchSource.makeReadSource(
        fileDescriptor: masterFileDescriptor, queue: readQueue)
      self.readSource.setEventHandler { [weak self] in self?.drainOutput() }
      self.readSource.setCancelHandler { Darwin.close(masterFileDescriptor) }
      self.readSource.resume()
    }

    deinit {
      closeSupervisorLifetimeIfNeeded()
      closeTransportIfNeeded()
    }

    public static func spawn(_ specification: ProcessLaunchSpec) throws -> PTYProcess {
      spawnLock.lock()
      defer { spawnLock.unlock() }

      guard access(specification.executable, X_OK) == 0 else {
        throw RuntimeError.launchFailed(String(cString: strerror(errno)))
      }

      var supervisorLifetimePipe = [Int32](repeating: -1, count: 2)
      let supervisorLifetimePipeResult = supervisorLifetimePipe.withUnsafeMutableBufferPointer {
        pipe($0.baseAddress!)
      }
      guard supervisorLifetimePipeResult == 0 else {
        throw RuntimeError.launchFailed("Could not create the supervisor lifetime pipe")
      }
      let supervisorLifetimeRead = supervisorLifetimePipe[0]
      let supervisorLifetimeWrite = supervisorLifetimePipe[1]
      var transferredSupervisorLifetimeWrite = false
      defer {
        Darwin.close(supervisorLifetimeRead)
        if !transferredSupervisorLifetimeWrite { Darwin.close(supervisorLifetimeWrite) }
      }
      for descriptor in supervisorLifetimePipe {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
          throw RuntimeError.launchFailed("Could not secure the supervisor lifetime pipe")
        }
      }

      let arguments =
        [
          "/bin/sh", "-c", supervisorLifetimeWatchdogScript, "otto-process-watchdog",
          String(supervisorLifetimeRead), specification.executable,
        ] + specification.arguments
      let cArguments = arguments.map { strdup($0) }
      defer {
        for argument in cArguments { free(argument) }
      }

      let argumentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
        capacity: cArguments.count + 1)
      defer { argumentVector.deallocate() }
      for (index, argument) in cArguments.enumerated() {
        argumentVector[index] = argument
      }
      argumentVector[cArguments.count] = nil
      guard let executable = cArguments[0] else {
        throw RuntimeError.launchFailed("Missing executable")
      }

      guard let workingDirectory = strdup(specification.workingDirectory) else {
        throw RuntimeError.launchFailed("Could not encode the working directory")
      }
      defer { free(workingDirectory) }

      let environment = specification.resolvedEnvironment(
        inheriting: ProcessInfo.processInfo.environment)
      let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") }
      defer {
        for value in cEnvironment { free(value) }
      }
      let environmentVector = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
        capacity: cEnvironment.count + 1)
      defer { environmentVector.deallocate() }
      for (index, value) in cEnvironment.enumerated() {
        environmentVector[index] = value
      }
      environmentVector[cEnvironment.count] = nil

      let master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
      guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0 else {
        if master >= 0 { Darwin.close(master) }
        throw RuntimeError.launchFailed("Could not allocate a pseudo-terminal")
      }
      var slavePathBytes = [CChar](repeating: 0, count: Int(PATH_MAX))
      let slavePathResult = slavePathBytes.withUnsafeMutableBufferPointer { buffer in
        ptsname_r(master, buffer.baseAddress!, buffer.count)
      }
      guard slavePathResult == 0 else {
        Darwin.close(master)
        throw RuntimeError.launchFailed("Could not resolve the pseudo-terminal slave")
      }
      let slavePathLength = slavePathBytes.firstIndex(of: 0) ?? slavePathBytes.count
      let slavePath = String(
        decoding: slavePathBytes.prefix(slavePathLength).map { UInt8(bitPattern: $0) },
        as: UTF8.self
      )
      var windowSize = winsize(
        ws_row: specification.rows,
        ws_col: specification.columns,
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      let setupSlave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
      guard setupSlave >= 0, ioctl(setupSlave, TIOCSWINSZ, &windowSize) == 0 else {
        if setupSlave >= 0 { Darwin.close(setupSlave) }
        Darwin.close(master)
        throw RuntimeError.launchFailed("Could not set pseudo-terminal dimensions")
      }
      var transferredSetupSlave = false
      defer {
        if !transferredSetupSlave { Darwin.close(setupSlave) }
      }

      var fileActions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
      guard posix_spawn_file_actions_init(&fileActions) == 0,
        posix_spawnattr_init(&attributes) == 0
      else {
        Darwin.close(master)
        throw RuntimeError.launchFailed("Could not initialize process spawn attributes")
      }
      defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
      }

      let chdirResult: Int32
      if #available(macOS 26.0, *) {
        chdirResult = posix_spawn_file_actions_addchdir(&fileActions, workingDirectory)
      } else {
        chdirResult = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
      }
      let openResult = posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        slavePath,
        O_RDWR,
        0
      )
      let setupSlaveInheritResult = posix_spawn_file_actions_addinherit_np(
        &fileActions, setupSlave)
      let supervisorLifetimeInheritResult = posix_spawn_file_actions_addinherit_np(
        &fileActions, supervisorLifetimeRead)
      let stdoutResult = posix_spawn_file_actions_adddup2(
        &fileActions, setupSlave, STDOUT_FILENO)
      let stderrResult = posix_spawn_file_actions_adddup2(
        &fileActions, setupSlave, STDERR_FILENO)
      let setupSlaveCloseResult = posix_spawn_file_actions_addclose(
        &fileActions, setupSlave)
      let closeResult = posix_spawn_file_actions_addclose(&fileActions, master)
      guard chdirResult == 0, openResult == 0, stdoutResult == 0, stderrResult == 0,
        setupSlaveInheritResult == 0, supervisorLifetimeInheritResult == 0,
        setupSlaveCloseResult == 0, closeResult == 0
      else {
        Darwin.close(master)
        throw RuntimeError.launchFailed("Could not configure pseudo-terminal process actions")
      }

      var emptySignalSet = sigset_t()
      sigemptyset(&emptySignalSet)
      var defaultSignals = sigset_t()
      sigemptyset(&defaultSignals)
      for signal in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { sigaddset(&defaultSignals, signal) }
      let flags = Int16(
        POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_SETSIGDEF)
      guard posix_spawnattr_setflags(&attributes, flags) == 0,
        posix_spawnattr_setsigmask(&attributes, &emptySignalSet) == 0,
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0
      else {
        Darwin.close(master)
        throw RuntimeError.launchFailed("Could not configure process session attributes")
      }

      var pid: pid_t = 0
      let spawnResult = posix_spawn(
        &pid,
        executable,
        &fileActions,
        &attributes,
        argumentVector,
        environmentVector
      )
      guard spawnResult == 0, pid > 0 else {
        Darwin.close(master)
        throw RuntimeError.launchFailed(String(cString: strerror(spawnResult)))
      }

      let descriptorFlags = fcntl(master, F_GETFD)
      let statusFlags = fcntl(master, F_GETFL)
      guard descriptorFlags >= 0,
        fcntl(master, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
        statusFlags >= 0,
        fcntl(master, F_SETFL, statusFlags | O_NONBLOCK) == 0
      else {
        Darwin.close(master)
        kill(pid, SIGTERM)
        throw RuntimeError.launchFailed("Could not configure nonblocking PTY transport")
      }
      let process = PTYProcess(
        processIdentifier: pid,
        masterFileDescriptor: master,
        setupSlaveFileDescriptor: setupSlave,
        supervisorLifetimeWriteFileDescriptor: supervisorLifetimeWrite,
        columns: specification.columns,
        rows: specification.rows
      )
      process.observeExit()
      transferredSetupSlave = true
      transferredSupervisorLifetimeWrite = true
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
            let written = Darwin.write(
              masterFileDescriptor, baseAddress.advanced(by: offset), remaining)
            if written < 0 {
              if errno == EINTR { continue }
              if errno == EAGAIN || errno == EWOULDBLOCK {
                var descriptor = pollfd(
                  fd: masterFileDescriptor, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, 1_000) > 0 else {
                  throw RuntimeError.transportClosed
                }
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

    /// Whether the terminal currently echoes typed characters. Programs turn echo off while they
    /// read a password or secret (`read -s`), so Otto can say typing is hidden there. Reading the
    /// line discipline never consumes input; a closed transport reports echo on.
    public var echoesInput: Bool {
      stateLock.withLock {
        guard !isClosed else { return true }
        var attributes = termios()
        guard tcgetattr(masterFileDescriptor, &attributes) == 0 else { return true }
        return (attributes.c_lflag & tcflag_t(ECHO)) != 0
      }
    }

    public func resize(columns: UInt16, rows: UInt16) throws {
      let unchanged = try stateLock.withLock {
        guard !isClosed else { throw RuntimeError.transportClosed }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFileDescriptor, TIOCSWINSZ, &size) == 0 else {
          throw RuntimeError.transportClosed
        }
        let unchanged = self.columns == columns && self.rows == rows
        self.columns = columns
        self.rows = rows
        return unchanged
      }
      if unchanged { try signalForegroundProcessGroup(SIGWINCH) }
    }

    public func interrupt() throws {
      try send(Data([0x03]))
    }

    public func terminate() throws {
      try signalForegroundProcessGroup(SIGTERM)
    }

    public func forceTerminate() throws {
      try signalForegroundProcessGroup(SIGKILL)
    }

    /// Closes Otto's supervision lease and PTY transport. The independent lifetime monitor
    /// terminates the whole provider process group even if the provider ignores terminal EOF.
    public func close() {
      closeSupervisorLifetimeIfNeeded()
      closeTransportIfNeeded()
    }

    private func drainOutput(final: Bool = false) {
      while true {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var readError: Int32 = 0
        let count = stateLock.withLock {
          guard !isClosed else { return Int.min }
          let value = Darwin.read(masterFileDescriptor, &bytes, bytes.count)
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

    private func signalExit(exitCode: Int32) {
      exitContinuation.yield(exitCode)
      exitContinuation.finish()
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
      // alive: closing the last slave fd discards any unread master-side data.
      drainOutput()
      closeSetupSlaveIfNeeded()
      drainOutput()
      closeSupervisorLifetimeIfNeeded()
      signalExit(exitCode: code)
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
      closeTransportIfNeeded()
    }

    private func closeSetupSlaveIfNeeded() {
      stateLock.withLock {
        guard let descriptor = setupSlaveFileDescriptor else { return }
        setupSlaveFileDescriptor = nil
        Darwin.close(descriptor)
      }
    }

    private func signalForegroundProcessGroup(_ signal: Int32) throws {
      var foregroundGroup: pid_t = 0
      if ioctl(masterFileDescriptor, TIOCGPGRP, &foregroundGroup) == 0,
        foregroundGroup > 0,
        kill(-foregroundGroup, signal) == 0
      {
        return
      }
      guard kill(processIdentifier, signal) == 0 || errno == ESRCH else {
        throw RuntimeError.transportClosed
      }
    }

    private func closeSupervisorLifetimeIfNeeded() {
      stateLock.withLock {
        guard let descriptor = supervisorLifetimeWriteFileDescriptor else { return }
        supervisorLifetimeWriteFileDescriptor = nil
        Darwin.close(descriptor)
      }
    }

    private func closeTransportIfNeeded() {
      stateLock.withLock {
        guard !isClosed else { return }
        isClosed = true
        if let descriptor = setupSlaveFileDescriptor {
          setupSlaveFileDescriptor = nil
          Darwin.close(descriptor)
        }
        readSource.cancel()
      }
    }
  }
#endif

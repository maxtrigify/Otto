#if os(Windows)
  import Foundation
  import WinSDK

  /// POSIX process identifiers; Windows process IDs are DWORDs that fit in 32 bits.
  public typealias pid_t = Int32

  /// A provider process attached to a Windows pseudo console (ConPTY), with the same surface as
  /// the Darwin and Linux `PTYProcess`. The process runs inside a job object so stopping it, or
  /// ottod exiting, takes its whole tree (shells, node, git) down with it.
  public final class PTYProcess: @unchecked Sendable {
    public let processIdentifier: pid_t
    public let output: AsyncStream<Data>
    public let exit: AsyncStream<Int32>

    private let console: HPCON
    private let inputWrite: HANDLE
    private let outputRead: HANDLE
    private let processHandle: HANDLE
    private let job: HANDLE
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Int32>.Continuation
    private let stateLock = NSLock()
    private var isClosed = false

    /// `ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)`; the macro is not imported into Swift.
    private static let pseudoConsoleAttribute = DWORD_PTR(0x0002_0016)

    private init(
      processIdentifier: pid_t, console: HPCON, inputWrite: HANDLE, outputRead: HANDLE,
      processHandle: HANDLE, job: HANDLE
    ) {
      self.processIdentifier = processIdentifier
      self.console = console
      self.inputWrite = inputWrite
      self.outputRead = outputRead
      self.processHandle = processHandle
      self.job = job
      var outputContinuation: AsyncStream<Data>.Continuation!
      output = AsyncStream(bufferingPolicy: .unbounded) { outputContinuation = $0 }
      self.outputContinuation = outputContinuation
      var exitContinuation: AsyncStream<Int32>.Continuation!
      exit = AsyncStream(bufferingPolicy: .unbounded) { exitContinuation = $0 }
      self.exitContinuation = exitContinuation
    }

    public static func spawn(_ specification: ProcessLaunchSpec) throws -> PTYProcess {
      var inputRead: HANDLE?
      var inputWrite: HANDLE?
      var outputRead: HANDLE?
      var outputWrite: HANDLE?
      guard CreatePipe(&inputRead, &inputWrite, nil, 0) else { throw lastError("CreatePipe") }
      guard CreatePipe(&outputRead, &outputWrite, nil, 0) else {
        CloseHandle(inputRead)
        CloseHandle(inputWrite)
        throw lastError("CreatePipe")
      }

      var console: HPCON?
      let size = COORD(X: SHORT(clamping: specification.columns), Y: SHORT(clamping: specification.rows))
      let created = CreatePseudoConsole(size, inputRead, outputWrite, 0, &console)
      // The pseudo console holds its own duplicates of the far ends.
      CloseHandle(inputRead)
      CloseHandle(outputWrite)
      guard created == S_OK, let console else {
        CloseHandle(inputWrite)
        CloseHandle(outputRead)
        throw RuntimeError.launchFailed("CreatePseudoConsole failed (\(created))")
      }

      guard let job = CreateJobObjectW(nil, nil) else {
        ClosePseudoConsole(console)
        CloseHandle(inputWrite)
        CloseHandle(outputRead)
        throw lastError("CreateJobObject")
      }
      var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
      limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
      _ = SetInformationJobObject(
        job, JobObjectExtendedLimitInformation, &limits,
        DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))

      var attributeListSize: SIZE_T = 0
      _ = InitializeProcThreadAttributeList(nil, 1, 0, &attributeListSize)
      let attributeStorage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(attributeListSize), alignment: 16)
      defer { attributeStorage.deallocate() }
      let attributeList = LPPROC_THREAD_ATTRIBUTE_LIST(attributeStorage)
      guard InitializeProcThreadAttributeList(attributeList, 1, 0, &attributeListSize) else {
        cleanup(console: console, inputWrite: inputWrite, outputRead: outputRead, job: job)
        throw lastError("InitializeProcThreadAttributeList")
      }
      defer { DeleteProcThreadAttributeList(attributeList) }
      guard
        UpdateProcThreadAttribute(
          attributeList, 0, pseudoConsoleAttribute, console,
          SIZE_T(MemoryLayout<HPCON>.size), nil, nil)
      else {
        cleanup(console: console, inputWrite: inputWrite, outputRead: outputRead, job: job)
        throw lastError("UpdateProcThreadAttribute")
      }

      var startup = STARTUPINFOEXW()
      startup.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
      // ottod's own stdio is the desktop app's protocol pipe. Without explicit null standard
      // handles the child inherits those pipes and bypasses the pseudo console entirely.
      startup.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
      startup.StartupInfo.hStdInput = nil
      startup.StartupInfo.hStdOutput = nil
      startup.StartupInfo.hStdError = nil
      startup.lpAttributeList = attributeList
      var information = PROCESS_INFORMATION()

      var commandLine = wide(
        ([specification.executable] + specification.arguments).map(quoteArgument)
          .joined(separator: " "))
      var environment = environmentBlock(
        specification.resolvedEnvironment(inheriting: ProcessInfo.processInfo.environment))
      let directory = wide(specification.workingDirectory)
      let flags = DWORD(EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED)

      let launched = commandLine.withUnsafeMutableBufferPointer { command in
        environment.withUnsafeMutableBufferPointer { block in
          directory.withUnsafeBufferPointer { cwd in
            withUnsafeMutablePointer(to: &startup) { startupPointer in
              startupPointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { info in
                CreateProcessW(
                  nil, command.baseAddress, nil, nil, false, flags, block.baseAddress,
                  cwd.baseAddress, info, &information)
              }
            }
          }
        }
      }
      guard launched else {
        cleanup(console: console, inputWrite: inputWrite, outputRead: outputRead, job: job)
        throw lastError("CreateProcess")
      }
      _ = AssignProcessToJobObject(job, information.hProcess)
      ResumeThread(information.hThread)
      CloseHandle(information.hThread)

      let process = PTYProcess(
        processIdentifier: pid_t(bitPattern: information.dwProcessId),
        console: console,
        inputWrite: inputWrite!,
        outputRead: outputRead!,
        processHandle: information.hProcess,
        job: job)
      process.startReading()
      process.startWaiting()
      return process
    }

    public func send(_ data: Data) throws {
      try stateLock.withLock {
        guard !isClosed else { throw RuntimeError.transportClosed }
        try data.withUnsafeBytes { buffer in
          guard let base = buffer.baseAddress else { return }
          var offset = 0
          while offset < buffer.count {
            var written: DWORD = 0
            guard
              WriteFile(
                inputWrite, base.advanced(by: offset), DWORD(buffer.count - offset), &written, nil)
            else { throw RuntimeError.transportClosed }
            offset += Int(written)
          }
        }
      }
    }

    public func send(text: String) throws {
      try send(Data(text.utf8))
    }

    /// ConPTY does not expose the console's echo mode to the host; report echo on.
    public var echoesInput: Bool { true }

    public func resize(columns: UInt16, rows: UInt16) throws {
      try stateLock.withLock {
        guard !isClosed else { throw RuntimeError.transportClosed }
        let result = ResizePseudoConsole(
          console, COORD(X: SHORT(clamping: columns), Y: SHORT(clamping: rows)))
        guard result == S_OK else { throw RuntimeError.transportClosed }
      }
    }

    /// Ctrl+C through the pseudo console, as a terminal user would type it.
    public func interrupt() throws { try send(Data([0x03])) }

    public func terminate() throws { _ = TerminateJobObject(job, 1) }

    public func forceTerminate() throws { _ = TerminateJobObject(job, 1) }

    private func startReading() {
      // Only this thread reads the pipe; the handle is closed after the stream finishes.
      nonisolated(unsafe) let handle = outputRead
      let continuation = outputContinuation
      Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
          var read: DWORD = 0
          let succeeded = buffer.withUnsafeMutableBytes { bytes in
            ReadFile(handle, bytes.baseAddress, DWORD(bytes.count), &read, nil)
          }
          guard succeeded, read > 0 else { break }
          continuation.yield(Data(buffer[0..<Int(read)]))
        }
        continuation.finish()
      }
    }

    private func startWaiting() {
      Thread.detachNewThread { [self] in
        WaitForSingleObject(processHandle, INFINITE)
        var code: DWORD = 0
        _ = GetExitCodeProcess(processHandle, &code)
        // Closing the pseudo console flushes and breaks the output pipe, ending the reader.
        close()
        exitContinuation.yield(Int32(bitPattern: code))
        exitContinuation.finish()
      }
    }

    private func close() {
      let shouldClose = stateLock.withLock {
        guard !isClosed else { return false }
        isClosed = true
        return true
      }
      guard shouldClose else { return }
      ClosePseudoConsole(console)
      CloseHandle(inputWrite)
      CloseHandle(processHandle)
      CloseHandle(job)
    }

    deinit {
      close()
      CloseHandle(outputRead)
    }

    private static func cleanup(console: HPCON, inputWrite: HANDLE?, outputRead: HANDLE?, job: HANDLE) {
      ClosePseudoConsole(console)
      CloseHandle(inputWrite)
      CloseHandle(outputRead)
      CloseHandle(job)
    }

    private static func lastError(_ call: String) -> RuntimeError {
      RuntimeError.launchFailed("\(call) failed (Windows error \(GetLastError()))")
    }

    private static func wide(_ string: String) -> [WCHAR] {
      Array(string.utf16) + [0]
    }

    /// CreateProcess's argv parsing rules (backslashes only escape before a quote).
    static func quoteArgument(_ argument: String) -> String {
      guard argument.isEmpty || argument.contains(where: { " \t\n\u{0B}\"".contains($0) }) else {
        return argument
      }
      var quoted = "\""
      var backslashes = 0
      for character in argument {
        if character == "\\" {
          backslashes += 1
        } else if character == "\"" {
          quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
          backslashes = 0
        } else {
          quoted += String(repeating: "\\", count: backslashes) + String(character)
          backslashes = 0
        }
      }
      return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    /// A sorted, double-NUL-terminated UTF-16 environment block.
    private static func environmentBlock(_ environment: [String: String]) -> [WCHAR] {
      var block: [WCHAR] = []
      for key in environment.keys.sorted(by: { $0.uppercased() < $1.uppercased() }) {
        block += Array("\(key)=\(environment[key] ?? "")".utf16) + [0]
      }
      return block + [0]
    }
  }
#endif

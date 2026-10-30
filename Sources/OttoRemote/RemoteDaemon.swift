import Foundation
import OttoRuntime
import OttoTools

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import ucrt  // not WinSDK: its UUID typedef shadows Foundation.UUID
#else
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#endif

public actor RemoteDaemon {
  public let id: UUID
  public let limits: RemoteResourceLimits
  private var token: [UInt8]
  private let tokenFile: URL?
  private let workspaceRoots: [String]
  private let journal: RemoteEventJournal
  private var sessions: [UUID: PTYProcess] = [:]

  public init(
    token: String,
    tokenFile: URL? = nil,
    stateDirectory: URL,
    workspaceRoots: [URL],
    limits: RemoteResourceLimits = RemoteResourceLimits()
  ) throws {
    guard token.utf8.count >= 32 else {
      throw RemoteError.invalidInput("authentication tokens must contain at least 32 bytes")
    }
    guard limits.maximumSessions > 0, limits.maximumEventPage > 0,
      limits.maximumInputBytes > 0,
      limits.maximumJournalBytes > 0
        && limits.maximumTransferBytes > 0
    else { throw RemoteError.invalidInput("resource limits must be positive") }
    let canonicalRoots = try workspaceRoots.map(Self.canonicalDirectory)
    guard !canonicalRoots.isEmpty else {
      throw RemoteError.invalidInput("at least one workspace root is required")
    }
    self.id = UUID()
    self.token = Array(token.utf8)
    self.tokenFile = tokenFile
    self.workspaceRoots = canonicalRoots
    self.limits = limits
    self.journal = try RemoteEventJournal(
      url: stateDirectory.appending(path: "events.jsonl"),
      maximumBytes: limits.maximumJournalBytes
    )
  }

  public func handle(_ request: RemoteRequest) async -> RemoteResponse {
    guard Self.constantTimeEqual(Array(request.token.utf8), token) else {
      return failure(request.id, code: "unauthorized", error: RemoteError.unauthorized)
    }
    do {
      let result: JSONValue
      switch request.method {
      case .hello:
        let input = try decode(RemoteCursorInput.self, from: request.parameters)
        result = try JSONValue.encode(
          RemoteHello(
            protocolVersion: RemoteProtocol.version,
            daemonVersion: "0.1.0",
            daemonID: id,
            activeSessionIDs: sessions.keys.sorted { $0.uuidString < $1.uuidString },
            eventPage: try await eventPage(input)
          ))
      case .heartbeat:
        result = try JSONValue.encode(heartbeat())
      case .events:
        result = try JSONValue.encode(
          try await eventPage(decode(RemoteCursorInput.self, from: request.parameters)))
      case .launch:
        result = try JSONValue.encode(
          RemoteSessionOutput(
            sessionID: try await launch(
              decode(RemoteLaunchInput.self, from: request.parameters))))
      case .input:
        let input = try decode(RemoteTerminalInput.self, from: request.parameters)
        try send(input)
        result = .object(["accepted": .bool(true)])
      case .resize:
        let input = try decode(RemoteResizeInput.self, from: request.parameters)
        try resize(input)
        result = .object(["accepted": .bool(true)])
      case .stop:
        let input = try decode(RemoteSessionInput.self, from: request.parameters)
        try await stop(input.sessionID)
        result = .object(["accepted": .bool(true)])
      case .fileRead:
        result = try JSONValue.encode(
          try readFile(decode(RemoteFileReadInput.self, from: request.parameters)))
      case .fileWrite:
        result = try JSONValue.encode(
          try writeFile(decode(RemoteFileWriteInput.self, from: request.parameters)))
      case .tokenRotate:
        try rotateToken(decode(RemoteTokenRotateInput.self, from: request.parameters))
        result = .object(["accepted": .bool(true)])
      }
      return RemoteResponse(id: request.id, result: result)
    } catch {
      return failure(request.id, code: code(for: error), error: error)
    }
  }

  public func heartbeat() -> RemoteHeartbeat {
    RemoteHeartbeat(
      daemonID: id,
      timestamp: .now,
      activeSessions: sessions.count,
      processorCount: ProcessInfo.processInfo.processorCount,
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
    )
  }

  public func eventPage(_ input: RemoteCursorInput) async throws -> RemoteEventPage {
    guard input.afterSequence >= 0 else {
      throw RemoteError.invalidInput("event cursor cannot be negative")
    }
    guard (1...limits.maximumEventPage).contains(input.limit) else {
      throw RemoteError.resourceLimit("event page exceeds \(limits.maximumEventPage)")
    }
    return await journal.page(after: input.afterSequence, limit: input.limit)
  }

  private func launch(_ input: RemoteLaunchInput) async throws -> UUID {
    guard sessions.count < limits.maximumSessions else {
      throw RemoteError.resourceLimit("maximum concurrent sessions reached")
    }
    guard input.columns > 0, input.columns <= limits.maximumColumns,
      input.rows > 0, input.rows <= limits.maximumRows
    else { throw RemoteError.resourceLimit("terminal dimensions exceed configured bounds") }
    let workspace = try Self.canonicalDirectory(URL(fileURLWithPath: input.workspacePath))
    guard workspaceRoots.contains(where: { Self.contains(workspace, root: $0) }) else {
      throw RemoteError.workspaceDenied
    }
    guard RemotePath.isAbsolute(input.executable),
      FileManager.default.isExecutableFile(atPath: input.executable)
    else { throw RemoteError.invalidInput("the executable must be an absolute executable path") }
    let sessionID = UUID()
    let process = try PTYProcess.spawn(
      ProcessLaunchSpec(
        executable: input.executable,
        arguments: input.arguments,
        workingDirectory: workspace,
        columns: input.columns,
        rows: input.rows
      ))
    sessions[sessionID] = process
    _ = try await journal.append(
      kind: .sessionStarted,
      sessionID: sessionID,
      payload: .object(["pid": .number(Double(process.processIdentifier))])
    )
    Task { [weak self] in await self?.capture(process, sessionID: sessionID) }
    return sessionID
  }

  private func capture(_ process: PTYProcess, sessionID: UUID) async {
    for await data in process.output {
      _ = try? await journal.append(
        kind: .outputAppended,
        sessionID: sessionID,
        payload: .object(["data": .string(data.base64EncodedString())])
      )
    }
    var exitCode: Int32 = -1
    for await code in process.exit { exitCode = code }
    sessions.removeValue(forKey: sessionID)
    _ = try? await journal.append(
      kind: .sessionExited,
      sessionID: sessionID,
      payload: .object(["exitCode": .number(Double(exitCode))])
    )
  }

  private func send(_ input: RemoteTerminalInput) throws {
    guard input.data.count <= limits.maximumInputBytes else {
      throw RemoteError.resourceLimit("terminal input exceeds \(limits.maximumInputBytes) bytes")
    }
    guard let process = sessions[input.sessionID] else { throw RemoteError.sessionNotFound }
    try process.send(input.data)
  }

  private func resize(_ input: RemoteResizeInput) throws {
    guard input.columns > 0, input.columns <= limits.maximumColumns,
      input.rows > 0, input.rows <= limits.maximumRows
    else { throw RemoteError.resourceLimit("terminal dimensions exceed configured bounds") }
    guard let process = sessions[input.sessionID] else { throw RemoteError.sessionNotFound }
    try process.resize(columns: input.columns, rows: input.rows)
  }

  private func stop(_ sessionID: UUID) async throws {
    guard let process = sessions[sessionID] else { throw RemoteError.sessionNotFound }
    try process.terminate()
    _ = try await journal.append(kind: .sessionStopped, sessionID: sessionID)
  }

  private func readFile(_ input: RemoteFileReadInput) throws -> RemoteFileOutput {
    let url = try confinedFileURL(
      workspacePath: input.workspacePath,
      relativePath: input.relativePath,
      mustExist: true
    )
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw RemoteError.invalidInput("only regular files can be transferred")
    }
    let size = values.fileSize ?? 0
    guard size <= limits.maximumTransferBytes else {
      throw RemoteError.resourceLimit("file exceeds \(limits.maximumTransferBytes) bytes")
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= limits.maximumTransferBytes else {
      throw RemoteError.resourceLimit("file exceeds \(limits.maximumTransferBytes) bytes")
    }
    return RemoteFileOutput(data: data, byteCount: data.count)
  }

  private func writeFile(_ input: RemoteFileWriteInput) throws -> RemoteFileOutput {
    guard input.data.count <= limits.maximumTransferBytes else {
      throw RemoteError.resourceLimit("file exceeds \(limits.maximumTransferBytes) bytes")
    }
    let url = try confinedFileURL(
      workspacePath: input.workspacePath,
      relativePath: input.relativePath,
      mustExist: false
    )
    if FileManager.default.fileExists(atPath: url.path), !input.overwrite {
      throw RemoteError.invalidInput("destination exists and overwrite was not requested")
    }
    try input.data.write(to: url, options: [.atomic])
    return RemoteFileOutput(data: Data(), byteCount: input.data.count)
  }

  private func confinedFileURL(
    workspacePath: String,
    relativePath: String,
    mustExist: Bool
  ) throws -> URL {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
      !relativePath.split(separator: "/").contains(".."),
      !relativePath.utf8.contains(0)
    else { throw RemoteError.invalidInput("file paths must be safe workspace-relative paths") }
    let workspace = try Self.canonicalDirectory(URL(fileURLWithPath: workspacePath))
    guard workspaceRoots.contains(where: { Self.contains(workspace, root: $0) }) else {
      throw RemoteError.workspaceDenied
    }
    let candidate = URL(fileURLWithPath: workspace, isDirectory: true)
      .appending(path: relativePath)
      .standardizedFileURL
    let parent = try Self.canonicalDirectory(candidate.deletingLastPathComponent())
    guard Self.contains(parent, root: workspace) else { throw RemoteError.workspaceDenied }
    if mustExist {
      guard let canonical = RemotePath.resolve(candidate.path) else {
        throw RemoteError.invalidInput("requested file does not exist")
      }
      guard Self.contains(canonical, root: workspace) else { throw RemoteError.workspaceDenied }
      return URL(fileURLWithPath: canonical)
    }
    return URL(fileURLWithPath: parent, isDirectory: true)
      .appending(path: candidate.lastPathComponent)
  }

  private func rotateToken(_ input: RemoteTokenRotateInput) throws {
    guard input.newToken.utf8.count >= 32 else {
      throw RemoteError.invalidInput("authentication tokens must contain at least 32 bytes")
    }
    if let tokenFile {
      let directory = tokenFile.deletingLastPathComponent()
      guard FileManager.default.isWritableFile(atPath: directory.path) else {
        throw RemoteError.invalidInput("token directory is not writable")
      }
      let temporary = directory.appending(path: ".ottod-token-\(UUID().uuidString)")
      guard
        FileManager.default.createFile(
          atPath: temporary.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        )
      else { throw RemoteError.invalidInput("could not create a protected token file") }
      do {
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.write(contentsOf: Data((input.newToken + "\n").utf8))
        try handle.synchronize()
        try handle.close()
        RemotePath.restrict(temporary.path, mode: 0o600)
        guard RemotePath.replace(temporary.path, with: tokenFile.path) else {
          throw RemoteError.invalidInput("could not atomically replace the token file")
        }
      } catch {
        RemotePath.remove(temporary.path)
        throw error
      }
    }
    token = Array(input.newToken.utf8)
  }

  private func decode<T: Decodable & Sendable>(_ type: T.Type, from value: JSONValue?) throws -> T {
    guard let value else { throw RemoteError.invalidInput("parameters are required") }
    do { return try value.decode(type) } catch {
      throw RemoteError.invalidInput("parameters do not match \(String(describing: type))")
    }
  }

  private func failure(_ id: String, code: String, error: Error) -> RemoteResponse {
    RemoteResponse(
      id: id,
      error: RemoteFailure(code: code, message: error.localizedDescription)
    )
  }

  private func code(for error: Error) -> String {
    guard let remote = error as? RemoteError else { return "internal_error" }
    return switch remote {
    case .unauthorized: "unauthorized"
    case .invalidInput: "invalid_input"
    case .workspaceDenied: "workspace_denied"
    case .sessionNotFound: "session_not_found"
    case .resourceLimit: "resource_limit"
    case .journal: "journal_error"
    }
  }

  private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference = UInt(lhs.count ^ rhs.count)
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= UInt(left ^ right)
    }
    return difference == 0
  }

  private static func canonicalDirectory(_ url: URL) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let resolved = RemotePath.resolve(url.path)
    else { throw RemoteError.invalidInput("workspace directories must exist") }
    return resolved
  }

  private static func contains(_ candidate: String, root: String) -> Bool {
    RemotePath.contains(candidate, root: root)
  }
}

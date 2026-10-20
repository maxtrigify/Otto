import Foundation
import OttoRemote
import OttoTools
import Testing

@Suite("Remote daemon")
struct RemoteDaemonTests {
  @Test("Journal persists contiguous events and reconnect cursors")
  func journalPersistence() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let url = fixture.state.appending(path: "journal.jsonl")
    let journal = try RemoteEventJournal(url: url, maximumBytes: 1_048_576)
    let sessionID = UUID()
    let first = try await journal.append(kind: .sessionStarted, sessionID: sessionID)
    let second = try await journal.append(
      kind: .outputAppended,
      sessionID: sessionID,
      payload: .object(["data": .string(Data("hello".utf8).base64EncodedString())])
    )
    #expect(first.sequence == 1)
    #expect(second.sequence == 2)

    let restored = try RemoteEventJournal(url: url, maximumBytes: 1_048_576)
    let page = await restored.page(after: 1, limit: 10)
    #expect(page.events == [second])
    #expect(page.latestSequence == 2)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }

  @Test("PTY survives a logical disconnect and replays output after its cursor")
  func reconnectReplay() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let daemon = try fixture.daemon()
    let launch = RemoteLaunchInput(
      executable: "/bin/sh",
      arguments: ["-lc", "printf 'before\\n'; sleep 0.08; printf 'after\\n'"],
      workspacePath: fixture.workspace.path
    )
    let response = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .launch,
        parameters: try JSONValue.encode(launch)
      ))
    let session = try #require(try response.result?.decode(RemoteSessionOutput.self))
    let initial = try await daemon.eventPage(RemoteCursorInput(afterSequence: 0, limit: 10))
    #expect(initial.events.contains { $0.kind == .sessionStarted })
    let cursor = initial.latestSequence

    let deadline = ContinuousClock.now + .seconds(5)
    var latestHello: RemoteHello?
    while ContinuousClock.now < deadline {
      let reconnect = await daemon.handle(
        RemoteRequest(
          token: fixture.token,
          method: .hello,
          parameters: try JSONValue.encode(
            RemoteCursorInput(afterSequence: cursor, limit: 20))
        ))
      latestHello = try reconnect.result?.decode(RemoteHello.self)
      if latestHello?.eventPage.events.contains(where: { $0.kind == .sessionExited }) == true {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let hello = try #require(latestHello)
    #expect(hello.protocolVersion == RemoteProtocol.version)
    #expect(hello.eventPage.events.allSatisfy { $0.sequence > cursor })
    #expect(hello.eventPage.events.contains { $0.sessionID == session.sessionID })
    #expect(hello.eventPage.events.contains { $0.kind == .sessionExited })
    let output = hello.eventPage.events
      .filter { $0.kind == .outputAppended }
      .compactMap { $0.payload?["data"]?.stringValue }
      .compactMap { Data(base64Encoded: $0) }
      .reduce(into: Data()) { $0.append($1) }
    #expect(String(decoding: output, as: UTF8.self).contains("after"))
  }

  @Test("Authentication, workspace confinement, and resource limits fail closed")
  func securityAndLimits() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let limits = RemoteResourceLimits(
      maximumSessions: 1,
      maximumEventPage: 2,
      maximumInputBytes: 4,
      maximumColumns: 120,
      maximumRows: 40,
      maximumJournalBytes: 1_048_576
    )
    let daemon = try fixture.daemon(limits: limits)
    let denied = await daemon.handle(RemoteRequest(token: "x", method: .heartbeat))
    #expect(denied.error?.code == "unauthorized")

    let outside = RemoteLaunchInput(
      executable: "/bin/sh",
      arguments: ["-lc", "true"],
      workspacePath: "/tmp"
    )
    let outsideResponse = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .launch,
        parameters: try JSONValue.encode(outside)
      ))
    #expect(outsideResponse.error?.code == "workspace_denied")

    let longRun = RemoteLaunchInput(
      executable: "/bin/sh",
      arguments: ["-lc", "sleep 2"],
      workspacePath: fixture.workspace.path
    )
    let first = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .launch,
        parameters: try JSONValue.encode(longRun)
      ))
    let session = try #require(try first.result?.decode(RemoteSessionOutput.self))
    let second = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .launch,
        parameters: try JSONValue.encode(longRun)
      ))
    #expect(second.error?.code == "resource_limit")
    let oversized = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .input,
        parameters: try JSONValue.encode(
          RemoteTerminalInput(sessionID: session.sessionID, data: Data("12345".utf8)))
      ))
    #expect(oversized.error?.code == "resource_limit")
    _ = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .stop,
        parameters: try JSONValue.encode(RemoteSessionInput(sessionID: session.sessionID))
      ))
  }

  @Test("Heartbeat reports content-free health metrics")
  func heartbeat() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let daemon = try fixture.daemon()
    let heartbeat = await daemon.heartbeat()
    #expect(heartbeat.activeSessions == 0)
    #expect(heartbeat.processorCount > 0)
    #expect(heartbeat.physicalMemoryBytes > 0)
  }

  @Test("File transfer is atomic, bounded, and confined to registered workspaces")
  func fileTransfer() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = fixture.workspace.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let daemon = try fixture.daemon(
      limits: RemoteResourceLimits(maximumTransferBytes: 16))

    let write = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .fileWrite,
        parameters: try JSONValue.encode(
          RemoteFileWriteInput(
            workspacePath: fixture.workspace.path,
            relativePath: "artifact.txt",
            data: Data("remote artifact".utf8)
          ))
      ))
    #expect(try write.result?.decode(RemoteFileOutput.self).byteCount == 15)
    let read = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .fileRead,
        parameters: try JSONValue.encode(
          RemoteFileReadInput(
            workspacePath: fixture.workspace.path,
            relativePath: "artifact.txt"
          ))
      ))
    #expect(try read.result?.decode(RemoteFileOutput.self).data == Data("remote artifact".utf8))

    let traversal = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .fileRead,
        parameters: try JSONValue.encode(
          RemoteFileReadInput(workspacePath: fixture.workspace.path, relativePath: "../secret"))
      ))
    #expect(traversal.error?.code == "invalid_input")
    let symlinkEscape = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .fileWrite,
        parameters: try JSONValue.encode(
          RemoteFileWriteInput(
            workspacePath: fixture.workspace.path,
            relativePath: "escape/stolen.txt",
            data: Data("no".utf8)
          ))
      ))
    #expect(symlinkEscape.error?.code == "workspace_denied")
    let oversized = await daemon.handle(
      RemoteRequest(
        token: fixture.token,
        method: .fileWrite,
        parameters: try JSONValue.encode(
          RemoteFileWriteInput(
            workspacePath: fixture.workspace.path,
            relativePath: "large.bin",
            data: Data(repeating: 0, count: 17)
          ))
      ))
    #expect(oversized.error?.code == "resource_limit")
  }

  @Test("Private socket reconnects to the same persistent daemon and cursor")
  func socketReconnect() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let daemon = try fixture.daemon()
    let socket = fixture.state.appending(path: "ottod.sock").path
    let server = try RemoteSocketServer(socketPath: socket, daemon: daemon)
    defer { server.stop() }
    let firstClient = RemoteSocketClient(socketPath: socket, token: fixture.token)
    let launch = RemoteLaunchInput(
      executable: "/bin/sh",
      arguments: ["-lc", "IFS= read line; printf 'remote-socket:%s\\n' \"$line\""],
      workspacePath: fixture.workspace.path
    )
    let session = try await firstClient.request(.launch, parameters: launch)
      .decode(RemoteSessionOutput.self)
    let initial = try await firstClient.request(
      .events,
      parameters: RemoteCursorInput(afterSequence: 0, limit: 10)
    ).decode(RemoteEventPage.self)
    let cursor = initial.latestSequence

    let reconnectedClient = RemoteSocketClient(socketPath: socket, token: fixture.token)
    _ = try await reconnectedClient.request(
      .input,
      parameters: RemoteTerminalInput(
        sessionID: session.sessionID,
        data: Data("resume\n".utf8)
      ))
    let deadline = ContinuousClock.now + .seconds(10)
    var latestHello: RemoteHello?
    while ContinuousClock.now < deadline {
      let candidate = try await reconnectedClient.request(
        .hello,
        parameters: RemoteCursorInput(afterSequence: cursor, limit: 20)
      ).decode(RemoteHello.self)
      latestHello = candidate
      if candidate.eventPage.events.contains(where: { $0.kind == .sessionExited }) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let hello = try #require(latestHello)
    let daemonID = await daemon.id
    #expect(hello.daemonID == daemonID)
    #expect(hello.eventPage.events.contains { $0.sessionID == session.sessionID })
    #expect(hello.eventPage.events.contains { $0.kind == .sessionExited })
    let permissions =
      try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions]
      as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }

  @Test("ottod serve retains its socket after startup and accepts requests")
  func serveProcessLifetime() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let tokenFile = fixture.state.appending(path: "token")
    let socket = fixture.state.appending(path: "process.sock")
    try FileManager.default.createDirectory(
      at: fixture.state,
      withIntermediateDirectories: true
    )
    try Data((fixture.token + "\n").utf8).write(to: tokenFile)
    chmod(tokenFile.path, 0o600)

    let process = Process()
    process.executableURL = try ottodExecutableURL()
    process.arguments = [
      "serve",
      "--token-file", tokenFile.path,
      "--state-dir", fixture.state.path,
      "--workspace", fixture.workspace.path,
      "--socket", socket.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let startupDeadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: socket.path),
      process.isRunning,
      ContinuousClock.now < startupDeadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(process.isRunning)
    #expect(FileManager.default.fileExists(atPath: socket.path))

    try await Task.sleep(for: .milliseconds(1_200))
    #expect(process.isRunning)
    let client = RemoteSocketClient(socketPath: socket.path, token: fixture.token)
    let hello = try await client.request(
      .hello,
      parameters: RemoteCursorInput(afterSequence: 0, limit: 10)
    ).decode(RemoteHello.self)
    #expect(hello.protocolVersion == RemoteProtocol.version)
  }

  @Test("Fleet projection exposes reconnecting, remote, offline, and completed states")
  func fleetProjection() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    let daemon = try fixture.daemon()
    let socket = fixture.state.appending(path: "fleet.sock").path
    let server = try RemoteSocketServer(socketPath: socket, daemon: daemon)
    defer { server.stop() }
    let client = RemoteSocketClient(socketPath: socket, token: fixture.token)
    let coordinator = RemoteFleetCoordinator()
    #expect(await coordinator.beginReconnect().status == .reconnecting)

    let launch = try await client.request(
      .launch,
      parameters: RemoteLaunchInput(
        executable: "/bin/sh",
        arguments: ["-lc", "IFS= read line; printf '%s\\n' \"$line\""],
        workspacePath: fixture.workspace.path
      )
    ).decode(RemoteSessionOutput.self)
    var snapshot = try await coordinator.refresh(using: client)
    #expect(snapshot.status == .remote)
    #expect(snapshot.sessions[launch.sessionID]?.state == .working)
    #expect(snapshot.processorCount ?? 0 > 0)

    #expect(await coordinator.markOffline().status == .offline)
    _ = try await client.request(
      .input,
      parameters: RemoteTerminalInput(
        sessionID: launch.sessionID,
        data: Data("done\n".utf8)
      ))
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      snapshot = try await coordinator.refresh(using: client)
      if snapshot.sessions[launch.sessionID]?.state == .done { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(snapshot.status == .remote)
    #expect(snapshot.sessions[launch.sessionID]?.state == .done)
  }

  @Test("Token rotation persists atomically and immediately revokes the old token")
  func tokenRotation() async throws {
    let fixture = try RemoteFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
    let tokenFile = fixture.state.appending(path: "token")
    try Data((fixture.token + "\n").utf8).write(to: tokenFile)
    chmod(tokenFile.path, 0o600)
    let daemon = try RemoteDaemon(
      token: fixture.token,
      tokenFile: tokenFile,
      stateDirectory: fixture.state,
      workspaceRoots: [fixture.workspace]
    )
    let socket = fixture.state.appending(path: "rotate.sock").path
    let server = try RemoteSocketServer(socketPath: socket, daemon: daemon)
    defer { server.stop() }
    let oldClient = RemoteSocketClient(socketPath: socket, token: fixture.token)
    let newToken = RemoteTokenGenerator.generate()
    _ = try await oldClient.request(
      .tokenRotate,
      parameters: RemoteTokenRotateInput(newToken: newToken)
    )
    await #expect(throws: (any Error).self) {
      try await oldClient.request(.heartbeat)
    }
    let newClient = RemoteSocketClient(socketPath: socket, token: newToken)
    let heartbeat = try await newClient.request(.heartbeat).decode(RemoteHeartbeat.self)
    let daemonID = await daemon.id
    #expect(heartbeat.daemonID == daemonID)
    #expect(
      try String(contentsOf: tokenFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines) == newToken)
    let permissions =
      try FileManager.default.attributesOfItem(atPath: tokenFile.path)[
        .posixPermissions
      ] as? NSNumber
    #expect(permissions?.intValue == 0o600)
  }
}

private struct RemoteFixture: Sendable {
  let root: URL
  let state: URL
  let workspace: URL
  let token = "otto-test-token-0123456789-abcdef"

  init() throws {
    root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(
        path: "otto-r-\(UUID().uuidString.prefix(12))",
        directoryHint: .isDirectory
      )
    state = root.appending(path: "state", directoryHint: .isDirectory)
    workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  }

  func daemon(limits: RemoteResourceLimits = RemoteResourceLimits()) throws -> RemoteDaemon {
    try RemoteDaemon(
      token: token,
      stateDirectory: state,
      workspaceRoots: [workspace],
      limits: limits
    )
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func ottodExecutableURL() throws -> URL {
  if let override = ProcessInfo.processInfo.environment["OTTO_TEST_OTTOD_EXECUTABLE"] {
    let candidate = URL(fileURLWithPath: override)
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
  }
  let origins =
    Bundle.allBundles.compactMap(\.executableURL)
    + Bundle.allFrameworks.compactMap(\.executableURL)
    + CommandLine.arguments
    .filter { $0.hasPrefix("/") }
    .map { URL(fileURLWithPath: $0) }
  for origin in origins {
    var directory = origin.standardizedFileURL.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = directory.appending(path: "ottod")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
      directory.deleteLastPathComponent()
    }
  }
  throw CocoaError(.fileNoSuchFile)
}

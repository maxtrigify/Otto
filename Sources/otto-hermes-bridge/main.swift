import Foundation
import OttoControl
import OttoMCP
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools

private enum BridgeError: Error, LocalizedError {
  case usage(String)
  case invalidRemoteURL
  case missingSessionToken
  case gateway(String)

  var errorDescription: String? {
    switch self {
    case .usage(let message): message
    case .invalidRemoteURL: "Hermes remote URL is invalid."
    case .missingSessionToken: "No Hermes session token is saved in Keychain."
    case .gateway(let message): message
    }
  }
}

private struct Options {
  var mode = HermesConnectionMode.local
  var hermesPath = "hermes"
  var remoteURL = ""
  var workingDirectory = ""
  var localWorkingDirectory = ""
  var prompt: String?
  var resumeSessionID: String?
  var profile: String?
  var model: String?
  var effort: String?
  var permissionMode = "workspaceWrite"
  var probe = false
  var ottoToolTunnel = false

  static func parse(_ arguments: [String]) throws -> Self {
    var result = Self()
    var index = 0
    while index < arguments.count {
      let flag = arguments[index]
      if flag == "--probe" {
        result.probe = true
        index += 1
        continue
      }
      // `--muse-tool-tunnel` is the pre-rename spelling of the same flag.
      if flag == "--otto-tool-tunnel" || flag == "--muse-tool-tunnel" {
        result.ottoToolTunnel = true
        index += 1
        continue
      }
      guard index + 1 < arguments.count else {
        throw BridgeError.usage("Missing value for \(flag).")
      }
      let value = arguments[index + 1]
      switch flag {
      case "--mode":
        guard let mode = HermesConnectionMode(rawValue: value) else {
          throw BridgeError.usage("Unknown Hermes connection mode: \(value).")
        }
        result.mode = mode
      case "--hermes-path": result.hermesPath = value
      case "--remote-url": result.remoteURL = value
      case "--working-directory": result.workingDirectory = value
      case "--local-working-directory": result.localWorkingDirectory = value
      case "--prompt": result.prompt = value
      case "--resume": result.resumeSessionID = value
      case "--profile": result.profile = value
      case "--model": result.model = value
      case "--effort": result.effort = value
      case "--permission": result.permissionMode = value
      default: throw BridgeError.usage("Unknown option: \(flag).")
      }
      index += 2
    }
    return result
  }
}

private struct HermesOttoToolTunnel {
  private let bridge: MCPBridge
  private let encoder = JSONEncoder()

  init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard let socket = OttoEnvironment.value("CONTROL_SOCKET", in: environment), !socket.isEmpty,
      let token = OttoEnvironment.value("CONTROL_TOKEN", in: environment), !token.isEmpty
    else { return nil }
    bridge = MCPBridge(
      client: ControlClient(
        socketPath: socket,
        token: token,
        sourceNodeID: OttoEnvironment.value("NODE_ID", in: environment).flatMap(
          UUID.init(uuidString:)),
        sourceCanvasID: OttoEnvironment.value("CANVAS_ID", in: environment).flatMap(
          UUID.init(uuidString:))
      ))
  }

  /// Returns nil for an ordinary human-facing clarify request. Marker-bearing requests are always
  /// consumed, including malformed or disallowed ones, so a forged tunnel request is never shown
  /// to the user as a confusing question.
  func response(to question: String) -> String? {
    do {
      let request: HermesOttoToolTunnelProtocol.Request
      switch HermesOttoToolTunnelProtocol.parse(question: question) {
      case .ordinaryClarification:
        return nil
      case .rejected(let message):
        return Self.error(message)
      case .request(let parsed):
        request = parsed
      }
      let arguments = try JSONDecoder().decode(JSONValue.self, from: request.argumentsJSON)
      let response = try bridge.handle(
        MCPRequest(
          id: .string(UUID().uuidString),
          method: "tools/call",
          params: .object([
            "name": .string(request.name),
            "arguments": arguments,
          ])
        ))
      if let error = response.error {
        return Self.error(error.message)
      }
      guard let result = response.result else {
        return Self.error("Otto returned no tool result.")
      }
      return String(decoding: try encoder.encode(result), as: UTF8.self)
    } catch {
      return Self.error(error.localizedDescription)
    }
  }

  private static func error(_ message: String) -> String {
    let object: [String: Any] = ["isError": true, "message": message]
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
      return #"{"isError":true,"message":"Otto tool call failed."}"#
    }
    return String(decoding: data, as: UTF8.self)
  }
}

private actor HermesInputState {
  private var approvalPending = false
  private var runtimeSessionID: String
  /// FIFO of unanswered clarify request_ids seen in the event stream. A stdin line answers the
  /// oldest one via `clarify.respond`; the gateway resolves expired entries gracefully.
  private var clarifyQueue: [String] = []

  init(runtimeSessionID: String) {
    self.runtimeSessionID = runtimeSessionID
  }

  func currentRuntimeSessionID() -> String { runtimeSessionID }

  func updateRuntimeSessionID(_ value: String) { runtimeSessionID = value }

  func markApprovalPending() { approvalPending = true }

  func markClarifyPending(requestID: String) {
    guard !requestID.isEmpty else { return }
    clarifyQueue.append(requestID)
  }

  func takeClarifyID() -> String? {
    guard !clarifyQueue.isEmpty else { return nil }
    return clarifyQueue.removeFirst()
  }

  func approvalChoice(for text: String) -> String? {
    guard approvalPending else { return nil }
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if ["yes", "y", "approve", "ok", "go"].contains(normalized) {
      approvalPending = false
      return "once"
    }
    if ["no", "n", "deny", "cancel"].contains(normalized) {
      approvalPending = false
      return "deny"
    }
    return nil
  }
}

@main
private struct OttoHermesBridge {
  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["--version"] {
        print("otto-hermes-bridge 1")
        return
      }
      let options = try Options.parse(arguments)
      switch options.mode {
      case .local: try await runLocal(options)
      case .remote: try await runRemote(options)
      }
    } catch {
      emit([
        "type": "error",
        "message": error.localizedDescription,
      ])
      Foundation.exit(1)
    }
  }

  private static func runLocal(_ options: Options) async throws {
    guard !options.probe else {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: options.hermesPath)
      process.arguments = ["--version"]
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw BridgeError.gateway("Hermes CLI probe failed.")
      }
      return
    }
    guard let prompt = options.prompt else {
      throw BridgeError.usage("Local bridge mode requires --prompt.")
    }

    let usageURL = FileManager.default.temporaryDirectory
      .appending(path: "otto-hermes-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: usageURL) }
    var arguments: [String] = []
    if let resume = options.resumeSessionID { arguments += ["--resume", resume] }
    arguments += ["-z", prompt, "--usage-file", usageURL.path]
    if let model = options.model { arguments += ["--model", model] }
    if options.permissionMode == "unrestricted" { arguments.append("--yolo") }

    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: options.hermesPath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: options.workingDirectory, isDirectory: true)
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let response = String(
      decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let diagnostic = String(
      decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let usage: [String: Any]? =
      if let usageData = try? Data(contentsOf: usageURL) {
        try? JSONSerialization.jsonObject(with: usageData) as? [String: Any]
      } else {
        nil
      }
    if let sessionID = usage?["session_id"] as? String, !sessionID.isEmpty {
      emit(["type": "session.started", "session_id": sessionID])
    }
    let usageFailed = usage?["failed"] as? Bool == true
    if process.terminationStatus == 0, !usageFailed {
      emit(["type": "message.complete", "payload": ["text": response]])
    } else {
      let usageFailure = usage?["failure"] as? String ?? ""
      let message =
        [response, diagnostic, usageFailure]
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ?? "Hermes run failed."
      emit([
        "type": "error",
        "message": message,
      ])
      Foundation.exit(process.terminationStatus == 0 ? 1 : process.terminationStatus)
    }
  }

  private static func runRemote(_ options: Options) async throws {
    guard let baseURL = normalizedRemoteURL(options.remoteURL) else {
      throw BridgeError.invalidRemoteURL
    }
    let token = try await makeDefaultSecretStore().value(
      for: OttoPreferenceKey.hermesSessionTokenSecret)
    guard let token, !token.isEmpty else { throw BridgeError.missingSessionToken }

    if options.probe {
      let socket = URLSession.shared.webSocketTask(
        with: websocketURL(from: baseURL, token: token))
      socket.resume()
      _ = try await request(
        socket: socket,
        id: "probe",
        method: "session.list",
        params: [:],
        forwardEvents: false
      )
      let defaultSelection = try? await reportedRemoteDefault(socket: socket)
      socket.cancel(with: .normalClosure, reason: nil)
      if let defaultSelection {
        print(
          "Hermes remote backend (\(defaultSelection.provider) · \(defaultSelection.model))")
      } else {
        print("Hermes remote backend")
      }
      return
    }

    let socket = URLSession.shared.webSocketTask(with: websocketURL(from: baseURL, token: token))
    socket.resume()
    var sessionResult: [String: Any]
    if let resume = options.resumeSessionID {
      sessionResult = try await request(
        socket: socket,
        id: "resume",
        method: "session.resume",
        params: ["session_id": resume]
      )
    } else {
      var params: [String: Any] = ["source": HermesWire.sessionSource]
      if !options.workingDirectory.isEmpty { params["cwd"] = options.workingDirectory }
      if let profile = options.profile { params["profile"] = profile }
      // Hermes owns the profile's provider/model pairing. Sending a stale Claude model
      // through a Codex/ChatGPT transport is what produces
      // "The 'claude-opus-4-6' model is not supported when using Codex with a ChatGPT account."
      if let model = options.model { params["model"] = model }
      if let effort = options.effort { params["reasoning_effort"] = effort }
      sessionResult = try await request(
        socket: socket,
        id: "create",
        method: "session.create",
        params: params
      )
      // Multiplexed gateways can report their active profile while still resolving an unscoped
      // session from the default profile's config. Bind a replacement session to the gateway's
      // own reported profile name so Hermes, not Otto, supplies that profile's provider/model.
      if options.profile == nil,
        let info = sessionResult["info"] as? [String: Any],
        let profile = (info["profile_name"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !profile.isEmpty,
        profile != "default",
        let unscopedRuntimeID = sessionResult["session_id"] as? String
      {
        var scopedParams = params
        scopedParams["profile"] = profile
        let scopedSession = try await request(
          socket: socket,
          id: "create-profile-\(UUID().uuidString)",
          method: "session.create",
          params: scopedParams
        )
        _ = try? await request(
          socket: socket,
          id: "close-unscoped-\(UUID().uuidString)",
          method: "session.close",
          params: ["session_id": unscopedRuntimeID],
          forwardEvents: false
        )
        sessionResult = scopedSession
      }
    }
    guard var runtimeSessionID = sessionResult["session_id"] as? String else {
      throw BridgeError.gateway("Hermes did not return a session ID.")
    }
    var storedSessionID =
      sessionResult["stored_session_id"] as? String
      ?? options.resumeSessionID ?? runtimeSessionID
    emit(["type": "session.started", "session_id": storedSessionID])
    let inputState = HermesInputState(runtimeSessionID: runtimeSessionID)
    let ottoToolTunnel = options.ottoToolTunnel ? HermesOttoToolTunnel() : nil
    if options.ottoToolTunnel, ottoToolTunnel == nil {
      throw BridgeError.gateway("Otto's scoped control environment is unavailable.")
    }

    let preparedPrompt: String?
    if let prompt = options.prompt {
      let uploadedPrompt = try await prepareRemoteAttachments(
        in: prompt,
        localWorkingDirectory: options.localWorkingDirectory,
        socket: socket,
        runtimeSessionID: runtimeSessionID
      )
      preparedPrompt = uploadedPrompt
      try await send(
        socket: socket,
        id: "prompt",
        method: "prompt.submit",
        params: ["session_id": runtimeSessionID, "text": uploadedPrompt]
      )
    } else {
      preparedPrompt = nil
    }

    // A clarify or approval can park the run on a human for minutes; idle websockets die under
    // proxies and NAT well before that, killing the run with "Socket is not connected". Pings
    // keep the connection alive for as long as the user needs to think.
    let keepalive = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(25))
        socket.sendPing { _ in }
      }
    }
    defer { keepalive.cancel() }

    // The stdin reader runs in one-shot mode too: mid-run, Hermes can block on a clarify
    // question or an approval, and Otto's chat surface answers it by writing a line here. In
    // one-shot mode stray text with nothing pending is dropped — the run contract is a single
    // turn, and a lost line beats a surprise second turn.
    let oneShot = options.prompt != nil
    Task {
      while let line = readLine() {
        let text = line.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { continue }
        let currentSessionID = await inputState.currentRuntimeSessionID()
        if let requestID = await inputState.takeClarifyID() {
          try? await send(
            socket: socket,
            id: UUID().uuidString,
            method: "clarify.respond",
            params: ["session_id": currentSessionID, "request_id": requestID, "answer": text]
          )
        } else if let choice = await inputState.approvalChoice(for: text) {
          try? await send(
            socket: socket,
            id: UUID().uuidString,
            method: "approval.respond",
            params: ["session_id": currentSessionID, "choice": choice]
          )
        } else if !oneShot {
          try? await send(
            socket: socket,
            id: UUID().uuidString,
            method: "prompt.submit",
            params: ["session_id": currentSessionID, "text": text]
          )
        }
      }
    }

    var retriedCodexModelMismatch = false
    while true {
      let frame = try await receiveObject(socket)
      guard frame["method"] as? String == "event",
        let event = frame["params"] as? [String: Any]
      else { continue }
      let eventType = event["type"] as? String
      if !retriedCodexModelMismatch,
        eventType == "status.update",
        let payload = event["payload"] as? [String: Any],
        let message = payload["text"] as? String ?? payload["message"] as? String,
        isCodexAccountModelMismatch(message)
      {
        // The gateway publishes this terminal-looking status immediately before its
        // message.complete error. Otto would otherwise stop the bridge before the one-time
        // compatibility retry below can create a usable Codex session.
        continue
      }
      if eventType == "approval.request" {
        await inputState.markApprovalPending()
      }
      if eventType == "clarify.request" {
        let payload = event["payload"] as? [String: Any] ?? [:]
        let requestID = payload["request_id"] as? String ?? ""
        let question = payload["question"] as? String ?? ""
        if let response = ottoToolTunnel?.response(to: question), !requestID.isEmpty {
          try await send(
            socket: socket,
            id: "otto-tool-\(UUID().uuidString)",
            method: "clarify.respond",
            params: [
              "session_id": runtimeSessionID,
              "request_id": requestID,
              "answer": response,
            ]
          )
          continue
        }
        await inputState.markClarifyPending(requestID: requestID)
      }
      let failureMessage: String? =
        if eventType == "error" {
          event["message"] as? String ?? "Hermes remote run failed."
        } else if eventType == "message.complete",
          let payload = event["payload"] as? [String: Any],
          payload["status"] as? String == "error"
        {
          payload["error"] as? String ?? payload["text"] as? String
        } else {
          nil
        }
      if options.prompt != nil, let message = failureMessage {
        if !retriedCodexModelMismatch,
          isCodexAccountModelMismatch(message),
          let preparedPrompt
        {
          // Some older gateways cannot enumerate model.options, so a stale Claude model saved on
          // a ChatGPT/Codex profile is only discoverable after the first submission. Retry once
          // with Hermes' own compatibility model instead of making the user repair the remote
          // profile before Otto can start a session.
          var retryParams: [String: Any] = [
            "source": HermesWire.sessionSource,
            "provider": "openai-codex",
            "model": "gpt-5.4",
          ]
          if !options.workingDirectory.isEmpty {
            retryParams["cwd"] = options.workingDirectory
          }
          let retrySession = try await request(
            socket: socket,
            id: "codex-model-retry-\(UUID().uuidString)",
            method: "session.create",
            params: retryParams,
            forwardEvents: false
          )
          guard let retryRuntimeID = retrySession["session_id"] as? String else {
            throw BridgeError.gateway("Hermes did not return a retry session ID.")
          }
          runtimeSessionID = retryRuntimeID
          await inputState.updateRuntimeSessionID(retryRuntimeID)
          storedSessionID =
            retrySession["stored_session_id"] as? String ?? retryRuntimeID
          emit(["type": "session.started", "session_id": storedSessionID])
          retriedCodexModelMismatch = true
          try await send(
            socket: socket,
            id: "codex-model-retry-prompt-\(UUID().uuidString)",
            method: "prompt.submit",
            params: ["session_id": runtimeSessionID, "text": preparedPrompt]
          )
          continue
        }
        throw BridgeError.gateway(message)
      }
      let forwardedEvent =
        if eventType == "message.complete" {
          await localizeRemoteArtifacts(
            in: event,
            baseURL: baseURL,
            token: token,
            localWorkingDirectory: options.localWorkingDirectory,
            sessionID: storedSessionID
          )
        } else {
          event
        }
      emit(forwardedEvent)
      if options.prompt != nil, eventType == "message.complete" { return }
    }
  }

  /// Otto's composer records local image paths in a provider-only trailer. A remote Hermes
  /// gateway cannot read those paths, so upload the bytes through the same `image.attach_bytes`
  /// RPC used by Hermes Desktop and replace the trailer with gateway-local paths.
  ///
  /// Only Otto-owned `.otto/chat-attachments` files are eligible. This prevents text that merely
  /// resembles the trailer from becoming an arbitrary local-file read primitive.
  private static func prepareRemoteAttachments(
    in prompt: String,
    localWorkingDirectory: String,
    socket: URLSessionWebSocketTask,
    runtimeSessionID: String
  ) async throws -> String {
    guard !localWorkingDirectory.isEmpty,
      let trailer = attachmentTrailer(in: prompt),
      !trailer.paths.isEmpty
    else { return prompt }

    let allowedRoot = URL(fileURLWithPath: localWorkingDirectory, isDirectory: true)
      .appending(path: ".otto/chat-attachments", directoryHint: .isDirectory)
      .resolvingSymlinksInPath().standardizedFileURL
    var remotePaths: [String] = []
    for path in trailer.paths {
      let localURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
      guard isDescendant(localURL, of: allowedRoot) else {
        throw BridgeError.gateway(
          "Refusing to upload an attachment outside Otto's staging directory.")
      }
      let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true else {
        throw BridgeError.gateway(
          "Otto attachment is not a regular file: \(localURL.lastPathComponent)")
      }
      let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
      guard data.count <= 50 * 1_048_576 else {
        throw BridgeError.gateway("Otto attachment exceeds Hermes' 50 MB upload limit.")
      }
      let result = try await request(
        socket: socket,
        id: "attach-\(UUID().uuidString)",
        method: "image.attach_bytes",
        params: [
          "session_id": runtimeSessionID,
          "content_base64": data.base64EncodedString(),
          "filename": localURL.lastPathComponent,
        ],
        forwardEvents: false
      )
      guard let remotePath = result["path"] as? String, !remotePath.isEmpty else {
        throw BridgeError.gateway("Hermes uploaded an attachment without returning its path.")
      }
      remotePaths.append(remotePath)
    }

    let listing = remotePaths.map { "- \($0)" }.joined(separator: "\n")
    let rewrittenTrailer =
      "[The user attached \(remotePaths.count) image\(remotePaths.count == 1 ? "" : "s"). "
      + "View each one with your image or file reading tool before answering:\n"
      + listing + "]"
    return String(prompt[..<trailer.range.lowerBound]) + rewrittenTrailer
  }

  private static func attachmentTrailer(in prompt: String) -> (
    range: Range<String.Index>, paths: [String]
  )? {
    let marker = "[The user attached "
    guard let start = prompt.range(of: marker, options: .backwards)?.lowerBound else { return nil }
    let metadata = prompt[start...]
    guard metadata.hasSuffix("]"),
      metadata.contains("View each one with your image or file reading tool before answering:"),
      let firstLineEnd = metadata.firstIndex(of: "\n")
    else { return nil }
    let listingStart = metadata.index(after: firstLineEnd)
    let listingEnd = metadata.index(before: metadata.endIndex)
    let paths = metadata[listingStart..<listingEnd]
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        guard line.hasPrefix("- ") else { return nil }
        return String(line.dropFirst(2))
      }
    return (start..<prompt.endIndex, paths)
  }

  private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path.hasPrefix(rootPath)
  }

  /// Remote `file://` links point at the gateway's disk. Fetch each authenticated artifact into
  /// the local Otto workspace and rewrite the final response before the conversation renders it.
  private static func localizeRemoteArtifacts(
    in event: [String: Any],
    baseURL: URL,
    token: String,
    localWorkingDirectory: String,
    sessionID: String
  ) async -> [String: Any] {
    guard !localWorkingDirectory.isEmpty,
      var payload = event["payload"] as? [String: Any],
      let text = payload["text"] as? String,
      !text.isEmpty
    else { return event }

    let pattern = #"file://[^\s\)\]>]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return event }
    let sourceRange = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = regex.matches(in: text, range: sourceRange)
    guard !matches.isEmpty else { return event }

    let safeSession = sanitizedPathComponent(sessionID)
    let destinationDirectory = URL(fileURLWithPath: localWorkingDirectory, isDirectory: true)
      .appending(path: ".otto/hermes-downloads/\(safeSession)", directoryHint: .isDirectory)
    var rewritten = text
    for match in matches.reversed() {
      guard let range = Range(match.range, in: rewritten) else { continue }
      let source = String(rewritten[range])
      guard let remoteURL = URL(string: source), remoteURL.isFileURL else { continue }
      do {
        let localized = try await downloadRemoteArtifact(
          remotePath: remoteURL.path,
          baseURL: baseURL,
          token: token,
          destinationDirectory: destinationDirectory
        )
        rewritten.replaceSubrange(range, with: localized.absoluteString)
      } catch {
        // Preserve the original link and append no noisy diagnostics. The user still sees the
        // provider's artifact path, while successful siblings remain usable.
        continue
      }
    }
    payload["text"] = rewritten
    var forwarded = event
    forwarded["payload"] = payload
    return forwarded
  }

  private static func downloadRemoteArtifact(
    remotePath: String,
    baseURL: URL,
    token: String,
    destinationDirectory: URL
  ) async throws -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw BridgeError.invalidRemoteURL
    }
    components.scheme =
      ["https", "wss"].contains(components.scheme?.lowercased() ?? "")
      ? "https" : "http"
    let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = prefix.isEmpty ? "/api/files/download" : "/\(prefix)/api/files/download"
    components.queryItems = [
      URLQueryItem(name: "path", value: remotePath),
      URLQueryItem(name: "token", value: token),
    ]
    guard let downloadURL = components.url else { throw BridgeError.invalidRemoteURL }
    let (data, response) = try await URLSession.shared.data(from: downloadURL)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw BridgeError.gateway("Hermes could not download the generated artifact.")
    }
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let suggestedName =
      response.suggestedFilename ?? URL(fileURLWithPath: remotePath).lastPathComponent
    let destination = uniqueDestination(
      in: destinationDirectory,
      preferredName: suggestedName.isEmpty ? "hermes-artifact" : suggestedName
    )
    try data.write(to: destination, options: [.atomic])
    return destination
  }

  private static func uniqueDestination(in directory: URL, preferredName: String) -> URL {
    let safeName = sanitizedPathComponent(preferredName)
    let initial = directory.appending(path: safeName)
    guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
    let source = URL(fileURLWithPath: safeName)
    let stem = source.deletingPathExtension().lastPathComponent
    let suffix = source.pathExtension
    for counter in 2...10_000 {
      let name = suffix.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(suffix)"
      let candidate = directory.appending(path: name)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return directory.appending(path: "\(UUID().uuidString)-\(safeName)")
  }

  private static func sanitizedPathComponent(_ value: String) -> String {
    let disallowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).inverted
    let sanitized = value.components(separatedBy: disallowed).filter { !$0.isEmpty }.joined(
      separator: "-")
    return sanitized.isEmpty ? "artifact" : String(sanitized.prefix(180))
  }

  /// Reads Hermes' configured default for probe output only. Session creation omits model and
  /// provider unless Otto was given an explicit model, leaving selection to the Hermes profile.
  private static func reportedRemoteDefault(
    socket: URLSessionWebSocketTask
  ) async throws -> (provider: String, model: String)? {
    let result = try await request(
      socket: socket,
      id: "model-default",
      method: "model.options",
      params: [:],
      forwardEvents: false
    )
    let provider = (result["provider"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let model = (result["model"] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !provider.isEmpty, !model.isEmpty else { return nil }
    return (provider, model)
  }

  private static func isCodexProvider(_ provider: String) -> Bool {
    let normalized = provider.lowercased().replacingOccurrences(of: "_", with: "-")
    return normalized == "codex" || normalized == "openai-codex"
  }

  private static func isCodexAccountModelMismatch(_ message: String) -> Bool {
    let normalized = message.lowercased()
    return normalized.contains("model is not supported")
      && normalized.contains("codex")
      && normalized.contains("chatgpt")
  }

  private static func request(
    socket: URLSessionWebSocketTask,
    id: String,
    method: String,
    params: [String: Any],
    forwardEvents: Bool = true
  ) async throws -> [String: Any] {
    try await send(socket: socket, id: id, method: method, params: params)
    while true {
      let frame = try await receiveObject(socket)
      if frame["method"] as? String == "event", let event = frame["params"] as? [String: Any] {
        if forwardEvents { emit(event) }
        continue
      }
      guard frame["id"] as? String == id else { continue }
      if let error = frame["error"] as? [String: Any] {
        throw BridgeError.gateway(error["message"] as? String ?? "Hermes RPC failed.")
      }
      return frame["result"] as? [String: Any] ?? [:]
    }
  }

  private static func send(
    socket: URLSessionWebSocketTask,
    id: String,
    method: String,
    params: [String: Any]
  ) async throws {
    let frame: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params,
    ]
    let data = try JSONSerialization.data(withJSONObject: frame)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  private static func receiveObject(_ socket: URLSessionWebSocketTask) async throws
    -> [String: Any]
  {
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let value): data = value
    @unknown default: throw BridgeError.gateway("Hermes sent an unsupported WebSocket frame.")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BridgeError.gateway("Hermes sent an invalid JSON frame.")
    }
    return object
  }

  private static func normalizedRemoteURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
      url.host != nil, url.user == nil, url.password == nil, url.fragment == nil
    else { return nil }
    return url
  }

  private static func websocketURL(from base: URL, token: String) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.scheme =
      ["https", "wss"].contains(components.scheme?.lowercased() ?? "")
      ? "wss" : "ws"
    let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.path = prefix.isEmpty ? "/api/ws" : "/\(prefix)/api/ws"
    components.queryItems = [URLQueryItem(name: "token", value: token)]
    return components.url!
  }

  private static func emit(_ object: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }
}

/// Session source label sent to the Hermes gateway. Legacy wire name, do not change without a
/// protocol version bump: gateways and their session lists already key Otto sessions by it.
private enum HermesWire {
  static let sessionSource = "muse"
}

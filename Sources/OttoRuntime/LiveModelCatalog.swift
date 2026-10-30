import Foundation
import OttoModels

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Catalog-only handshakes: no user prompt, inference, session resume or tool execution.
/// Each probe owns and reaps its process; its account environment is never logged.
enum LiveModelCatalog {
  static func discover(
    provider: AgentProvider, executable: String, environment: [String: String],
    timeout: TimeInterval = 20
  ) async -> [AgentModel]? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          returning: probe(
            provider: provider, executable: executable, environment: environment, timeout: timeout)?
            .models)
      }
    }
  }

  static func discoverApps(
    executable: String, environment: [String: String], timeout: TimeInterval = 60
  ) async -> [ProviderMarketplaceApp]? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          returning: probe(
            provider: .codex, executable: executable,
            environment: environment, timeout: timeout, apps: true)?.apps)
      }
    }
  }

  private struct Result {
    var models: [AgentModel]? = nil
    var apps: [ProviderMarketplaceApp]? = nil
  }

  static func inheritedPrefixes(
    for provider: AgentProvider, environment: [String: String]
  ) -> [String] {
    // Leave the default Claude config directory implicit: explicitly setting even ~/.claude
    // changes Claude's keychain namespace. Named profiles restore their supplied directory.
    var prefixes = [
      "OTTO_", "MUSE_", "CODEX_", "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
    ]
    if !environment.isEmpty {
      prefixes += ProviderAccountIsolation.descriptor(for: provider).credentialEnvironmentVariables
    }
    return prefixes
  }

  private static func probe(
    provider: AgentProvider, executable: String, environment: [String: String],
    timeout: TimeInterval, apps: Bool = false
  ) -> Result? {
    #if os(Windows)
      // The probe multiplexes the CLI's pipe with poll(2); Windows uses the static catalog.
      return nil
    #else
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments =
      provider == .codex
      ? ["app-server"]
      : [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence",
        "--settings", "{\"disableAllHooks\":true}", "--tools", "",
      ]
    process.environment = ProcessLaunchSpec(
      executable: executable, environment: environment,
      inheritedEnvironmentPrefixesToRemove: inheritedPrefixes(
        for: provider, environment: environment), workingDirectory: "/"
    ).resolvedEnvironment(inheriting: ProcessInfo.processInfo.environment)
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    let input = Pipe()
    let output = Pipe()
    #if canImport(Darwin)
      // A CLI can exit between responses. Treat a broken input pipe as a failed probe.
      _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    #endif
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Parent must not hold the child's write end: otherwise EOF cannot be detected.
    try? output.fileHandleForWriting.close()
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      let grace = ProcessInfo.processInfo.systemUptime + 0.25
      while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var pending = Data()
    var bytesRead = 0
    func send(_ message: [String: Any]) throws {
      var data = try JSONSerialization.data(withJSONObject: message)
      data.append(10)
      try input.fileHandleForWriting.write(contentsOf: data)
    }
    func receive() -> [String: Any]? {
      while ProcessInfo.processInfo.systemUptime < deadline {
        if let newline = pending.firstIndex(of: 10) {
          let line = pending.prefix(upTo: newline)
          let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
          pending.removeSubrange(...newline)
          if let object { return object }
          continue
        }
        var descriptor = pollfd(
          fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0 {
          if errno == EINTR { continue }
          return nil
        }
        if ready == 0 { continue }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(descriptor.fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        bytesRead += count
        // App-server also emits full-directory notifications alongside paginated responses.
        // Keep a bounded larger budget for app metadata; model probes retain their small limit.
        guard bytesRead <= (apps ? 32 : 4) * 1024 * 1024 else { return nil }
        pending.append(contentsOf: buffer.prefix(count))
      }
      return nil
    }
    do {
      if provider == .claudeCode {
        try send([
          "type": "control_request", "request_id": "otto-models",
          "request": ["subtype": "initialize"],
        ])
        while let message = receive() {
          guard message["type"] as? String == "control_response",
            let response = message["response"] as? [String: Any],
            response["request_id"] as? String == "otto-models"
          else { continue }
          guard response["subtype"] as? String == "success",
            let result = response["response"] as? [String: Any],
            let rows = result["models"] as? [[String: Any]]
          else { return nil }
          return Result(models: models(rows, idKey: "value"))
        }
      } else {
        var initializeParams: [String: Any] = [
          "clientInfo": ["name": apps ? "otto_app_catalog" : "otto_model_catalog", "version": "1"]
        ]
        if apps { initializeParams["capabilities"] = ["experimentalApi": true] }
        try send(["id": 1, "method": "initialize", "params": initializeParams])
        while let message = receive() {
          guard message["id"] as? Int == 1 else { continue }
          guard message["error"] == nil, message["result"] != nil else { return nil }
          try send(["method": "initialized"])
          // Codex can return a built-in catalog even when this profile has no login.
          // Do not present that fallback as the selected account's available models.
          try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
          var accountResponse: [String: Any]?
          while let response = receive() {
            if response["id"] as? Int == 2 {
              accountResponse = response
              break
            }
          }
          guard let accountResponse, accountResponse["error"] == nil,
            let accountResult = accountResponse["result"] as? [String: Any],
            accountResult["account"] is [String: Any]
          else { return nil }
          if apps, (accountResult["account"] as? [String: Any])?["type"] as? String != "chatgpt" {
            return nil
          }
          var cursor: String?
          var cursors = Set<String>()
          var rows: [[String: Any]] = []
          var requestID = 3
          repeat {
            var params: [String: Any] = ["limit": apps ? 500 : 100]
            if apps { params["forceRefetch"] = cursor == nil }
            if let cursor { params["cursor"] = cursor }
            try send([
              "id": requestID, "method": apps ? "app/list" : "model/list", "params": params,
            ])
            var page: [String: Any]?
            while let response = receive() {
              if response["id"] as? Int == requestID {
                page = response
                break
              }
            }
            guard let page, page["error"] == nil,
              let result = page["result"] as? [String: Any],
              let batch = result["data"] as? [[String: Any]]
            else { return nil }
            rows += batch
            guard rows.count <= (apps ? 10000 : 3000), requestID < (apps ? 103 : 63) else {
              return nil
            }
            cursor = result["nextCursor"] as? String
            if let next = cursor, !cursors.insert(next).inserted { return nil }
            requestID += 1
          } while cursor != nil && ProcessInfo.processInfo.systemUptime < deadline
          guard cursor == nil else { return nil }
          if apps {
            // This optional endpoint is absent in older CLI versions. A catalogue is still usable;
            // its entries simply cannot claim an installed/callable state.
            try send(["id": requestID, "method": "app/installed", "params": ["forceRefresh": true]])
            var installed: [[String: Any]] = []
            while let response = receive() {
              guard response["id"] as? Int == requestID else { continue }
              if let result = response["result"] as? [String: Any],
                let values = result["apps"] as? [[String: Any]]
              {
                installed = values
              }
              break
            }
            return Result(apps: ProviderMarketplaceApp.parse(rows, installed: installed))
          }
          return Result(models: models(rows, idKey: "model"))
        }
      }
    } catch { return nil }
    return nil
    #endif
  }

  private static func models(_ rows: [[String: Any]], idKey: String) -> [AgentModel] {
    var seen = Set<String>()
    return rows.compactMap { row in
      guard let id = row[idKey] as? String, !id.isEmpty,
        row["hidden"] as? Bool != true, seen.insert(id).inserted
      else { return nil }
      let name = (row["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return AgentModel(id: id, displayName: name?.isEmpty == false ? name! : id)
    }
  }
}

import CryptoKit
import Darwin
import Foundation
import OttoModels

/// Explicit user-triggered package installation. No prompt/inference, shell, trust bypass,
/// credential export or captured CLI output. Owns a process group, including git children.
public enum MarketplaceInstaller {
  public enum Outcome: Equatable, Sendable {
    case installed, unavailable, needsProviderSetup, timedOut
  }

  public static func connectRemote(_ plugin: PublicMarketplacePlugin) async -> Outcome {
    guard plugin.provider == .openCode, let url = plugin.remoteURL else { return .unavailable }
    let home = NSHomeDirectory()
    guard
      let executable = ExecutableLocator.find(
        "opencode", preferredPaths: ["\(home)/.opencode/bin/opencode"])
    else { return .unavailable }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let server = try registerOpenCodeRemote(
            url: url, identity: plugin.id,
            directory: URL(fileURLWithPath: home).appending(path: ".config/opencode"))
          continuation.resume(
            returning: run(executable, arguments: ["mcp", "auth", server], timeout: 180))
        } catch {
          continuation.resume(returning: .needsProviderSetup)
        }
      }
    }
  }

  /// Preserve every existing setting. Refuse JSONC, collisions and simultaneous edits instead
  /// of rewriting a user's configuration under a different interpretation.
  static func registerOpenCodeRemote(url: URL, identity: String, directory: URL) throws -> String {
    guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else { throw SetupError.invalid }
    let manager = FileManager.default
    guard !manager.fileExists(atPath: directory.appending(path: "opencode.jsonc").path)
    else { throw SetupError.conflictingConfiguration }
    let file = directory.appending(path: "opencode.json")
    if let attributes = try? manager.attributesOfItem(atPath: file.path),
      attributes[.type] as? FileAttributeType == .typeSymbolicLink
    {
      throw SetupError.conflictingConfiguration
    }
    let original = try? Data(contentsOf: file)
    if manager.fileExists(atPath: file.path), original == nil {
      throw SetupError.conflictingConfiguration
    }
    if let original, original.count > 1_048_576 { throw SetupError.conflictingConfiguration }
    var root: [String: Any]
    if let original {
      guard let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
      else { throw SetupError.conflictingConfiguration }
      root = object
    } else {
      root = [:]
    }
    if root["mcp"] != nil && !(root["mcp"] is [String: Any]) {
      throw SetupError.conflictingConfiguration
    }
    var servers = root["mcp"] as? [String: Any] ?? [:]
    let digest = SHA256.hash(data: Data(identity.utf8)).prefix(10).map {
      String(format: "%02x", $0)
    }.joined()
    // Entries added before the rename are named `muse-marketplace-…`; reuse one if present.
    let legacyName = "muse-marketplace-" + digest
    let name = servers[legacyName] != nil ? legacyName : "otto-marketplace-" + digest
    if let existing = servers[name] {
      guard let config = existing as? [String: Any], config["url"] as? String == url.absoluteString,
        config["type"] as? String == "remote", config["oauth"] as? Bool != false
      else { throw SetupError.conflictingConfiguration }
      return name
    }
    servers[name] = ["type": "remote", "url": url.absoluteString]
    root["mcp"] = servers
    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    guard (try? Data(contentsOf: file)) == original else {
      throw SetupError.conflictingConfiguration
    }
    try data.write(to: file, options: .atomic)
    return name
  }
  enum SetupError: Error { case invalid, conflictingConfiguration }

  public static func authenticate(provider: AgentProvider, server: String, workspace: String) async
    -> Outcome
  {
    guard provider == .cursor || provider == .openCode, !server.isEmpty,
      !server.hasPrefix("-"), server.count <= 200, !server.contains(where: { $0.isNewline })
    else { return .unavailable }
    let home = NSHomeDirectory()
    let executable = ExecutableLocator.find(
      provider == .cursor ? "cursor-agent" : "opencode",
      preferredPaths: provider == .openCode ? ["\(home)/.opencode/bin/opencode"] : [])
    guard let executable else { return .unavailable }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          returning: run(
            executable,
            arguments: ["mcp", provider == .cursor ? "login" : "auth", server],
            timeout: 180, workspace: workspace))
      }
    }
  }

  public static func arguments(for plugin: PublicMarketplacePlugin) -> [String]? {
    guard plugin.nativeInstall, let source = plugin.installSource,
      source.count < 1_000, !source.contains(where: { $0.isWhitespace || $0.isNewline })
    else { return nil }
    switch plugin.provider {
    case .claudeCode:
      guard source == "\(plugin.id)@claude-plugins-official",
        !plugin.id.hasPrefix("-"), !plugin.id.isEmpty,
        plugin.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
      else { return nil }
      return ["plugin", "install", source, "--scope", "user"]
    case .grok:
      guard source.hasPrefix("https://github.com/"), !source.contains("?"),
        source.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ":/.-_@#".contains($0)) })
      else { return nil }
      return ["plugin", "install", source]
    default: return nil
    }
  }

  public static func install(_ plugin: PublicMarketplacePlugin) async -> Outcome {
    guard let args = arguments(for: plugin) else { return .unavailable }
    let home = NSHomeDirectory()
    let executable = ExecutableLocator.find(
      plugin.provider == .claudeCode ? "claude" : "grok",
      preferredPaths: plugin.provider == .grok ? ["\(home)/.grok/bin/grok"] : [])
    guard let executable else { return .unavailable }
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        // Registration is a native CLI operation, not execution of catalogue-provided scripts.
        if plugin.provider == .claudeCode {
          let registered = run(
            executable,
            arguments: [
              "plugin", "marketplace", "add",
              "anthropics/claude-plugins-official",
            ], timeout: 60)
          guard registered == .installed else {
            continuation.resume(returning: registered)
            return
          }
        }
        continuation.resume(returning: run(executable, arguments: args, timeout: 90))
      }
    }
  }

  static func run(
    _ executable: String, arguments: [String], timeout: TimeInterval, workspace: String = "/"
  ) -> Outcome {
    let environment = ProcessLaunchSpec(
      executable: executable,
      inheritedEnvironmentPrefixesToRemove: [
        "OTTO_", "MUSE_", "CODEX_", "CLAUDE_", "CLAUDECODE",
        "ANTHROPIC_", "OPENAI_", "XAI_", "GROK_HOME", "KIMI_", "CURSOR_", "OPENCODE_", "XDG_",
      ],
      workingDirectory: workspace
    ).resolvedEnvironment(inheriting: ProcessInfo.processInfo.environment)
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    guard posix_spawnattr_init(&attributes) == 0 else { return .unavailable }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawn_file_actions_init(&actions) == 0 else { return .unavailable }
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attributes, 0)
    // Keep native credentials and any output out of Otto transcripts and logs.
    for fd: Int32 in [0, 1, 2] {
      posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0)
    }
    posix_spawn_file_actions_addchdir_np(&actions, workspace)
    var pid: pid_t = 0
    let error = argv.withUnsafeMutableBufferPointer { args in
      envp.withUnsafeMutableBufferPointer { env in
        posix_spawn(&pid, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
      }
    }
    guard error == 0 else { return .unavailable }
    var status: Int32 = 0
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        // Also clean up any subprocess left behind by a failed/interrupted installer.
        kill(-pid, SIGTERM)
        return status == 0 ? .installed : .needsProviderSetup
      }
      if result < 0 && errno != EINTR {
        kill(-pid, SIGKILL)
        return .needsProviderSetup
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    kill(-pid, SIGTERM)
    Thread.sleep(forTimeInterval: 0.25)
    kill(-pid, SIGKILL)
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return .timedOut
  }
}

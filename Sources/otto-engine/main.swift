import Foundation
import OttoCore
import OttoHostRuntime
import OttoModels
import OttoPersistence
import OttoRPCContracts
import OttoSecurity
import OttoServices
import OttoTools

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import ucrt
#endif

/// The full Otto engine without a window: ApplicationServices for one workspace, served over
/// the host RPC (OttoRPCContracts) on standard input/output. Otto Desktop starts one per
/// workspace. Each stdin line is `{"token": "...", "request": OttoRPCRequest}`; each stdout line
/// is an OttoRPCResponse, or `{"error": {...}}` when a line cannot be parsed or authorised.
@MainActor
enum OttoEngine {
  static let usage = """
    Usage:
      otto-engine stdio --token-file <path> --state-dir <path> --workspace <path> [--secrets desktop]

    Runs Otto's engine for one workspace and serves the host RPC over standard input/output.
    """

  /// Exactly one of `request` (shared host RPC) or `desktop` (owner-only DesktopAPI).
  struct Request: Decodable {
    var token: String
    var request: OttoRPCRequest?
    var desktop: DesktopAPI.Call?
    var hostReply: DesktopHost.Reply?
    var hostEvent: DesktopHost.IncomingEvent?
  }

  struct Failure: Encodable {
    struct Detail: Encodable {
      var code: String
      var message: String
    }
    /// The request's ID when it could be read, so the client can fail that call promptly.
    var id: UUID?
    var error: Detail
  }

  static func main() async {
    do {
      let options = try Options(CommandLine.arguments.dropFirst())
      let token = try loadToken(options.tokenFile)
      try FileManager.default.createDirectory(
        at: options.stateDirectory, withIntermediateDirectories: true)

      let database = SQLiteWorkspaceStore(
        path: options.stateDirectory.appending(path: "workspace.sqlite").path)
      let store = CanvasStore(persistence: database)
      let registry = ToolRegistry(auditSink: CompositeToolAuditSink([database]))
      let output = ResponseWriter()
      let desktopHost = DesktopHost(output: output)
      // Read input from the start: the desktop's keychain answers secret lookups while the engine
      // starts. Host replies and events are handled at once; requests wait until it is ready.
      let requests = startReading(token: token, host: desktopHost, output: output)
      let legacySecrets = options.stateDirectory.appending(path: "secrets.json")
      let secrets: any SecretStore
      if options.desktopSecrets {
        let keychain = DesktopSecretStore(host: desktopHost)
        await keychain.adopt(legacyFile: legacySecrets)
        secrets = keychain
        // Every service's own secrets (Gmail, Telegram, website passwords…) use it too.
        PlatformKeyring.install(keychain)
        LoopbackSignIn.install(DesktopLoopbackBroker(host: desktopHost))
      } else {
        secrets = EngineSecretStore(fileURL: legacySecrets)
      }
      let services = ApplicationServices(
        store: store,
        registry: registry,
        secrets: secrets,
        // Agent accounts live with this engine, never in the native Mac app's folder.
        providerAccounts: ProviderAccountStore(
          rootDirectory: options.stateDirectory.appending(
            path: "accounts", directoryHint: .isDirectory),
          secrets: secrets),
        // Gmail's client setup lives with this engine, never beside the Mac app's.
        appConnections: AppConnectionsStore(
          workspacePath: options.workspace.path, configurationDirectory: options.stateDirectory),
        workspacePath: options.workspace.path,
        personalMemoryPath: options.stateDirectory.appending(path: "user-context.md").path
      )
      await store.restore()
      #if os(Windows)
        _ = _putenv_s(OttoEnvironment.key("MOBILE_HOST"), "off")
      #else
        setenv(OttoEnvironment.key("MOBILE_HOST"), "off", 1)
      #endif
      await services.start()
      if let problem = services.errorMessage {
        // Startup carries on with what did load; say what did not.
        FileHandle.standardError.write(Data("otto-engine startup problem: \(problem)\n".utf8))
      }

      let adapter = ApplicationServicesMobileHostAdapter(
        services: services,
        environmentID: try environmentID(in: options.stateDirectory),
        environmentName: ProcessInfo.processInfo.hostName,
        hostVersion: "0.1.0",
        isOwnerClient: true
      )
      let journal = try RunEventJournal(
        directory: options.stateDirectory.appending(path: "events", directoryHint: .isDirectory))
      let host = OttoHostRuntime(dataSource: adapter, journal: journal)
      let bridge = OttoMobileEventBridge(services: services, adapter: adapter, host: host)
      await bridge.start()
      FileHandle.standardError.write(Data("otto-engine ready\n".utf8))

      // The desktop app is the only client and holds every scope.
      let client = OttoHostClientContext(
        deviceID: UUID(uuidString: "00000000-0000-0000-0000-00000000D35C")!,
        scopes: Set(OttoRPCScope.allCases))
      let browsers = DesktopBrowserBridge(
        store: store, runtime: services.browserRuntime, host: desktopHost)
      await browsers.start()
      var desktop = DesktopAPI(services: services, store: store)
      if options.desktopSecrets {
        // Voice needs the desktop's microphone, speakers and keychain.
        let voice = DesktopVoice(
          services: services, store: store, host: desktopHost, secrets: secrets,
          workspacePath: options.workspace.path)
        await voice.start()
        desktop.voice = voice
      }
      let api = desktop
      for await request in requests {
        // Long calls (sending a message, starting a thread) must not hold up event polling.
        if let call = request.desktop {
          Task { await output.writeLine(await api.handle(call)) }
        } else if let rpc = request.request {
          Task {
            let response = await host.handle(rpc, client: client)
            await output.write(response)
          }
        } else {
          await output.write(Failure(error: .init(code: "invalid_request", message: "Invalid request.")))
        }
      }
      // Standard input closed: the desktop app is quitting. Save state before exiting.
      bridge.stop()
      await services.flushPersistence()
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n\(usage)\n".utf8))
      exit(64)
    }
  }

  /// Lines from standard input, read on a background thread so the main actor stays free.
  /// Reads standard input for the engine's whole life. Host replies and host events (the
  /// desktop answering a keychain lookup, microphone audio) are delivered immediately, even
  /// during startup; authorised requests are queued for the main loop once the engine is ready.
  static func startReading(token: String, host: DesktopHost, output: ResponseWriter)
    -> AsyncStream<Request>
  {
    let (requests, continuation) = AsyncStream<Request>.makeStream()
    let expected = Array(token.utf8)
    Task {
      for await line in standardInputLines() {
        let request: Request
        do {
          request = try OttoRPCCodec.decoder.decode(Request.self, from: Data(line.utf8))
        } catch {
          await output.write(
            Failure(error: .init(code: "invalid_request", message: "Invalid request.")))
          continue
        }
        guard constantTimeEqual(Array(request.token.utf8), expected) else {
          if let call = request.desktop {
            await output.write(
              DesktopAPI.Failure(
                id: call.id, error: .init(code: "unauthorized", message: "Unauthorized.")))
          } else {
            await output.write(
              Failure(
                id: request.request?.id,
                error: .init(code: "unauthorized", message: "Unauthorized.")))
          }
          continue
        }
        if let reply = request.hostReply {
          await host.receive(reply)
        } else if let event = request.hostEvent {
          await host.receive(event)
        } else {
          continuation.yield(request)
        }
      }
      continuation.finish()
    }
    return requests
  }

  static func standardInputLines() -> AsyncStream<String> {
    AsyncStream { continuation in
      Thread.detachNewThread {
        while let line = readLine() {
          if !line.isEmpty { continuation.yield(line) }
        }
        continuation.finish()
      }
    }
  }

  static func environmentID(in directory: URL) throws -> UUID {
    let file = directory.appending(path: "environment-id")
    if let text = try? String(contentsOf: file, encoding: .utf8),
      let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return id
    }
    let id = UUID()
    try id.uuidString.write(to: file, atomically: true, encoding: .utf8)
    return id
  }

  static func loadToken(_ url: URL) throws -> String {
    #if !os(Windows)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
      guard permissions & 0o077 == 0 else { throw EngineError.insecureTokenFile }
    #endif
    let token = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count >= 32 else { throw EngineError.invalidToken }
    return token
  }

  static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    var difference = UInt(lhs.count ^ rhs.count)
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      difference |= UInt(left ^ right)
    }
    return difference == 0
  }
}

struct Options {
  var tokenFile: URL
  var stateDirectory: URL
  var workspace: URL
  /// `--secrets desktop`: keep secrets in Otto Desktop's OS keychain instead of a state file.
  var desktopSecrets = false

  init(_ arguments: ArraySlice<String>) throws {
    var values: [String: String] = [:]
    var remaining = Array(arguments)
    guard remaining.first == "stdio" else { throw EngineError.usage }
    remaining.removeFirst()
    while remaining.count >= 2 {
      values[remaining.removeFirst()] = remaining.removeFirst()
    }
    guard remaining.isEmpty, let token = values["--token-file"], let state = values["--state-dir"],
      let workspace = values["--workspace"]
    else { throw EngineError.usage }
    desktopSecrets = values["--secrets"] == "desktop"
    tokenFile = URL(fileURLWithPath: token)
    stateDirectory = URL(fileURLWithPath: state, isDirectory: true)
    self.workspace = URL(fileURLWithPath: workspace, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: self.workspace.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw EngineError.missingWorkspace }
  }
}

enum EngineError: Error, LocalizedError {
  case usage, insecureTokenFile, invalidToken, missingWorkspace

  var errorDescription: String? {
    switch self {
    case .usage: "Invalid otto-engine arguments."
    case .insecureTokenFile: "The token file must not be accessible by group or others."
    case .invalidToken: "The token must contain at least 32 bytes."
    case .missingWorkspace: "The workspace folder does not exist."
    }
  }
}

/// Writes one JSON document per line; serialised so concurrent responses never interleave.
actor ResponseWriter {
  private let encoder = OttoRPCCodec.encoder

  func write<Value: Encodable>(_ value: Value) {
    guard let data = try? encoder.encode(value) else { return }
    writeLine(data)
  }

  func writeLine(_ encoded: Data) {
    var data = encoded
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }
}

/// Secrets for app connections and bots, kept owner-only in the engine's state folder until the
/// platform keyring (Windows Credential Manager, libsecret) is wired up.
actor EngineSecretStore: SecretStore {
  private let fileURL: URL

  init(fileURL: URL) { self.fileURL = fileURL }

  func set(_ value: String, for key: String) async throws {
    var secrets = load()
    secrets[key] = value
    try save(secrets)
  }

  func value(for key: String) async throws -> String? { load()[key] }

  func delete(_ key: String) async throws {
    var secrets = load()
    guard secrets.removeValue(forKey: key) != nil else { return }
    try save(secrets)
  }

  private func load() -> [String: String] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private func save(_ secrets: [String: String]) throws {
    let data = try JSONEncoder().encode(secrets)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      _ = FileManager.default.createFile(
        atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    try data.write(to: fileURL, options: .atomic)
    #if !os(Windows)
      _ = chmod(fileURL.path, 0o600)
    #endif
  }
}

await OttoEngine.main()

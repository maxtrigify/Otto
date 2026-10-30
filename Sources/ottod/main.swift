import Dispatch
import Foundation
import OttoCommercial
import OttoRemote

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#else
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#endif

struct OttodCommand {
  private static let upgradeUsage: String = {
    """
    ottod install-upgrade --manifest <signed.json> --artifact <ottod> --destination <ottod|mused>
      --current-version <version> --current-build <number> --key-id <id> --public-key <base64>
    """
  }()

  private static let usage = """
    Usage:
      ottod serve --token-file <path> --state-dir <path> --workspace <path> [--socket <path>]
      ottod stdio --token-file <path> --state-dir <path> --workspace <path> [--workspace <path> ...]
    \(upgradeUsage)

    Runs the authenticated Otto remote protocol over standard input/output.
    The token file must be owner-only and contain at least 32 bytes. This diagnostic
    transport is intended to run inside an SSH session; persistent socket service is
    configured separately during remote bootstrap.
    """

  static func main() async {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments.first == "install-upgrade" {
        let receipt = try installUpgrade(arguments)
        let data = try JSONEncoder.commercial.encode(receipt)
        print(String(decoding: data, as: UTF8.self))
        return
      }
      let configuration = try parse(arguments)
      let token = try loadToken(configuration.tokenFile)
      let daemon = try RemoteDaemon(
        token: token,
        tokenFile: configuration.tokenFile,
        stateDirectory: configuration.stateDirectory,
        workspaceRoots: configuration.workspaces
      )
      if configuration.mode == .serve {
        #if os(Windows)
          throw OttodError.serveUnsupported
        #else
          let server = try RemoteSocketServer(
            socketPath: configuration.socketPath,
            daemon: daemon
          )
          FileHandle.standardError.write(Data("ottod listening on a private Unix socket.\n".utf8))
          await server.waitUntilStopped()
          return
        #endif
      }
      let decoder = JSONDecoder()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      while let line = readLine() {
        let response: RemoteResponse
        do {
          let request = try decoder.decode(RemoteRequest.self, from: Data(line.utf8))
          response = await daemon.handle(request)
        } catch {
          response = RemoteResponse(
            id: "unknown",
            error: RemoteFailure(code: "invalid_request", message: "Invalid remote request.")
          )
        }
        let data = try encoder.encode(response)
        print(String(decoding: data, as: UTF8.self))
        fflush(nil)
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      FileHandle.standardError.write(Data("\(usage)\n".utf8))
      Foundation.exit(64)
    }
  }

  private static func installUpgrade(_ arguments: [String]) throws -> RemoteUpgradeReceipt {
    var values: [String: String] = [:]
    var index = 1
    while index < arguments.count {
      guard index + 1 < arguments.count, arguments[index].hasPrefix("--") else {
        throw OttodError.usage
      }
      guard values.updateValue(arguments[index + 1], forKey: arguments[index]) == nil else {
        throw OttodError.usage
      }
      index += 2
    }
    guard
      values.count == 7,
      let manifestPath = values["--manifest"],
      let artifactPath = values["--artifact"],
      let destinationPath = values["--destination"],
      let currentVersion = values["--current-version"],
      let buildText = values["--current-build"],
      let currentBuild = Int(buildText),
      currentBuild >= 0,
      let keyID = values["--key-id"],
      !keyID.isEmpty,
      let encodedPublicKey = values["--public-key"],
      let publicKey = Data(base64Encoded: encodedPublicKey)
    else { throw OttodError.usage }

    let document = try JSONDecoder.commercial.decode(
      SignedDocument.self,
      from: Data(contentsOf: URL(fileURLWithPath: manifestPath))
    )
    return try RemoteUpgradeInstaller(publicKeys: [keyID: publicKey]).install(
      document: document,
      artifact: URL(fileURLWithPath: artifactPath),
      destination: URL(fileURLWithPath: destinationPath),
      currentVersion: currentVersion,
      currentBuild: currentBuild
    )
  }

  private static func parse(_ arguments: [String]) throws -> Configuration {
    if arguments == ["--help"] || arguments == ["-h"] {
      print(usage)
      Foundation.exit(0)
    }
    guard let command = arguments.first,
      command == "stdio" || command == "serve"
    else { throw OttodError.usage }
    var tokenFile: URL?
    var stateDirectory: URL?
    var workspaces: [URL] = []
    var socketPath: String?
    var index = 1
    while index < arguments.count {
      guard index + 1 < arguments.count else { throw OttodError.usage }
      let value = URL(fileURLWithPath: arguments[index + 1])
      switch arguments[index] {
      case "--token-file": tokenFile = value
      case "--state-dir": stateDirectory = value
      case "--workspace": workspaces.append(value)
      case "--socket": socketPath = arguments[index + 1]
      default: throw OttodError.usage
      }
      index += 2
    }
    guard let tokenFile, let stateDirectory, !workspaces.isEmpty else {
      throw OttodError.usage
    }
    let mode: Configuration.Mode = command == "serve" ? .serve : .stdio
    let resolvedSocket =
      socketPath
      ?? stateDirectory.appending(path: "ottod.sock").path
    return Configuration(
      mode: mode,
      tokenFile: tokenFile,
      stateDirectory: stateDirectory,
      workspaces: workspaces,
      socketPath: resolvedSocket
    )
  }

  private static func loadToken(_ url: URL) throws -> String {
    #if !os(Windows)
      // Windows has no POSIX mode bits; the token lives in the user's profile, guarded by its ACL.
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
      guard permissions & 0o077 == 0 else { throw OttodError.insecureTokenFile }
    #endif
    let token = try String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.utf8.count >= 32 else { throw OttodError.invalidToken }
    return token
  }
}

await OttodCommand.main()

private struct Configuration {
  enum Mode { case serve, stdio }
  var mode: Mode
  var tokenFile: URL
  var stateDirectory: URL
  var workspaces: [URL]
  var socketPath: String
}

private enum OttodError: Error, LocalizedError {
  case usage
  case insecureTokenFile
  case invalidToken
  case serveUnsupported

  var errorDescription: String? {
    switch self {
    case .usage: "Invalid ottod arguments."
    case .insecureTokenFile: "The ottod token file must not be accessible by group or others."
    case .invalidToken: "The ottod token must contain at least 32 bytes."
    case .serveUnsupported: "ottod serve needs Unix sockets; on Windows use ottod stdio."
    }
  }
}

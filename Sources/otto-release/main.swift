import Foundation
import OttoCommercial
import OttoModels
import OttoRemote

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

@main
struct OttoReleaseCommand {
  fileprivate static let usage = """
    Usage:
      otto-release public-key
      otto-release sign-manifest <manifest.json> <signed-manifest.json>
      otto-release sign-remote-upgrade <manifest.json> <signed-upgrade.json>
      otto-release sign-remote-artifact <ottod> <version> <build> <platform> <signed-upgrade.json>

    Set OTTO_SIGNING_PRIVATE_KEY to a base64-encoded Ed25519 private key and
    OTTO_SIGNING_KEY_ID to its public key identifier.
    """

  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        return
      }
      let signer = try loadSigner()
      if arguments == ["public-key"] {
        print(signer.publicKey.base64EncodedString())
      } else if arguments.count == 3, arguments[0] == "sign-manifest" {
        let inputPath = arguments[1]
        let outputPath = arguments[2]
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        let manifest = try JSONDecoder.commercial.decode(
          UpdateManifest.self,
          from: Data(contentsOf: inputURL)
        )
        try validate(manifest)
        let document = try signer.sign(manifest)
        try JSONEncoder.commercial.encode(document).write(to: outputURL, options: .atomic)
      } else if arguments.count == 3, arguments[0] == "sign-remote-upgrade" {
        let inputURL = URL(fileURLWithPath: arguments[1])
        let outputURL = URL(fileURLWithPath: arguments[2])
        let manifest = try JSONDecoder.commercial.decode(
          RemoteUpgradeManifest.self,
          from: Data(contentsOf: inputURL)
        )
        try validate(manifest)
        let document = try signer.sign(manifest)
        try JSONEncoder.commercial.encode(document).write(to: outputURL, options: .atomic)
      } else if arguments.count == 6, arguments[0] == "sign-remote-artifact" {
        let artifact = URL(fileURLWithPath: arguments[1])
        guard
          let build = Int(arguments[3]),
          let platform = RemoteUpgradePlatform(rawValue: arguments[4])
        else { throw ReleaseToolError.invalidManifest }
        let metadata = try artifactMetadata(artifact)
        let manifest = RemoteUpgradeManifest(
          version: arguments[2],
          build: build,
          platform: platform,
          sha256: metadata.sha256,
          byteCount: metadata.byteCount
        )
        try validate(manifest)
        let document = try signer.sign(manifest)
        try JSONEncoder.commercial.encode(document).write(
          to: URL(fileURLWithPath: arguments[5]),
          options: .atomic
        )
      } else {
        throw ReleaseToolError.usage
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      Foundation.exit(64)
    }
  }

  private static func loadSigner() throws -> CommercialDocumentSigner {
    let environment = ProcessInfo.processInfo.environment
    guard
      let encodedKey = OttoEnvironment.value("SIGNING_PRIVATE_KEY", in: environment),
      let privateKey = Data(base64Encoded: encodedKey),
      let keyID = OttoEnvironment.value("SIGNING_KEY_ID", in: environment),
      !keyID.isEmpty
    else { throw ReleaseToolError.missingSigningKey }
    return try CommercialDocumentSigner(keyID: keyID, privateKey: privateKey)
  }

  private static func validate(_ manifest: UpdateManifest) throws {
    guard !manifest.releases.isEmpty else { throw ReleaseToolError.invalidManifest }
    for release in manifest.releases.values {
      guard
        release.artifactURL.scheme?.lowercased() == "https", release.byteCount > 0,
        release.sha256.count == 64, release.sha256.allSatisfy(\.isHexDigit),
        (0...100).contains(release.rolloutPercentage)
      else { throw ReleaseToolError.invalidManifest }
    }
  }

  private static func validate(_ manifest: RemoteUpgradeManifest) throws {
    let versionParts = manifest.version.split(separator: ".", omittingEmptySubsequences: false)
    guard
      !versionParts.isEmpty,
      versionParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      manifest.build > 0,
      manifest.protocolVersion == RemoteProtocol.version,
      manifest.byteCount > 0,
      manifest.sha256.count == 64,
      manifest.sha256.allSatisfy(\.isHexDigit)
    else { throw ReleaseToolError.invalidManifest }
  }

  private static func artifactMetadata(
    _ artifact: URL
  ) throws -> (sha256: String, byteCount: Int64) {
    guard
      let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize > 0
    else { throw ReleaseToolError.invalidArtifact }
    let handle = try FileHandle(forReadingFrom: artifact)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (digest, Int64(fileSize))
  }
}

private enum ReleaseToolError: Error, LocalizedError {
  case usage
  case missingSigningKey
  case invalidManifest
  case invalidArtifact

  var errorDescription: String? {
    switch self {
    case .usage: OttoReleaseCommand.usage
    case .missingSigningKey:
      "Set OTTO_SIGNING_PRIVATE_KEY and OTTO_SIGNING_KEY_ID in the release environment."
    case .invalidManifest: "The update manifest is invalid."
    case .invalidArtifact: "The remote daemon artifact is missing, empty, or not a regular file."
    }
  }
}

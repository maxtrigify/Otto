import Foundation
import OttoCommercial

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif
#if canImport(Darwin)
  import Darwin
#else
  #if canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #endif
#endif
#if os(macOS)
  import Security
#endif

public enum RemoteUpgradePlatform: String, Codable, Sendable, Equatable {
  case macOSArm64 = "macos-arm64"
  case macOSX8664 = "macos-x86_64"
  case linuxArm64 = "linux-arm64"
  case linuxX8664 = "linux-x86_64"

  public static var current: RemoteUpgradePlatform {
    #if os(macOS) && arch(arm64)
      return .macOSArm64
    #elseif os(macOS)
      return .macOSX8664
    #elseif arch(arm64)
      return .linuxArm64
    #else
      return .linuxX8664
    #endif
  }
}

public struct RemoteUpgradeManifest: Codable, Sendable, Equatable {
  public var version: String
  public var build: Int
  public var platform: RemoteUpgradePlatform
  public var protocolVersion: Int
  public var sha256: String
  public var byteCount: Int64
  public var generatedAt: Date

  public init(
    version: String,
    build: Int,
    platform: RemoteUpgradePlatform,
    protocolVersion: Int = RemoteProtocol.version,
    sha256: String,
    byteCount: Int64,
    generatedAt: Date = .now
  ) {
    self.version = version
    self.build = build
    self.platform = platform
    self.protocolVersion = protocolVersion
    self.sha256 = sha256
    self.byteCount = byteCount
    self.generatedAt = generatedAt
  }
}

public struct RemoteUpgradeReceipt: Codable, Sendable, Equatable {
  public var version: String
  public var build: Int
  public var previousArtifact: URL?
}

public enum RemoteUpgradeError: Error, LocalizedError, Equatable {
  case invalidManifest
  case incompatiblePlatform
  case incompatibleProtocol
  case downgradeRejected
  case invalidArtifact
  case invalidCodeSignature
  case unsafeDestination
  case installFailed

  public var errorDescription: String? {
    switch self {
    case .invalidManifest: "The remote upgrade manifest is invalid or untrusted."
    case .incompatiblePlatform: "The remote upgrade targets another platform."
    case .incompatibleProtocol: "The remote upgrade requires an unsupported protocol."
    case .downgradeRejected: "Remote daemon downgrades are not allowed."
    case .invalidArtifact: "The remote upgrade artifact failed its size or SHA-256 check."
    case .invalidCodeSignature: "The remote upgrade artifact has an invalid code signature."
    case .unsafeDestination: "The remote upgrade destination is unsafe."
    case .installFailed: "The remote upgrade could not be installed atomically."
    }
  }
}

public struct RemoteUpgradeInstaller: Sendable {
  /// File names an upgrade may replace: `ottod`, or `mused` on hosts installed before the rename.
  public static let daemonExecutableNames: Set<String> = ["ottod", "mused"]

  private let verifier: SignedDocumentVerifier
  private let codeSignatureCheck: @Sendable (URL) throws -> Void

  public init(publicKeys: [String: Data]) {
    self.verifier = SignedDocumentVerifier(publicKeys: publicKeys)
    self.codeSignatureCheck = Self.validateCodeSignature
  }

  public init(
    publicKeys: [String: Data],
    codeSignatureCheck: @escaping @Sendable (URL) throws -> Void
  ) {
    self.verifier = SignedDocumentVerifier(publicKeys: publicKeys)
    self.codeSignatureCheck = codeSignatureCheck
  }

  public func install(
    document: SignedDocument,
    artifact: URL,
    destination: URL,
    currentVersion: String,
    currentBuild: Int
  ) throws -> RemoteUpgradeReceipt {
    let manifest: RemoteUpgradeManifest
    do {
      manifest = try verifier.verify(document, as: RemoteUpgradeManifest.self)
    } catch {
      throw RemoteUpgradeError.invalidManifest
    }
    guard manifest.platform == .current else { throw RemoteUpgradeError.incompatiblePlatform }
    guard manifest.protocolVersion <= RemoteProtocol.version else {
      throw RemoteUpgradeError.incompatibleProtocol
    }
    let comparison = compareVersions(manifest.version, currentVersion)
    guard comparison > 0 || (comparison == 0 && manifest.build > currentBuild) else {
      throw RemoteUpgradeError.downgradeRejected
    }
    try validateDestination(destination)
    try verifyArtifact(artifact, manifest: manifest)

    let directory = destination.deletingLastPathComponent()
    let staged = directory.appending(path: ".ottod-upgrade-\(UUID().uuidString)")
    let backup = destination.appendingPathExtension("previous")
    defer { _ = unlink(staged.path) }
    do {
      try FileManager.default.copyItem(at: artifact, to: staged)
      guard chmod(staged.path, 0o755) == 0 else {
        throw RemoteUpgradeError.installFailed
      }
      try verifyArtifact(staged, manifest: manifest)
      do { try codeSignatureCheck(staged) } catch {
        throw RemoteUpgradeError.invalidCodeSignature
      }

      var previousArtifact: URL?
      if FileManager.default.fileExists(atPath: destination.path) {
        if FileManager.default.fileExists(atPath: backup.path) { _ = unlink(backup.path) }
        #if os(macOS)
          guard renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) == 0 else {
            throw RemoteUpgradeError.installFailed
          }
          guard rename(staged.path, backup.path) == 0 else {
            _ = renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP))
            throw RemoteUpgradeError.installFailed
          }
        #else
          guard link(destination.path, backup.path) == 0,
            rename(staged.path, destination.path) == 0
          else {
            _ = unlink(backup.path)
            throw RemoteUpgradeError.installFailed
          }
        #endif
        previousArtifact = backup
      } else {
        guard rename(staged.path, destination.path) == 0 else {
          throw RemoteUpgradeError.installFailed
        }
      }

      do {
        try verifyArtifact(destination, manifest: manifest)
        try codeSignatureCheck(destination)
      } catch {
        if let previousArtifact {
          #if os(macOS)
            _ = renamex_np(previousArtifact.path, destination.path, UInt32(RENAME_SWAP))
          #else
            _ = rename(previousArtifact.path, destination.path)
          #endif
        } else {
          _ = unlink(destination.path)
        }
        if error as? RemoteUpgradeError == .invalidArtifact {
          throw RemoteUpgradeError.invalidArtifact
        }
        throw RemoteUpgradeError.invalidCodeSignature
      }
      return RemoteUpgradeReceipt(
        version: manifest.version,
        build: manifest.build,
        previousArtifact: previousArtifact
      )
    } catch let error as RemoteUpgradeError {
      throw error
    } catch {
      throw RemoteUpgradeError.installFailed
    }
  }

  private func verifyArtifact(_ artifact: URL, manifest: RemoteUpgradeManifest) throws {
    guard artifact.isFileURL,
      let values = try? artifact.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      Int64(values.fileSize ?? -1) == manifest.byteCount,
      manifest.byteCount > 0,
      manifest.sha256.count == 64,
      manifest.sha256.allSatisfy(\.isHexDigit)
    else { throw RemoteUpgradeError.invalidArtifact }
    let handle = try FileHandle(forReadingFrom: artifact)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
      throw RemoteUpgradeError.invalidArtifact
    }
  }

  private func validateDestination(_ destination: URL) throws {
    // `mused` is the daemon's name before the rename; installs that have not been migrated
    // still upgrade in place.
    guard destination.isFileURL,
      RemoteUpgradeInstaller.daemonExecutableNames.contains(destination.lastPathComponent)
    else {
      throw RemoteUpgradeError.unsafeDestination
    }
    let directory = destination.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isWritableFile(atPath: directory.path),
      let resolved = realpath(directory.path, nil)
    else { throw RemoteUpgradeError.unsafeDestination }
    defer { free(resolved) }

    var destinationMetadata = stat()
    if lstat(destination.path, &destinationMetadata) == 0 {
      guard destinationMetadata.st_mode & S_IFMT == S_IFREG else {
        throw RemoteUpgradeError.unsafeDestination
      }
    } else if errno != ENOENT {
      throw RemoteUpgradeError.unsafeDestination
    }
  }

  private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
      let leftPart = index < left.count ? left[index] : 0
      let rightPart = index < right.count ? right[index] : 0
      if leftPart != rightPart { return leftPart < rightPart ? -1 : 1 }
    }
    return 0
  }

  private static func validateCodeSignature(_ url: URL) throws {
    #if os(macOS)
      var staticCode: SecStaticCode?
      guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
        let staticCode,
        SecStaticCodeCheckValidity(
          staticCode,
          SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
          nil
        ) == errSecSuccess
      else { throw RemoteUpgradeError.invalidCodeSignature }
    #else
      _ = url
    #endif
  }
}

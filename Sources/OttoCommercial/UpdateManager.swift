import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

public enum UpdateArtifactVerifier {
  public static func verify(fileURL: URL, release: UpdateRelease) throws {
    guard fileURL.isFileURL else { throw CommercialError.invalidRelease }
    let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, Int64(values.fileSize ?? -1) == release.byteCount else {
      throw CommercialError.invalidRelease
    }

    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest.caseInsensitiveCompare(release.sha256) == .orderedSame else {
      throw CommercialError.invalidRelease
    }
  }
}

public struct UpdateManager: Sendable {
  private let client: CommercialClient
  private let verifier: SignedDocumentVerifier

  public init(client: CommercialClient, verifier: SignedDocumentVerifier) {
    self.client = client
    self.verifier = verifier
  }

  public func availableRelease(
    channel: ReleaseChannel,
    currentVersion: String,
    currentBuild: Int,
    macOSVersion: String,
    rolloutBucket: Int
  ) async throws -> UpdateRelease? {
    let signedManifest = try await client.updateManifest()
    let manifest = try verifier.verify(signedManifest, as: UpdateManifest.self)
    guard !manifest.blockedVersions.contains(currentVersion) else { return nil }
    guard let release = manifest.releases[channel] else { return nil }
    guard release.artifactURL.scheme?.lowercased() == "https" else {
      throw CommercialError.insecureURL
    }
    guard (0...100).contains(release.rolloutPercentage), (0..<100).contains(rolloutBucket) else {
      throw CommercialError.invalidRelease
    }
    guard rolloutBucket < release.rolloutPercentage else { return nil }
    guard compareVersions(macOSVersion, release.minimumMacOSVersion) >= 0 else { return nil }
    let versionComparison = compareVersions(release.version, currentVersion)
    guard versionComparison > 0 || (versionComparison == 0 && release.build > currentBuild) else {
      return nil
    }
    guard release.sha256.count == 64, release.sha256.allSatisfy({ $0.isHexDigit }) else {
      throw CommercialError.invalidRelease
    }
    guard release.byteCount > 0 else { throw CommercialError.invalidRelease }
    return release
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
}

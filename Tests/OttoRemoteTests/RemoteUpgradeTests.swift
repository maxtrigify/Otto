import CryptoKit
import Foundation
import OttoCommercial
import OttoRemote
import Testing

@Suite("Remote daemon upgrades")
struct RemoteUpgradeTests {
  @Test("Signed upgrade installs atomically and preserves one rollback artifact")
  func installsAndBacksUp() throws {
    let fixture = try UpgradeFixture()
    defer { fixture.cleanup() }
    let oldData = Data("old-daemon".utf8)
    let newData = Data("new-daemon".utf8)
    try oldData.write(to: fixture.destination)
    try newData.write(to: fixture.artifact)
    let document = try fixture.document(for: newData, version: "0.2.0", build: 2)
    let installer = RemoteUpgradeInstaller(publicKeys: fixture.publicKeys) { _ in }

    let receipt = try installer.install(
      document: document,
      artifact: fixture.artifact,
      destination: fixture.destination,
      currentVersion: "0.1.0",
      currentBuild: 1
    )
    #expect(try Data(contentsOf: fixture.destination) == newData)
    let backup = try #require(receipt.previousArtifact)
    #expect(try Data(contentsOf: backup) == oldData)
    #expect(receipt.version == "0.2.0")
  }

  @Test("Tampering, unknown keys, downgrades, platforms, protocols, and unsafe targets fail closed")
  func rejectsInvalidUpgrades() throws {
    let fixture = try UpgradeFixture()
    defer { fixture.cleanup() }
    let data = Data("candidate".utf8)
    try data.write(to: fixture.artifact)
    let valid = try fixture.document(for: data, version: "0.2.0", build: 2)
    let installer = RemoteUpgradeInstaller(publicKeys: fixture.publicKeys) { _ in }
    try Data("tampered".utf8).write(to: fixture.artifact)
    #expect(throws: RemoteUpgradeError.invalidArtifact) {
      try installer.install(
        document: valid, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.1.0", currentBuild: 1)
    }
    try data.write(to: fixture.artifact)

    let unknownKey = RemoteUpgradeInstaller(publicKeys: [:]) { _ in }
    #expect(throws: RemoteUpgradeError.invalidManifest) {
      try unknownKey.install(
        document: valid, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.1.0", currentBuild: 1)
    }
    #expect(throws: RemoteUpgradeError.downgradeRejected) {
      try installer.install(
        document: valid, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.3.0", currentBuild: 1)
    }

    let wrongPlatform = try fixture.document(
      for: data,
      version: "0.2.0",
      build: 2,
      platform: RemoteUpgradePlatform.current == .macOSArm64 ? .macOSX8664 : .macOSArm64
    )
    #expect(throws: RemoteUpgradeError.incompatiblePlatform) {
      try installer.install(
        document: wrongPlatform, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.1.0", currentBuild: 1)
    }
    let futureProtocol = try fixture.document(
      for: data, version: "0.2.0", build: 2, protocolVersion: 999)
    #expect(throws: RemoteUpgradeError.incompatibleProtocol) {
      try installer.install(
        document: futureProtocol, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.1.0", currentBuild: 1)
    }
    let unsafe = fixture.root.appending(path: "not-ottod")
    #expect(throws: RemoteUpgradeError.unsafeDestination) {
      try installer.install(
        document: valid, artifact: fixture.artifact, destination: unsafe,
        currentVersion: "0.1.0", currentBuild: 1)
    }
  }

  @Test("Hosts installed before the rename upgrade their `mused` binary in place")
  func upgradesLegacyDaemonName() throws {
    for name in ["mused", "ottod"] {
      let fixture = try UpgradeFixture(daemonName: name)
      defer { fixture.cleanup() }
      let newData = Data("new-daemon-\(name)".utf8)
      try Data("old".utf8).write(to: fixture.destination)
      try newData.write(to: fixture.artifact)
      let document = try fixture.document(for: newData, version: "0.2.0", build: 2)
      let installer = RemoteUpgradeInstaller(publicKeys: fixture.publicKeys) { _ in }
      _ = try installer.install(
        document: document, artifact: fixture.artifact, destination: fixture.destination,
        currentVersion: "0.1.0", currentBuild: 1)
      #expect(try Data(contentsOf: fixture.destination) == newData)
    }
    #expect(RemoteUpgradeInstaller.daemonExecutableNames == ["ottod", "mused"])
  }

  @Test("A failed post-install signature check restores the previous daemon")
  func rollback() throws {
    let fixture = try UpgradeFixture()
    defer { fixture.cleanup() }
    let oldData = Data("known-good".utf8)
    let newData = Data("bad-after-install".utf8)
    try oldData.write(to: fixture.destination)
    try newData.write(to: fixture.artifact)
    let document = try fixture.document(for: newData, version: "0.2.0", build: 2)
    let destination = fixture.destination
    let installer = RemoteUpgradeInstaller(publicKeys: fixture.publicKeys) { url in
      if url == destination { throw RemoteUpgradeError.invalidCodeSignature }
    }
    #expect(throws: RemoteUpgradeError.invalidCodeSignature) {
      try installer.install(
        document: document, artifact: fixture.artifact, destination: destination,
        currentVersion: "0.1.0", currentBuild: 1)
    }
    #expect(try Data(contentsOf: destination) == oldData)
  }

  @Test("A staged artifact changed after verification is rejected and rolled back")
  func stagedArtifactRaceRollsBack() throws {
    let fixture = try UpgradeFixture()
    defer { fixture.cleanup() }
    let oldData = Data("known-good".utf8)
    let newData = Data("signed-candidate".utf8)
    try oldData.write(to: fixture.destination)
    try newData.write(to: fixture.artifact)
    let document = try fixture.document(for: newData, version: "0.2.0", build: 2)
    let destination = fixture.destination
    let installer = RemoteUpgradeInstaller(publicKeys: fixture.publicKeys) { url in
      if url != destination {
        try Data("changed-after-staging".utf8).write(to: url)
      }
    }
    #expect(throws: RemoteUpgradeError.invalidArtifact) {
      try installer.install(
        document: document,
        artifact: fixture.artifact,
        destination: destination,
        currentVersion: "0.1.0",
        currentBuild: 1
      )
    }
    #expect(try Data(contentsOf: destination) == oldData)
  }
}

private struct UpgradeFixture {
  let root: URL
  let artifact: URL
  let destination: URL
  let signer: CommercialDocumentSigner

  var publicKeys: [String: Data] { [signer.keyID: signer.publicKey] }

  init(daemonName: String = "ottod") throws {
    root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appending(path: "otto-up-\(UUID().uuidString.prefix(12))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    artifact = root.appending(path: "candidate")
    destination = root.appending(path: daemonName)
    signer = CommercialDocumentSigner(keyID: "remote-upgrade-test")
  }

  func document(
    for data: Data,
    version: String,
    build: Int,
    platform: RemoteUpgradePlatform = .current,
    protocolVersion: Int = RemoteProtocol.version
  ) throws -> SignedDocument {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return try signer.sign(
      RemoteUpgradeManifest(
        version: version,
        build: build,
        platform: platform,
        protocolVersion: protocolVersion,
        sha256: digest,
        byteCount: Int64(data.count)
      ))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

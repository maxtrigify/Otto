import Foundation
import Testing

@testable import OttoVoice

@Suite("Whistle speech recognition")
struct WhistleTests {
  private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "otto-whistle-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Nothing downloads until the person agrees to the license terms")
  func refusesWithoutTerms() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = DownloadCounter()
    let installer = WhistleInstaller(
      installRoot: root.appending(path: "Whistle"), termsAccepted: { false },
      download: { url in
        await calls.record()
        return url
      })
    var states = installer.updates.makeAsyncIterator()
    #expect(await states.next() == .notInstalled)
    await installer.install()
    #expect(
      await states.next() == .failed(WhistleInstallerError.termsNotAccepted.localizedDescription))
    #expect(await calls.count == 0)
  }

  @Test("Downloads must match the pinned size and sha256 exactly")
  func verifiesPinnedFiles() async throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let installer = WhistleInstaller(installRoot: root.appending(path: "Whistle"))
    let short = root.appending(path: "short")
    try Data(count: 10).write(to: short)
    await #expect(throws: WhistleInstallerError.self) {
      try await installer.verify(short, as: WhistleInstaller.engine)
    }
    // Right size, wrong bytes: only the checksum can catch it.
    let forged = root.appending(path: "forged")
    try Data(count: WhistleInstaller.engine.size).write(to: forged)
    await #expect {
      try await installer.verify(forged, as: WhistleInstaller.engine)
    } throws: { error in
      (error as? WhistleInstallerError).map {
        if case .checksum = $0 { true } else { false }
      } ?? false
    }
  }

  @Test("Pinned downloads come from the authors' Hugging Face repositories at fixed revisions")
  func pinnedSources() {
    for artifact in [WhistleInstaller.engine, WhistleInstaller.model] {
      #expect(artifact.url.host == "huggingface.co")
      #expect(artifact.url.path.hasPrefix("/Cactus-Compute/"))
      #expect(artifact.url.path.contains("/resolve/"))
      #expect(!artifact.url.path.contains("/resolve/main/"))
      #expect(artifact.sha256.count == 64)
    }
    #expect(WhistleInstaller.engine.executable && !WhistleInstaller.model.executable)
  }

  @Test("Agreement is tied to the pinned revision")
  func termsAgreement() throws {
    let defaults = try #require(UserDefaults(suiteName: "otto-whistle-terms-\(UUID())"))
    #expect(!WhistleTerms.isAccepted(defaults))
    WhistleTerms.accept(defaults)
    #expect(WhistleTerms.isAccepted(defaults))
    defaults.set("whistle@older needle3@older", forKey: WhistleTerms.acceptedKey)
    #expect(!WhistleTerms.isAccepted(defaults))
    WhistleTerms.withdraw(defaults)
    #expect(!WhistleTerms.isAccepted(defaults))
  }

  @Test("A missing install is reported, not run")
  func missingInstall() throws {
    let root = try scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(WhistleRuntimeConfiguration(root: root).validationError() != nil)
  }

  @Test("The engine's JSON transcript is read, plain output is accepted, empty output fails")
  func parsesOutput() throws {
    let json = try WhistleOfflineRunner.parse(
      "loading model\n{\"text\":\" turn off the kitchen lights \",\"language\":\"en\",\"ttft_ms\":41.2,\"decode_tps\":180.0}\n"
    )
    #expect(json == WhistleTranscription(text: "turn off the kitchen lights", language: "en"))
    #expect(try WhistleOfflineRunner.parse("hello world\n").text == "hello world")
    #expect(throws: WhistleRuntimeError.missingResult) { try WhistleOfflineRunner.parse("\n  \n") }
  }
}

private actor DownloadCounter {
  var count = 0
  func record() { count += 1 }
}

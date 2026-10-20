import Foundation
import OttoCore
import OttoModels
import OttoServices
import Testing

@MainActor
@Suite("Mobile host startup")
struct MobileHostStartupTests {
  @Test("General startup becomes ready without scanning unrelated Brain files")
  func startupDoesNotRebuildBrain() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mobile-ready-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Startup")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(
          canvases: [canvas], activeCanvasID: canvas.id)), workspacePath: root.path)
    defer { services.stop() }
    let unrelated = root.appending(path: ".otto/brain/log/unrelated.md")
    try Data("Not a memory record".utf8).write(to: unrelated)
    await services.start()
    let brain = try #require(services.brain)
    _ = await brain.manifest
    #expect(services.isOnline)
    #expect(
      FileManager.default.fileExists(atPath: unrelated.path),
      "Startup must not open and quarantine unrelated history during an index rebuild")
    await services.shutdown()
  }

  @Test("Host starts before general services, reports failures and retries")
  func startupAndRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "mobile-startup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let canvas = OttoCanvas(name: "Host startup")
    let services = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: root.path)
    defer { services.stop() }
    // The pre-rename MUSE_ name is still honoured.
    await services.startMobileHostIfConfigured(environment: ["MUSE_MOBILE_HOST_ALLOW_LAN": "1"])
    #expect(services.mobileHostError != nil)
    #expect(!services.isStartingMobileHost)
    #expect(services.mobilePairingPayload == nil)
    #expect(services.mobileHostEndpoint == nil)

    let port = Int.random(in: 35000...45000)
    await services.startMobileHostIfConfigured(environment: ["OTTO_MOBILE_HOST_PORT": String(port)])
    let deadline = Date().addingTimeInterval(5)
    while services.isStartingMobileHost && Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!services.isOnline, "Mobile host does not depend on brain/tool startup")
    #expect(services.mobileHostError == nil)
    let endpoint = try #require(services.mobileHostEndpoint)
    #expect(services.mobilePairingPayload?.baseURL == endpoint)
    let (_, response) = try await URLSession.shared.data(from: endpoint.appending(path: "health"))
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let firstOffer = services.mobilePairingPayload?.offerID
    _ = try await services.refreshMobilePairingOffer()
    #expect(services.mobilePairingPayload?.offerID != firstOffer)

    let secondRoot = root.appending(path: "second")
    let second = ApplicationServices(
      store: CanvasStore(
        snapshot: WorkspaceSnapshot(canvases: [canvas], activeCanvasID: canvas.id)),
      workspacePath: secondRoot.path)
    defer { second.stop() }
    await second.startMobileHostIfConfigured(environment: ["MUSE_MOBILE_HOST_PORT": String(port)])
    let conflictDeadline = Date().addingTimeInterval(5)
    while second.isStartingMobileHost && Date() < conflictDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(second.mobileHostError != nil)
    #expect(!second.isStartingMobileHost)
    #expect(second.mobileHostEndpoint == nil)
    #expect(second.mobilePairingPayload == nil)
  }
}

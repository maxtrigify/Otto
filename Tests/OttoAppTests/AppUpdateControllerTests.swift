import Foundation
import Testing

@testable import OttoApp

@Suite("App update controller")
struct AppUpdateControllerTests {
  @Test("Artifact links separate line and column suffixes from local paths")
  func artifactReferenceLines() {
    #expect(
      ArtifactReference.parse("Plans/Muse Custom Agents Implementation Plan.md:31")
        == ArtifactReference(
          path: "Plans/Muse Custom Agents Implementation Plan.md", line: 31, column: nil)
    )
    #expect(
      ArtifactReference.parse("Sources/OttoApp/WorkspaceView.swift:1026:14")
        == ArtifactReference(
          path: "Sources/OttoApp/WorkspaceView.swift", line: 1026, column: 14)
    )
    #expect(
      ArtifactReference.parse("Plans/version:final.md")
        == ArtifactReference(path: "Plans/version:final.md", line: nil, column: nil)
    )
  }

  @MainActor
  @Test("Activation checks discover releases after launch without duplicate immediate requests")
  func activationCheckCadence() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(AppUpdateController.shouldCheckAfterActivation(lastCheckAt: nil, now: now))
    #expect(
      !AppUpdateController.shouldCheckAfterActivation(
        lastCheckAt: now.addingTimeInterval(-59),
        now: now
      ))
    #expect(
      AppUpdateController.shouldCheckAfterActivation(
        lastCheckAt: now.addingTimeInterval(-60),
        now: now
      ))
  }

  @MainActor
  @Test("Update restart requests bypass the ordinary protected-quit path")
  func relaunchRequest() {
    let request = UpdateRelaunchRequest()
    #expect(!request.isActive)
    request.begin()
    #expect(request.isActive)
  }

  @MainActor
  @Test("Update termination cleanup and timeout approve quit only once")
  func updateTerminationGateRepliesOnce() {
    var replies = 0
    let gate = UpdateTerminationGate { replies += 1 }
    gate.finish()
    gate.finish()
    #expect(replies == 1)
  }

  @MainActor
  @Test("Detached update helper bounds its wait for the old app")
  func relaunchHelperHasBoundedExit() {
    let script = AppUpdateController.relaunchHelperScript
    #expect(script.contains("kill -TERM"))
    #expect(script.contains("kill -KILL"))
    #expect(script.contains("WAITED"))
  }
}

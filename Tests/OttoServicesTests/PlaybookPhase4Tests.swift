import Foundation
import OttoModels
import OttoServices
import Testing

@Suite("Phase 4 teachability and identity")
struct PlaybookPhase4Tests {
  @Test("Demonstration redacts secrets and requires a successful test before save")
  func safeLifecycle() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PlaybookStore(workspacePath: root.path)
    let step = PlaybookStep(
      instruction: "Sign in and open the report",
      anchor: SemanticAnchor(role: "button", name: "Open report", nearbyText: "Reports"),
      inputs: ["account": "max@example.com", "password": "hunter2"])
    let draft = try await store.capture(
      name: "Weekly report", profileID: UUID(), demonstratedSteps: [step])
    #expect(draft.steps[0].inputs["password"] == "<redacted>")
    let renamed = try await store.update(id: draft.id, name: "Monthly report", steps: draft.steps)
    #expect(renamed.name == "Monthly report")
    await #expect(throws: PlaybookError.testRequired) { try await store.save(id: draft.id) }
    let tested = try await store.runSafeTest(
      id: draft.id, now: Date(timeIntervalSince1970: 100))
    #expect(tested.state == .tested)
    #expect(tested.lastTestEvidence?.validatedStepCount == 1)
    #expect(tested.lastTestEvidence?.externalEffectsBlocked == true)
    let saved = try await store.save(id: draft.id)
    #expect(saved.state == .saved)

    let reloaded = PlaybookStore(workspacePath: root.path)
    #expect(await reloaded.all().first?.state == .saved)
  }

  @Test("A tested playbook previews every routine decision before remaining disabled")
  func routinePreview() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileID = UUID()
    let store = PlaybookStore(workspacePath: root.path)
    let draft = try await store.capture(
      name: "Publish digest", profileID: profileID,
      demonstratedSteps: [
        PlaybookStep(
          instruction: "Publish the digest",
          anchor: SemanticAnchor(role: "button", name: "Publish"),
          inputs: ["digest": "{{digest}}"])
      ])
    _ = try await store.runSafeTest(id: draft.id)
    _ = try await store.save(id: draft.id)
    let now = Date(timeIntervalSince1970: 1_000)
    let preview = try await store.routinePreview(
      id: draft.id, intervalSeconds: 3_600, permissions: ["notion.write"],
      overlap: .queueLatest, now: now)
    #expect(preview.routine.enabled == false)
    #expect(preview.routine.concurrency == .queueLatest)
    #expect(preview.routine.toolAllowlist == ["notion.write"])
    #expect(preview.inputs == ["digest"])
    #expect(preview.nextRunAt == now.addingTimeInterval(3_600))
  }

  @Test("Invalid edits preserve saved steps; valid edits invalidate validation")
  func editValidation() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = PlaybookStore(workspacePath: root.path)
    let step = PlaybookStep(
      instruction: "Return the verification marker",
      anchor: SemanticAnchor(role: "text", name: "Response"))
    let draft = try await store.capture(
      name: "Verification", profileID: UUID(), demonstratedSteps: [step])
    _ = try await store.runSafeTest(id: draft.id)
    let saved = try await store.save(id: draft.id)
    await #expect(throws: PlaybookError.self) {
      try await store.update(id: draft.id, name: "", steps: [])
    }
    #expect(await store.all().first == saved)
    let reloaded = PlaybookStore(workspacePath: root.path)
    let persisted = try #require(await reloaded.all().first)
    #expect(persisted.id == saved.id)
    #expect(persisted.name == saved.name)
    #expect(persisted.steps == saved.steps)
    #expect(persisted.state == .saved)
    #expect(persisted.lastTestEvidence?.id == saved.lastTestEvidence?.id)
    var changed = step
    changed.instruction = "Return a different marker"
    _ = try await store.update(id: draft.id, steps: [changed])
    await #expect(throws: PlaybookError.testRequired) { try await store.save(id: draft.id) }
    await #expect(throws: PlaybookError.testRequired) {
      try await store.routinePreview(
        id: draft.id, intervalSeconds: 86_400, permissions: [], overlap: .skip)
    }
  }

  @Test("Voice remains a profile sidecar and connector backends preserve authorization")
  func identityAndBackends() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let profileID = UUID()
    var voices = BotVoicePreferenceStore(workspacePath: root.path)
    try await voices.set(
      BotVoicePreference(profileID: profileID, voiceID: "voice-warm", autoSpeak: .needsYou))
    voices = BotVoicePreferenceStore(workspacePath: root.path)
    #expect(await voices.preference(profileID: profileID).voiceID == "voice-warm")
    #expect(await voices.preference(profileID: profileID).autoSpeak == .needsYou)

    let access: Set<String> = ["notion"]
    let local = try ConnectorBackendRouter.plan(
      integrationID: "notion", backend: .local, effectiveAccess: access)
    let managed = try ConnectorBackendRouter.plan(
      integrationID: "notion", backend: .managed, effectiveAccess: access)
    #expect(local.integrationID == managed.integrationID)
    #expect(local.backend != managed.backend)
    #expect(throws: ConnectorBackendRouter.AuthorizationError.connectionNotAllowed) {
      try ConnectorBackendRouter.plan(
        integrationID: "stripe", backend: .managed, effectiveAccess: access)
    }
  }

  @Test("Playbooks saved before test evidence remain readable but require retesting")
  func legacyEvidenceMigration() throws {
    struct LegacyPlaybook: Codable {
      var id: UUID
      var name: String
      var profileID: UUID
      var steps: [PlaybookStep]
      var state: PlaybookState
      var testedAt: Date?
      var updatedAt: Date
    }
    let legacy = LegacyPlaybook(
      id: UUID(), name: "Legacy", profileID: UUID(),
      steps: [
        PlaybookStep(
          instruction: "Open", anchor: SemanticAnchor(role: "button", name: "Open"))
      ],
      state: .tested, testedAt: .now, updatedAt: .now)
    let decoded = try JSONDecoder().decode(
      Playbook.self, from: JSONEncoder().encode(legacy))
    #expect(decoded.state == .tested)
    #expect(decoded.lastTestEvidence == nil)
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-phase4-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

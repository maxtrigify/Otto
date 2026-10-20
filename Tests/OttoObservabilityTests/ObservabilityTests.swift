import Foundation
import OttoModels
import OttoObservability
import OttoRuntime
import OttoTools
import Testing

@Suite("Privacy-safe observability")
struct ObservabilityTests {
  @Test("Runtime output and user content never enter the diagnostic timeline")
  func excludesUserContent() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ObservabilityStore(
      directory: directory,
      appVersion: "1.2.3",
      operatingSystemVersion: "macOS 26.3 (Build 25D125)",
      eventLimit: 64
    )
    try await store.beginSession()
    let agentID = UUID()
    try await store.recordRuntimeEvent(
      .output(
        agentID: agentID,
        text: "SECRET PROMPT /Users/alice/private.swift https://private.example audio transcript"
      ),
      provider: .codex
    )
    try await store.recordRuntimeEvent(
      .stateChanged(agentID: agentID, state: .working, confidence: 0.9),
      provider: .codex
    )
    let encoded = String(
      decoding: try JSONEncoder().encode(await store.timeline()),
      as: UTF8.self
    )
    for forbidden in [
      "SECRET PROMPT", "/Users/alice", "private.swift", "private.example", "transcript",
    ] {
      #expect(!encoded.contains(forbidden))
    }
    #expect(encoded.contains("agent.state_changed"))
    #expect(encoded.contains("Codex"))
  }

  @Test("A stale marker records abnormal exit while a clean end does not")
  func detectsAbnormalPreviousSession() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try ObservabilityStore(directory: directory, appVersion: "1.0")
    try await first.beginSession()

    let afterCrash = try ObservabilityStore(directory: directory, appVersion: "1.0")
    try await afterCrash.beginSession()
    #expect(await afterCrash.snapshot().previousSessionAbnormal)
    #expect(await afterCrash.timeline().contains { $0.kind == .previousSessionAbnormal })
    try await afterCrash.endSession()

    let afterCleanExit = try ObservabilityStore(directory: directory, appVersion: "1.0")
    try await afterCleanExit.beginSession()
    #expect(!(await afterCleanExit.snapshot().previousSessionAbnormal))
    try await afterCleanExit.endSession()
  }

  @Test("Tool audit events expose only allowlisted names, outcome, and duration")
  func toolMetrics() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let observability = try ObservabilityStore(directory: directory, appVersion: "1.0")
    let registry = ToolRegistry(auditSink: observability)
    try await registry.register(ObservedTool())
    _ = try await registry.call(
      name: "test.observed",
      input: .object(["secret": .string("never persist this")]),
      context: ToolContext(actorID: "/Users/private actor", scopes: [])
    )
    let snapshot = await observability.snapshot()
    #expect(snapshot.toolSuccessCount == 1)
    #expect(snapshot.toolFailureCount == 0)
    #expect((snapshot.toolLatencyMedianMilliseconds ?? -1) >= 0)
    let encoded = String(
      decoding: try JSONEncoder().encode(await observability.timeline()),
      as: UTF8.self
    )
    #expect(encoded.contains("test.observed"))
    #expect(!encoded.contains("never persist this"))
    #expect(!encoded.contains("/Users/private"))
  }

  @Test("Export is impossible without explicit consent and contains aggregates only")
  func consentGate() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ObservabilityStore(directory: directory, appVersion: "1.0")
    let exporter = CapturingExporter()
    await #expect(throws: ObservabilityError.consentRequired) {
      try await store.export(consent: false, using: exporter)
    }
    #expect(await exporter.snapshots.isEmpty)
    try await store.export(consent: true, using: exporter)
    #expect(await exporter.snapshots.count == 1)
  }

  @Test("Voice diagnostics reject arbitrary transcript-like values")
  func voiceStateAllowlist() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try ObservabilityStore(directory: directory, appVersion: "1.0")
    try await store.recordVoiceState("listening")
    await #expect(throws: ObservabilityError.invalidEvent) {
      try await store.recordVoiceState("summarise /Users/alice/secret.swift")
    }
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "otto-observability-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private struct ObservedTool: OttoTool {
  struct Input: Codable, Sendable { var secret: String }
  struct Output: Codable, Sendable { var accepted: Bool }
  static let definition = ToolDefinition(
    name: "test.observed",
    description: "Test diagnostic timing",
    inputSchema: .object(["type": .string("object")]),
    outputSchema: .object(["type": .string("object")]),
    requiredScopes: [],
    riskLevel: .read
  )

  func call(_ input: Input, context: ToolContext) async throws -> Output {
    Output(accepted: !input.secret.isEmpty)
  }
}

private actor CapturingExporter: ObservabilityExporter {
  private(set) var snapshots: [ObservabilitySnapshot] = []

  func export(_ snapshot: ObservabilitySnapshot) {
    snapshots.append(snapshot)
  }
}

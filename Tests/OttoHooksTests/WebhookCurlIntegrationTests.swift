import Crypto
import Foundation
import OttoApplicationTools
import OttoControl
import OttoHooks
import OttoModels
import OttoRuntime
import OttoSecurity
import OttoTools
import Testing

@testable import OttoServices

@Suite(.serialized)
struct WebhookCurlIntegrationTests {
  @MainActor @Test func curlFiresRoutineEngineAndCompletesRealAgentProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-hook-e2e-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let routineID = UUID()
    let slug = "integration"
    let secret = "integration-secret-32-bytes-long"
    let service = "io.openotto.hook-test.\(UUID().uuidString)"
    let secretStore = makeDefaultSecretStore(service: service)
    try await secretStore.set(secret, for: "routine.webhook.\(routineID.uuidString).secret")
    defer {
      Task { try? await secretStore.delete("routine.webhook.\(routineID.uuidString).secret") }
    }
    let routes = root.appending(path: "routes.json")
    try JSONEncoder().encode([WebhookRoute(routineID: routineID, slug: slug, enabled: true)])
      .write(to: routes)

    let supervisor = AgentSupervisor()
    let nodeID = try await supervisor.spawnDeterministicMock()
    let routineStore = RoutineStore(workspacePath: root.path)
    let routine = try routineStore.save(
      Routine(
        id: routineID, name: "Webhook integration", instruction: "Summarize the event",
        trigger: .webhook(slug: slug, filter: .jsonPathEquals(path: "$.event", value: "push")),
        target: .existingAgent(nodeID: nodeID), enabled: true))
    let engine = RoutineEngine(
      store: routineStore, eventBus: supervisor.eventBus, tickSeconds: 30,
      executor: { _, prompt in
        try await supervisor.sendPrompt(agentID: nodeID, prompt: prompt)
        return nodeID
      },
      resultProvider: { id in try? await supervisor.snapshot(agentID: id).result },
      deliveryHandler: { _, _, _ in })
    engine.start()
    defer { engine.stop() }
    let toolRegistry = ToolRegistry()
    let authenticator = ControlAuthenticator()
    try await toolRegistry.register(
      RoutineWebhookReceiveTool { input, context in
        #expect(context.source == .automation)
        let result = try await engine.fire(
          routine, payload: .init(text: input.body, idempotencyKey: input.idempotencyKey))
        switch result {
        case .fired(let runID, let agentNodeID):
          return RoutineTestRunOutput(fired: true, runID: runID, agentNodeID: agentNodeID)
        case .skipped(let reason): return RoutineTestRunOutput(fired: false, reason: reason)
        }
      })
    let token = await authenticator.issue(
      actorID: "hook-test", scopes: [.agentControl], source: .automation,
      interactionPrivileges: [])
    let socket = "/tmp/mh-\(UUID().uuidString.prefix(8)).sock"
    defer { unlink(socket) }
    let server = try ControlServer(
      socketPath: socket, registry: toolRegistry, authenticator: authenticator)
    defer { server.stop() }
    let port = Int.random(in: 20_000...40_000)
    let daemon = Process()
    let output = Pipe()
    daemon.executableURL = try hookExecutable()
    daemon.environment = ProcessInfo.processInfo.environment.merging([
      "OTTO_HOOK_ROUTES": routes.path, "OTTO_HOOK_PORT": String(port),
      "OTTO_HOOK_SECRET_SERVICE": service, "OTTO_CONTROL_SOCKET": socket,
      "OTTO_CONTROL_TOKEN": token,
    ]) { _, new in new }
    daemon.standardOutput = output
    daemon.standardError = output
    try daemon.run()
    defer { if daemon.isRunning { daemon.terminate() } }
    try await waitForHealth(port: port)
    let body = #"{"event":"push"}"#
    let signature = sign(Data(body.utf8), secret: secret)
    let curl = Process()
    let curlOutput = Pipe()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = [
      "-sS", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
      "http://127.0.0.1:\(port)/hooks/\(slug)", "-H", "X-Muse-Signature: \(signature)",
      "-H", "X-GitHub-Delivery: delivery-1", "--data-binary", body,
    ]
    curl.standardOutput = curlOutput
    try curl.run()
    curl.waitUntilExit()
    #expect(
      String(decoding: curlOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        == "202")
    for _ in 0..<200 {
      if routineStore.recentRuns(routineID: routineID).contains(where: { $0.outcome == .completed })
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let runs = routineStore.recentRuns(routineID: routineID)
    #expect(runs.contains { $0.outcome == .completed && $0.agentNodeID == nodeID })
    #expect(
      try await supervisor.snapshot(agentID: nodeID).lastPrompt?.contains("payload (untrusted)")
        == true)
  }

  private func hookExecutable() throws -> URL {
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    var candidates: [URL] = [
      Bundle(for: WebhookTestBundleMarker.self).bundleURL.deletingLastPathComponent()
        .appending(path: "otto-hookd")
    ]
    for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
      candidates.append(bundle.bundleURL.deletingLastPathComponent().appending(path: "otto-hookd"))
    }
    for _ in 0..<6 {
      candidates.append(directory.appending(path: "otto-hookd"))
      directory.deleteLastPathComponent()
    }
    candidates.append(
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: ".build/debug/otto-hookd"))
    guard
      let candidate = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw WebhookRejection.notFound
    }
    return candidate
  }
  private func waitForHealth(port: Int) async throws {
    for _ in 0..<100 {
      if let data = try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/healthz")!),
        !data.isEmpty
      {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw WebhookRejection.notFound
  }
  private func sign(_ body: Data, secret: String) -> String {
    HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
      .map { String(format: "%02x", $0) }.joined()
  }
}

private final class WebhookTestBundleMarker: NSObject {}

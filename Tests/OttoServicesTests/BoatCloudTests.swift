import Foundation
import OttoRemote
import OttoSecurity
import Testing

@testable import OttoServices

@Suite("Boat cloud core") @MainActor
struct BoatCloudTests {
  @Test("Trial gate blocks paid provisioning; personal billing and isolated defaults are explicit")
  func trialGate() async throws {
    let api = BoatFixture(tier: "paid")
    let client = BoatCloudClient(token: "test-token", transport: { try await api.respond($0) })
    await #expect(throws: BoatCloudError.trialOnly) {
      _ = try await client.create(BoatCreateIntent(noEnv: true), trialOnly: true)
    }
    #expect(await api.posts().isEmpty)
    _ = try await client.create(BoatCreateIntent(noEnv: true), trialOnly: false)
    let request = try #require(await api.posts().first)
    let bodyData = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["noEnv"] as? Bool == true)
    #expect(body["ttlSeconds"] as? Int == 3600)
    #expect(body["type"] as? String == "small")
    #expect(request.value(forHTTPHeaderField: "X-Boat-Org") == "personal")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
  }

  @Test("Lost creation response preserves the exact retry key and body across relaunch")
  func creationRetry() async throws {
    let api = BoatFixture()
    let secrets = InMemorySecretStore()
    let defaults = UserDefaults(suiteName: "boat-tests-\(UUID())")!
    let store = BoatCloudStore(
      secrets: secrets, defaults: defaults, transport: { try await api.respond($0) })
    await store.connect(key: "test-token")
    await api.failNextCreate()
    await store.create(trialOnly: true, useAccountEnvironment: false)
    #expect(store.pendingCreate != nil)
    #expect(store.machines.isEmpty)
    let restored = BoatCloudStore(
      secrets: secrets, defaults: defaults, transport: { try await api.respond($0) })
    await restored.connect()
    #expect(restored.pendingCreate == store.pendingCreate)
    await restored.create(trialOnly: true, useAccountEnvironment: true)
    let requests = await api.posts()
    #expect(requests.count == 2)
    #expect(requests[0].httpBody == requests[1].httpBody)
    #expect(
      requests[0].value(forHTTPHeaderField: "Idempotency-Key")
        == requests[1].value(forHTTPHeaderField: "Idempotency-Key"))
    #expect(restored.pendingCreate == nil)
    #expect(restored.machines.count == 1)
    let savedData = defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }
    #expect(!savedData.contains { String(decoding: $0, as: UTF8.self).contains("test-token") })
  }

  @Test(
    "Uncertain prompts are not replayed; confirmed conversation filters events and survives reconnect"
  )
  func promptBoundary() async throws {
    let api = BoatFixture()
    let secrets = InMemorySecretStore()
    let defaults = UserDefaults(suiteName: "boat-tests-\(UUID())")!
    let store = BoatCloudStore(
      secrets: secrets, defaults: defaults, transport: { try await api.respond($0) })
    await store.connect(key: "test-token")
    await store.create(trialOnly: true, useAccountEnvironment: false)
    let id = try #require(store.machines.first?.id)
    await api.failNextPrompt()
    await store.send("do work", to: id, provider: "codex")
    #expect(store.machines[0].uncertainSubmission)
    await store.send("do work", to: id, provider: "codex")
    #expect(await api.promptCount() == 1)
    let restored = BoatCloudStore(
      secrets: secrets, defaults: defaults, transport: { try await api.respond($0) })
    await restored.connect()
    #expect(restored.machines[0].uncertainSubmission)
    restored.acknowledgeUncertainSubmission(id)
    await restored.send("new work", to: id, provider: "claude-code")
    #expect(restored.machines[0].conversationID == "conv-own")
    #expect(!restored.machines[0].uncertainSubmission)
    await restored.refresh(machineID: id)
    #expect(restored.events.count == 1)
    #expect(restored.events.first?.data?.content == "Finished")
    let request = try #require(await api.eventRequest())
    #expect(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(
        URLQueryItem(name: "conversation", value: "conv-own")) == true)
    await restored.stop(id)
    await restored.resume(id, trialOnly: true)
    #expect(restored.machines[0].conversationID == "conv-own")
  }

  @Test(
    "Reject remote errors without echoing bodies and validate machine IDs before network requests")
  func sanitization() async throws {
    let client = BoatCloudClient(
      token: "test-token",
      transport: { _ in
        (
          Data("{\"ok\":false,\"code\":\"unauthorized\",\"message\":\"secret-desktop-url\"}".utf8),
          401
        )
      })
    do {
      _ = try await client.limits()
      Issue.record("Expected authentication error")
    } catch { #expect(!error.localizedDescription.contains("secret-desktop-url")) }
    await #expect(throws: BoatCloudError.invalidIdentifier) { try await client.stop("../account") }
  }
}

private actor BoatFixture {
  var requests: [URLRequest] = []
  var tier: String
  var createFailure = false
  var promptFailure = false
  init(tier: String = "trial") { self.tier = tier }
  func failNextCreate() { createFailure = true }
  func failNextPrompt() { promptFailure = true }
  func posts() -> [URLRequest] {
    requests.filter { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/sandboxes") == true }
  }
  func promptCount() -> Int { requests.filter { $0.url?.path.hasSuffix("/prompt") == true }.count }
  func eventRequest() -> URLRequest? {
    requests.first { $0.url?.path.hasSuffix("/events") == true }
  }
  func respond(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    let path = request.url!.path
    let body: String
    if path.hasSuffix("/limits") {
      body =
        "{\"ok\":true,\"type\":\"limits\",\"accessTier\":\"\(tier)\",\"canStart\":true,\"activeSandboxes\":0,\"maxActiveSandboxes\":2}"
    } else if path.hasSuffix("/prompt") {
      if promptFailure {
        promptFailure = false
        throw URLError(.timedOut)
      }
      body =
        "{\"ok\":true,\"type\":\"prompt.queued\",\"promptId\":\"prompt-own\",\"conversationId\":\"conv-own\"}"
    } else if path.contains("/prompts/") {
      body = "{\"ok\":true,\"type\":\"prompt.run\",\"promptRun\":{\"status\":\"finished\"}}"
    } else if path.hasSuffix("/events") {
      body =
        "{\"ok\":true,\"type\":\"events.list\",\"events\":[{\"id\":\"1\",\"type\":\"response\",\"conversationId\":\"conv-own\",\"data\":{\"content\":\"Finished\"}},{\"id\":\"2\",\"type\":\"response\",\"conversationId\":\"conv-other\",\"data\":{\"content\":\"Other user\"}}],\"pageInfo\":{\"nextCursor\":null,\"hasMore\":false}}"
    } else if path.hasSuffix("/stop") || path.hasSuffix("/resume") {
      body = "{\"ok\":true,\"type\":\"sandbox.updated\"}"
    } else {
      if request.httpMethod == "POST" && createFailure {
        createFailure = false
        throw URLError(.timedOut)
      }
      body =
        "{\"ok\":true,\"type\":\"sandbox.get\",\"sandbox\":{\"id\":\"bx_23456789\",\"name\":\"Test cloud\",\"state\":\"ready\",\"archiveAfter\":null,\"desktopUrl\":\"secret-never-decode\"}}"
    }
    return (Data(body.utf8), 200)
  }
}

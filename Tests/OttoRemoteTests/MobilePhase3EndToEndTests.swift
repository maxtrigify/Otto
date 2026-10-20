import Foundation
import OttoModels
import OttoRemote
import Testing

@Suite("Mobile Phase 3 end to end")
struct MobilePhase3EndToEndTests {
  @Test("Needs You push, reconnect replay, takeover, and exact resume share one durable run")
  func exitGate() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pairing = try RemotePairingStore(
      stateDirectory: root.appending(path: "pairing"), environmentName: "Mac",
      environmentPublicKey: "host-key")
    let offer = try await pairing.createOffer(scopes: [
      .readActivity, .readThreads, .controlComputer,
    ])
    let paired = try await pairing.exchange(
      offerID: offer.id, code: offer.code, deviceName: "Phone", devicePublicKey: "phone-key")
    _ = try await pairing.authorize(
      deviceID: paired.device.id, credential: paired.credential,
      scope: MobileMethodAuthorization.requiredScope(for: .computerAcquire))

    let runID = UUID()
    let profileID = UUID()
    let threadID = UUID()
    let control = try ComputerControlStore(stateDirectory: root.appending(path: "control"))
    let request = try await control.request(
      runID: runID, profileID: profileID, checkpointID: "checkpoint-7",
      reason: "Sign in to continue")
    let item = BotActivityItem(
      id: "takeover:\(request.id)", state: .needsUser, title: "Researcher needs you",
      detail: "Sign in to continue", profileID: profileID, channelID: threadID,
      deepLink: .bot(profileID: profileID, channelID: threadID), sourceEventSequence: 1)
    let notification = BotActivityNotification(
      transitionKey: "\(item.id):needsUser", activityID: item.id, state: .needsUser,
      deepLink: item.deepLink)
    let pushes = MobilePushProjector()
    let push = await pushes.project(
      notification: notification, item: item, environmentID: await pairing.environmentID,
      showPreview: false)
    #expect(push?.threadID == threadID)
    #expect(push?.preview == nil)
    #expect(
      await pushes.project(
        notification: notification, item: item, environmentID: await pairing.environmentID,
        showPreview: true) == nil)

    let journal = try MobileEventJournal(stateDirectory: root.appending(path: "events"))
    let thread = MobileThreadSummary(
      id: threadID, kind: .bot, title: "Researcher", profileID: profileID,
      memberProfileIDs: [profileID], updatedAt: Date(timeIntervalSince1970: 1), needsUser: true)
    let snapshot = MobileThreadSnapshot(thread: thread, messages: [], latestSequence: 1)
    _ = try await journal.append(
      type: .threadState, threadID: threadID, profileID: profileID,
      correlationID: runID, payload: MobileChatCodec.encode(snapshot),
      now: Date(timeIntervalSince1970: 1))
    let cache = try MobileClientCache(cacheDirectory: root.appending(path: "cache"))
    try await cache.apply(await journal.page(after: 0))
    try await cache.apply(await journal.page(after: 0))
    #expect(await cache.lastSequence == 1)
    #expect(await cache.cachedThread(id: threadID)?.thread.needsUser == true)

    _ = try await control.acquire(requestID: request.id, deviceID: paired.device.id)
    let handback = try await control.handBack(
      requestID: request.id, deviceID: paired.device.id, outcome: .done)
    let token = try #require(handback.resumeToken)
    let resumed = try await control.claimResume(requestID: request.id, token: token)
    #expect(resumed.runID == runID)
    #expect(resumed.pausedCheckpointID == "checkpoint-7")
    await #expect(throws: ComputerControlError.resumeAlreadyClaimed) {
      try await control.claimResume(requestID: request.id, token: token)
    }
  }

  @Test("Method scopes keep Canvas mutation out of the mobile protocol")
  func scopes() {
    #expect(MobileMethodAuthorization.requiredScope(for: .approvalRespond) == .respondApprovals)
    #expect(MobileMethodAuthorization.requiredScope(for: .messageSend) == .sendMessages)
    #expect(MobileMethodAuthorization.requiredScope(for: .computerInput) == .controlComputer)
    #expect(!MobileChatMethod.allCases.map(\.rawValue).contains(where: { $0.contains("canvas.") }))
  }

  private func temporaryDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "otto-mobile-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}

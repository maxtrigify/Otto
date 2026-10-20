import Foundation
import Testing

@testable import OttoServices

@MainActor
@Suite("Messaging durable acceptance and pairing (simulated)")
struct MessagingStoreTests {
  func fixture() throws -> (MessagingStore, URL) {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "messaging-tests-\(UUID())/state.json")
    let store = try MessagingStore(url: url)
    try store.configure(
      MessagingBinding(
        accountID: "account-a", projectPath: "/project-a",
        teamID: UUID(), coordinatorID: UUID(), expectedSender: "+15550001111",
        destination: "+15550002222"))
    return (store, url)
  }
  func event(_ text: String, id: String = UUID().uuidString) -> MessagingInbound {
    MessagingInbound(
      accountID: "account-a", eventID: id, conversation: "conversation-a",
      sender: "+15550001111", destination: "+15550002222", isDirect: true, text: text,
      unsupported: false)
  }
  func pair(_ store: MessagingStore) throws {
    let code = try store.issuePairing()
    #expect(try store.accept(event("PAIR " + code)))
  }
  @Test func validPairingIsSingleUseAndNeverPersistsToken() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let code = try store.issuePairing()
    #expect(try store.accept(event("PAIR " + code)))
    #expect(store.binding?.sender == "+15550001111")
    #expect(try !store.accept(event("PAIR " + code)))
    #expect(try !String(contentsOf: url, encoding: .utf8).contains(code))
    #expect(store.jobs.count == 1)
  }
  @Test func sharedPoolRoutePairsOnlyExpectedIdentityAndPinsRoute() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let code = try store.issuePairing()
    var input = event("PAIR " + code)
    input.destination = "shared"
    var wrong = input
    wrong.sender = "+15550009999"
    #expect(try !store.accept(wrong))
    wrong = input
    wrong.accountID = "another-project"
    #expect(try !store.accept(wrong))
    wrong = input
    wrong.isDirect = false
    #expect(try !store.accept(wrong))
    #expect(try store.accept(input))
    #expect(store.binding?.providerRoute == "shared")
    #expect(store.binding?.destination == "+15550002222")
    let reloaded = try MessagingStore(url: url)
    var request = event("Hello", id: "shared-event")
    request.destination = "shared"
    #expect(try reloaded.accept(request))
    #expect(try !reloaded.accept(request))
    request = event("Wrong route")
    #expect(try !reloaded.accept(request))
  }
  @Test func expiredAndRotatedCodesRejected() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let now = Date()
    let expired = try store.issuePairing(now: now)
    #expect(try !store.accept(event("PAIR " + expired), now: now.addingTimeInterval(301)))
    let rotated = try store.issuePairing()
    _ = try store.issuePairing()
    #expect(try !store.accept(event("PAIR " + rotated)))
  }
  @Test func unpairedAndWrongIdentityRejected() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    #expect(try !store.accept(event("run an agent")))
    let code = try store.issuePairing()
    for mutation in 0..<5 {
      var input = event("PAIR " + code)
      switch mutation {
      case 0: input.accountID = "other-account"
      case 1: input.sender = "+15550003333"
      case 2: input.destination = "+15550004444"
      case 3: input.isDirect = false
      default: input.unsupported = true
      }
      #expect(try !store.accept(input))
    }
    #expect(store.jobs.isEmpty)
    #expect(try store.accept(event("PAIR " + code)))
  }
  @Test func acceptanceAndDeduplicationSurviveRestart() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    let input = event("Research my meeting", id: "same-provider-event")
    #expect(try store.accept(input))
    let reloaded = try MessagingStore(url: url)
    #expect(try !reloaded.accept(input))
    #expect(reloaded.jobs.count == 2)
    #expect(reloaded.jobs.last?.state == .queued)
    #expect(reloaded.jobs.last?.id == store.jobs.last?.id)
    #expect(reloaded.jobs.last?.binding.projectPath == "/project-a")
  }
  @Test func differentConversationCannotReadOrRun() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    var input = event("Hello")
    input.conversation = "other-conversation"
    #expect(try !store.accept(input))
  }
  @Test func uncertainSendNotRequeuedOnRestart() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    var job = try #require(store.jobs.first)
    job.state = .sending
    try store.update(job)
    let reloaded = try MessagingStore(url: url)
    #expect(reloaded.jobs.first?.state == .uncertain)
  }
  @Test func disconnectInvalidatesPairAndLateDeliveryCallbacks() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    var job = try #require(store.jobs.first)
    try store.disconnect()
    job.state = .accepted
    try store.update(job)
    #expect(store.jobs.first?.state == .cancelled)
    #expect(try !store.accept(event("Hello")))
    let reloaded = try MessagingStore(url: url)
    #expect(reloaded.binding?.enabled == false)
    #expect(reloaded.binding?.sender == nil)
    #expect(reloaded.jobs.count == 1)
  }
  @Test func unsupportedContentGetsTextResponseWithoutTask() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    var input = event("")
    input.unsupported = true
    #expect(try store.accept(input))
    #expect(store.jobs.last?.state == .ready)
    #expect(store.jobs.last?.reply?.contains("supports text") == true)
  }
  @Test func changingTeamHasSeparateHistoryAndCancelsOldWork() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try pair(store)
    #expect(try store.accept(event("First team task")))
    let previous = try #require(store.binding)
    let next = MessagingBinding(
      accountID: "account-a", projectPath: "/project-b", teamID: UUID(),
      coordinatorID: UUID(), expectedSender: previous.expectedSender,
      destination: previous.destination)
    try store.configure(next)
    #expect(store.binding?.roomID != previous.roomID)
    #expect(store.jobs.last?.state == .cancelled)
    #expect(store.jobs.last?.binding.projectPath == "/project-a")
    #expect(try !store.accept(event("Cannot run until paired again")))
  }
  @Test func corruptedStateFailsClosed() throws {
    let (_, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("broken".utf8).write(to: url)
    #expect(throws: (any Error).self) { try MessagingStore(url: url) }
  }
  @Test func pairingCannotSurviveRestart() throws {
    let (store, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let code = try store.issuePairing()
    let reloaded = try MessagingStore(url: url)
    #expect(try !reloaded.accept(event("PAIR " + code)))
  }
  @Test func packagedConnectorLookupDoesNotDependOnBuildMachine() throws {
    let app = FileManager.default.temporaryDirectory.appending(
      path: "MessagingPackage-\(UUID()).app")
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(PhotonMessagingAdapter.packagedBridge(in: app) == nil)
    let directory = app.appending(path: "Contents/Resources/Otto_OttoServices.bundle/PhotonBridge")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("// bundled adapter".utf8).write(to: directory.appending(path: "bridge.mjs"))
    #expect(PhotonMessagingAdapter.packagedBridge(in: app) == directory)
  }

  @Test func packagedConnectorLookupFindsNestedResourceBundles() throws {
    let app = FileManager.default.temporaryDirectory.appending(
      path: "MessagingPackage-\(UUID()).app")
    defer { try? FileManager.default.removeItem(at: app) }
    let directory = app.appending(
      path: "Contents/Resources/Otto_OttoServices.bundle/Contents/Resources/PhotonBridge")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("// bundled adapter".utf8).write(to: directory.appending(path: "bridge.mjs"))
    #expect(PhotonMessagingAdapter.packagedBridge(in: app) == directory)
  }

}

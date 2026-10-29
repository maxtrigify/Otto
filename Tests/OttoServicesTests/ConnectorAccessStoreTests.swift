import Foundation
import Testing

@testable import OttoServices

@Suite("Connector bot access")
struct ConnectorAccessStoreTests {
  private func workspace() throws -> String {
    let root = FileManager.default.temporaryDirectory.appending(path: "otto-access-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.path
  }

  @Test("New connectors allow nobody until the Mac owner grants a bot")
  func newConnectorsDefaultToNobody() throws {
    let store = ConnectorAccessStore(workspacePath: try workspace())
    for kind in [ConnectorKind.email, .calendar, .telegram] {
      #expect(!store.canUse(kind, profileID: UUID()), "\(kind)")
      #expect(store.isRestricted(kind))
    }
  }

  @Test("Existing connectors keep serving every bot until they are restricted")
  func existingConnectorsStayOpenUntilRestricted() throws {
    let store = ConnectorAccessStore(workspacePath: try workspace())
    let kept = UUID()
    let removed = UUID()
    for kind in [ConnectorKind.gmail, .mobile, .iMessage] {
      #expect(!store.isRestricted(kind))
      #expect(store.canUse(kind, profileID: kept))
    }
    // Unticking one bot keeps every other current bot allowed.
    try store.setAllowed(false, profileID: removed, for: .gmail, everyBot: [kept, removed])
    #expect(store.isRestricted(.gmail))
    #expect(store.canUse(.gmail, profileID: kept))
    #expect(!store.canUse(.gmail, profileID: removed))
    #expect(!store.canUse(.gmail, profileID: UUID()))
  }

  @Test("Grants are per connector and multi-select")
  func multiSelectPerConnector() throws {
    let store = ConnectorAccessStore(workspacePath: try workspace())
    let first = UUID()
    let second = UUID()
    try store.setAllowed(true, profileID: first, for: .telegram)
    try store.setAllowed(true, profileID: second, for: .telegram)
    try store.setAllowed(true, profileID: first, for: .gmail)
    #expect(store.bots(for: .telegram) == [first, second])
    #expect(store.canUse(.gmail, profileID: first))
    #expect(!store.canUse(.gmail, profileID: second))
    try store.setAllowed(false, profileID: first, for: .telegram)
    #expect(store.bots(for: .telegram) == [second])
  }

  @Test("Grants survive a reload")
  func persists() throws {
    let path = try workspace()
    let bot = UUID()
    try ConnectorAccessStore(workspacePath: path).setAllowed(true, profileID: bot, for: .email)
    let reloaded = ConnectorAccessStore(workspacePath: path)
    #expect(reloaded.canUse(.email, profileID: bot))
    #expect(reloaded.persistenceError == nil)
  }

  @Test("Deleting a bot removes it from every connector")
  func removeProfile() throws {
    let store = ConnectorAccessStore(workspacePath: try workspace())
    let bot = UUID()
    try store.setAllowed(true, profileID: bot, for: .telegram)
    try store.setAllowed(true, profileID: bot, for: .calendar)
    try store.removeProfile(bot)
    #expect(!store.canUse(.telegram, profileID: bot))
    #expect(!store.canUse(.calendar, profileID: bot))
  }
}

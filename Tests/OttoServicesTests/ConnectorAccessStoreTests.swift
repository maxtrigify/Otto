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

  @Test("Nothing is allowed until the Mac owner grants it")
  func defaultsToNobody() throws {
    let store = ConnectorAccessStore(workspacePath: try workspace())
    #expect(!store.canUse(.gmail, profileID: UUID()))
    #expect(store.bots(for: .telegram).isEmpty)
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

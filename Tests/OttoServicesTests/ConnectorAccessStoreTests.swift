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

  @Test("An unreadable access file denies every connector and is kept before the next save")
  func corruptFileFailsClosed() throws {
    let path = try workspace()
    let directory = URL(fileURLWithPath: path).appending(path: ".otto")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "connector-access.json")
    try Data("{ not json".utf8).write(to: file)

    let store = ConnectorAccessStore(workspacePath: path)
    #expect(store.persistenceError != nil)
    let bot = UUID()
    for kind in ConnectorKind.allCases {
      #expect(store.isRestricted(kind), "\(kind)")
      #expect(!store.canUse(kind, profileID: bot), "\(kind)")
    }

    // Saving keeps a copy of the unreadable file and leaves the other connectors restricted.
    try store.setAllowed(true, profileID: bot, for: .telegram, everyBot: [bot, UUID()])
    let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("connector-access.json.corrupt-") }
    #expect(backups.count == 1)
    let backup = try Data(contentsOf: directory.appending(path: try #require(backups.first)))
    #expect(String(decoding: backup, as: UTF8.self) == "{ not json")
    #expect(store.bots(for: .telegram) == [bot])
    let reloaded = ConnectorAccessStore(workspacePath: path)
    #expect(reloaded.persistenceError == nil)
    #expect(reloaded.canUse(.telegram, profileID: bot))
    for kind in [ConnectorKind.gmail, .mobile, .iMessage] {
      #expect(reloaded.isRestricted(kind), "\(kind)")
      #expect(!reloaded.canUse(kind, profileID: bot), "\(kind)")
    }
  }
}

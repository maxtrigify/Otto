import Testing

@testable import OttoApp

@Suite("Command palette recents")
struct CommandPaletteRecentsTests {
  @Test func mostRecentLeadsAndTheListStaysShort() {
    var ids: [String] = []
    for id in ["a", "b", "c", "d"] {
      ids = CommandPaletteRecents.remembering(id, in: ids)
    }
    #expect(ids == ["d", "c", "b"])
    #expect(ids.count == CommandPaletteRecents.limit)
  }

  @Test func rerunningAnActionMovesItToTheFrontWithoutDuplicating() {
    let ids = CommandPaletteRecents.remembering("b", in: ["a", "b", "c"])
    #expect(ids == ["b", "a", "c"])
  }

  @Test func storageRoundTripsAndIgnoresBlanks() {
    let encoded = CommandPaletteRecents.encode(["agent.codex", "canvas.fit"])
    #expect(CommandPaletteRecents.decode(encoded) == ["agent.codex", "canvas.fit"])
    #expect(CommandPaletteRecents.decode("") == [])
    #expect(CommandPaletteRecents.decode(",,x,") == ["x"])
  }
}

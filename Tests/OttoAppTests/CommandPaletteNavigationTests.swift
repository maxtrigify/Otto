import Testing

@testable import OttoApp

@Suite("Command palette keyboard navigation")
struct CommandPaletteNavigationTests {
  @Test("Arrow movement walks actions then tools and wraps")
  func arrowMovementWraps() {
    let items = CommandPaletteNavigator.items(
      actionIDs: ["agent.grok", "agent.codex"],
      toolNames: ["agent.spawn"]
    )
    #expect(items.count == 3)

    let first = CommandPaletteNavigator.move(from: nil, through: items, by: 1)
    #expect(first == .action("agent.grok"))

    let second = CommandPaletteNavigator.move(from: first, through: items, by: 1)
    #expect(second == .action("agent.codex"))

    let tool = CommandPaletteNavigator.move(from: second, through: items, by: 1)
    #expect(tool == .tool("agent.spawn"))

    let wrapped = CommandPaletteNavigator.move(from: tool, through: items, by: 1)
    #expect(wrapped == .action("agent.grok"))

    let back = CommandPaletteNavigator.move(from: first, through: items, by: -1)
    #expect(back == .tool("agent.spawn"))
  }

  @Test("An empty list stays empty")
  func emptyList() {
    #expect(CommandPaletteNavigator.move(from: nil, through: [], by: 1) == nil)
  }
}

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

  @Test("Raw tools require an explicit Developer filter")
  func toolsAreSeparateFromEverydaySearch() {
    for filter in PaletteFilter.allCases {
      #expect(filter.showsTools == (filter == .developer))
    }
    let action = PaletteQuickAction(
      id: "agent.codex", title: "New Codex session", subtitle: "", symbol: "",
      keywords: "", perform: {})
    #expect(PaletteFilter.all.includes(action))
    #expect(PaletteFilter.agents.includes(action))
    #expect(!PaletteFilter.developer.includes(action))
  }

  @Test("Bot creation belongs with conversations")
  func botActionsAreInChat() {
    let action = PaletteQuickAction(
      id: "bot.hire", title: "Hire a bot", subtitle: "", symbol: "", keywords: "", perform: {})
    #expect(PaletteFilter.agents.includes(action))
    #expect(!PaletteFilter.actions.includes(action))
    #expect(!PaletteFilter.jump.includes(action))
  }

  @Test("Saved conversations appear on search without filling the default menu")
  func conversationsAreSearchOnly() {
    let action = PaletteQuickAction(
      id: "go.session.example", title: "Example session", subtitle: "", symbol: "",
      keywords: "", searchOnly: true, perform: {})
    #expect(!PaletteFilter.all.includes(action, searching: false))
    #expect(!PaletteFilter.jump.includes(action, searching: false))
    #expect(PaletteFilter.all.includes(action, searching: true))
    #expect(PaletteFilter.jump.includes(action, searching: true))
  }
}

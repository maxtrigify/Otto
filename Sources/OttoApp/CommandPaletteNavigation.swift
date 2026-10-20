import Foundation

/// One row in the command palette list: a quick action, then any matching advanced tools.
enum CommandPaletteItem: Hashable, Sendable {
  case action(String)
  case tool(String)
}

/// Pure list movement so the overlay can keep the search field focused while ↑/↓ change
/// the highlighted row. Wraps at both ends so a single key always lands on an item.
enum CommandPaletteNavigator {
  static func items(actionIDs: [String], toolNames: [String]) -> [CommandPaletteItem] {
    actionIDs.map(CommandPaletteItem.action) + toolNames.map(CommandPaletteItem.tool)
  }

  static func move(
    from current: CommandPaletteItem?,
    through items: [CommandPaletteItem],
    by step: Int
  ) -> CommandPaletteItem? {
    guard !items.isEmpty, step != 0 else { return current ?? items.first }
    let start: Int
    if let current, let index = items.firstIndex(of: current) {
      start = index
    } else {
      start = step > 0 ? -1 : 0
    }
    let count = items.count
    let next = ((start + step) % count + count) % count
    return items[next]
  }
}

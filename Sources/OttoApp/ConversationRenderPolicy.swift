import Foundation

/// Keeps chat rendering bounded independently of transcript length. The full transcript remains
/// in the runtime snapshot; the view expands it in deliberate pages instead of asking SwiftUI to
/// measure an unbounded history whenever the active turn changes.
enum ConversationRenderPolicy {
  static let initialRowLimit = 30
  static let rowPageSize = 80
  static let snapshotInterval = Duration.milliseconds(40)

  static func visibleRange(totalCount: Int, limit: Int) -> Range<Int> {
    guard totalCount > 0 else { return 0..<0 }
    let boundedLimit = max(1, limit)
    return max(0, totalCount - boundedLimit)..<totalCount
  }

  static func expandedLimit(current: Int, totalCount: Int) -> Int {
    min(totalCount, max(initialRowLimit, current) + rowPageSize)
  }
}

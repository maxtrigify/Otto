import Combine
import Foundation
import OttoModels

/// Persisted order of one-off sessions in the sidebar. Stored per workspace, so each space
/// keeps its own arrangement. `order` is the ids the person moved; ids that never appear in it
/// keep their natural order after the moved ones, so a freshly started session lands where it
/// always did.
struct PersistedSessionOrder: Codable {
  var schemaVersion: Int
  var order: [UUID]
}

@MainActor
final class SessionOrderStore: ObservableObject {
  @Published private(set) var order: [UUID] = []

  private let defaults: UserDefaults
  private var key: String?

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func load(workspacePath: String) {
    let newKey = "otto.chat.sessionOrder.\(workspacePath)"
    guard key != newKey else { return }
    key = newKey
    guard let data = defaults.data(forKey: newKey),
      let persisted = try? JSONDecoder().decode(PersistedSessionOrder.self, from: data)
    else {
      order = []
      return
    }
    order = persisted.order
  }

  /// Moves one session by `delta` places among the sessions currently shown (negative is up).
  /// Does nothing when the session is not in the list or would leave it.
  func move(_ id: UUID, by delta: Int, among ids: [UUID]) {
    var arranged = Self.arrange(ids, storedOrder: order)
    guard let index = arranged.firstIndex(of: id) else { return }
    let target = index + delta
    guard arranged.indices.contains(target) else { return }
    arranged.swapAt(index, target)
    order = arranged
    save()
  }

  /// Drops ids that no longer exist, so the file does not grow forever.
  func prune(keeping ids: [UUID]) {
    let keep = Set(ids)
    let pruned = order.filter { keep.contains($0) }
    guard pruned != order else { return }
    order = pruned
    save()
  }

  // MARK: - Pure ordering

  /// Stored ids first, in their stored order, then the remaining ids in their natural order.
  /// Stale stored ids are dropped.
  static func arrange(_ ids: [UUID], storedOrder: [UUID]) -> [UUID] {
    var remaining = Set(ids)
    var result: [UUID] = []
    for id in storedOrder where remaining.remove(id) != nil {
      result.append(id)
    }
    for id in ids where remaining.contains(id) {
      result.append(id)
      remaining.remove(id)
    }
    return result
  }

  static func arrange(_ nodes: [OttoNode], storedOrder: [UUID]) -> [OttoNode] {
    let ordered = arrange(nodes.map(\.id), storedOrder: storedOrder)
    let byID: [UUID: OttoNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    return ordered.compactMap { byID[$0] }
  }

  private func save() {
    guard let key else { return }
    let persisted = PersistedSessionOrder(schemaVersion: 1, order: order)
    guard let data = try? JSONEncoder().encode(persisted) else { return }
    defaults.set(data, forKey: key)
  }
}

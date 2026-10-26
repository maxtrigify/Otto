import Combine
import Foundation

struct HomePin: Codable, Equatable, Identifiable {
  enum Source: Codable, Equatable {
    case markdown(String)
    // Decode old pins without losing the accompanying Markdown pins. Never offered in the UI.
    case widget(UUID)
  }
  var id = UUID()
  var source: Source
  var expanded = false
}

/// Pins reference their originals. Removing or resizing a pin never mutates its source.
@MainActor
final class HomePinsStore: ObservableObject {
  @Published private(set) var pins: [HomePin] = []
  var visiblePins: [HomePin] {
    pins.filter {
      if case .markdown = $0.source { return true }
      return false
    }
  }

  private let defaults: UserDefaults
  private var key: String?

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  /// The first Home profile keeps the original key so existing pins survive the profile split.
  func load(workspace: String, profileID: UUID? = nil) {
    let newKey =
      profileID.map { "otto.home.pins.\(workspace).\($0.uuidString)" }
      ?? "otto.home.pins.\(workspace)"
    guard key != newKey else { return }
    key = newKey
    pins =
      defaults.data(forKey: newKey).flatMap {
        try? JSONDecoder().decode([HomePin].self, from: $0)
      } ?? []
  }

  func add(_ source: HomePin.Source) {
    guard case .markdown = source,
      !pins.contains(where: { $0.source == source })
    else { return }
    pins.append(HomePin(source: source))
    save()
  }

  func remove(_ id: UUID) {
    pins.removeAll { $0.id == id }
    save()
  }

  func move(_ id: UUID, by delta: Int) {
    let visible = visiblePins
    guard let visibleIndex = visible.firstIndex(where: { $0.id == id }),
      visible.indices.contains(visibleIndex + delta),
      let index = pins.firstIndex(where: { $0.id == id }),
      let target = pins.firstIndex(where: { $0.id == visible[visibleIndex + delta].id })
    else { return }
    pins.swapAt(index, target)
    save()
  }

  func resize(_ id: UUID) {
    guard let index = pins.firstIndex(where: { $0.id == id }) else { return }
    pins[index].expanded.toggle()
    save()
  }

  private func save() {
    guard let key, let data = try? JSONEncoder().encode(pins) else { return }
    defaults.set(data, forKey: key)
  }
}

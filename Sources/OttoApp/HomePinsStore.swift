import Combine
import Foundation

struct HomePin: Codable, Equatable, Identifiable {
  enum Source: Codable, Equatable {
    case markdown(String)
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
    guard !pins.contains(where: { $0.source == source }) else { return }
    pins.append(HomePin(source: source))
    save()
  }

  func remove(_ id: UUID) {
    pins.removeAll { $0.id == id }
    save()
  }

  func move(_ id: UUID, by delta: Int) {
    guard let index = pins.firstIndex(where: { $0.id == id }),
      pins.indices.contains(index + delta)
    else { return }
    let pin = pins.remove(at: index)
    pins.insert(pin, at: index + delta)
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

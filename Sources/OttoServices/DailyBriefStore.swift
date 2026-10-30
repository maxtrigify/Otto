#if canImport(Combine)
  import Combine
#else
  import OpenCombine
#endif
import Foundation
import OttoModels

/// Home profiles plus everything users, routines and bots add to the brief. Items Otto derives
/// from its own state are recomputed on every render and only their dismissals are stored here.
@MainActor
public final class DailyBriefStore: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var profiles: [HomeProfile] = []
    var selectedProfileID: UUID?
    var items: [BriefItem] = []
    var dismissed: [String: Date] = [:]
  }

  public enum BriefError: Error, LocalizedError {
    case invalidName, duplicateName, lastProfile, unknownProfile, emptyItem
    case unavailable(String)
    public var errorDescription: String? {
      switch self {
      case .invalidName: "Use a profile name of 1–40 characters."
      case .duplicateName: "A Home profile with that name already exists."
      case .lastProfile: "Home needs at least one profile."
      case .unknownProfile: "That Home profile no longer exists."
      case .emptyItem: "Give the item a title."
      case .unavailable(let reason): "The brief could not be saved: \(reason)"
      }
    }
  }

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  private let fileURL: URL
  private let fileManager: FileManager

  public init(workspacePath: String, fileManager: FileManager = .default, now: Date = .now) {
    self.fileManager = fileManager
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/home-brief.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
      if state.profiles.isEmpty {
        state.profiles = [HomeProfile(name: "Home")]
      }
      if state.selectedProfileID.flatMap({ id in state.profiles.first { $0.id == id } }) == nil {
        state.selectedProfileID = state.profiles.first?.id
      }
      state = Self.pruned(state, now: now)
    } catch {
      persistenceError = error.localizedDescription
      state.profiles = [HomeProfile(name: "Home")]
      state.selectedProfileID = state.profiles.first?.id
    }
  }

  public var profiles: [HomeProfile] { state.profiles }
  public var items: [BriefItem] { state.items }
  public var dismissedIDs: Set<String> { Set(state.dismissed.keys) }
  public var selectedProfile: HomeProfile {
    state.profiles.first { $0.id == state.selectedProfileID } ?? state.profiles[0]
  }

  public func profile(id: UUID) -> HomeProfile? { state.profiles.first { $0.id == id } }

  public func profile(named name: String) -> HomeProfile? {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return state.profiles.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
  }

  public func selectProfile(_ id: UUID) throws {
    guard profile(id: id) != nil else { throw BriefError.unknownProfile }
    var next = state
    next.selectedProfileID = id
    try persist(next)
  }

  @discardableResult
  public func createProfile(
    name: String, symbol: String = "square.stack", projectIDs: [UUID] = [],
    defaultProjectID: UUID? = nil, themeID: String? = nil
  ) throws -> HomeProfile {
    let clean = try validName(name, excluding: nil)
    let profile = HomeProfile(
      name: clean, symbol: symbol, projectIDs: projectIDs,
      defaultProjectID: defaultProjectID ?? projectIDs.first, themeID: themeID)
    var next = state
    next.profiles.append(profile)
    next.selectedProfileID = profile.id
    try persist(next)
    return profile
  }

  public func updateProfile(_ profile: HomeProfile) throws {
    guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else {
      throw BriefError.unknownProfile
    }
    var candidate = profile
    candidate.name = try validName(profile.name, excluding: profile.id)
    if let defaultProject = candidate.defaultProjectID, !candidate.projectIDs.isEmpty,
      !candidate.projectIDs.contains(defaultProject)
    {
      candidate.defaultProjectID = candidate.projectIDs.first
    }
    var next = state
    next.profiles[index] = candidate
    try persist(next)
  }

  public func deleteProfile(_ id: UUID) throws {
    guard state.profiles.count > 1 else { throw BriefError.lastProfile }
    guard state.profiles.contains(where: { $0.id == id }) else { throw BriefError.unknownProfile }
    var next = state
    next.profiles.removeAll { $0.id == id }
    next.items.removeAll { $0.profileID == id }
    if next.selectedProfileID == id { next.selectedProfileID = next.profiles.first?.id }
    try persist(next)
  }

  @discardableResult
  public func addTodo(title: String, profileID: UUID?, now: Date = .now) throws -> BriefItem {
    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { throw BriefError.emptyItem }
    let item = BriefItem(
      kind: .todo, title: String(clean.prefix(160)), source: "You", profileID: profileID,
      origin: .user, createdAt: now)
    try add([item])
    return item
  }

  public func add(_ items: [BriefItem]) throws {
    guard !items.isEmpty else { return }
    var next = state
    for item in items {
      next.items.removeAll { $0.id == item.id }
      next.items.append(item)
    }
    try persist(next)
  }

  /// A rerun of the same routine replaces its earlier open items instead of stacking duplicates.
  public func replace(origin: BriefItemOrigin, with items: [BriefItem]) throws {
    var next = state
    next.items.removeAll { $0.origin == origin && $0.completedAt == nil }
    next.items.append(contentsOf: items)
    try persist(next)
  }

  /// Stored to-dos are ticked off; derived ones are dismissed because Otto owns their state.
  public func setCompleted(_ id: String, _ completed: Bool, now: Date = .now) throws {
    var next = state
    if let index = next.items.firstIndex(where: { $0.id == id }) {
      next.items[index].completedAt = completed ? now : nil
    } else if completed {
      next.dismissed[id] = now
    } else {
      next.dismissed[id] = nil
    }
    try persist(next)
  }

  public func dismiss(_ id: String, now: Date = .now) throws {
    var next = state
    next.dismissed[id] = now
    try persist(next)
  }

  public func restore(_ id: String) throws {
    var next = state
    next.dismissed[id] = nil
    try persist(next)
  }

  public func compose(
    derived: [BriefItem], profile: HomeProfile? = nil, legacyProjectID: UUID?, now: Date = .now
  ) -> DailyBrief {
    DailyBriefComposer.compose(
      candidates: state.items + derived, profile: profile ?? selectedProfile,
      legacyProjectID: legacyProjectID, dismissedIDs: dismissedIDs, now: now)
  }

  private func validName(_ name: String, excluding id: UUID?) throws -> String {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 40 else { throw BriefError.invalidName }
    guard
      !state.profiles.contains(where: {
        $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame
      })
    else { throw BriefError.duplicateName }
    return clean
  }

  private static func pruned(_ state: State, now: Date) -> State {
    var next = state
    let week: TimeInterval = 7 * 24 * 60 * 60
    next.items.removeAll { item in
      if let done = item.completedAt { return now.timeIntervalSince(done) > week }
      switch item.kind {
      case .todo: return false
      case .update: return now.timeIntervalSince(item.createdAt) > 2 * 24 * 60 * 60
      case .event: return now.timeIntervalSince(item.endTime ?? item.time ?? item.createdAt) > week
      }
    }
    next.dismissed = next.dismissed.filter { now.timeIntervalSince($0.value) <= week }
    return next
  }

  private func persist(_ next: State) throws {
    if let persistenceError { throw BriefError.unavailable(persistenceError) }
    do {
      try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
      state = next
    } catch {
      persistenceError = error.localizedDescription
      throw error
    }
  }
}

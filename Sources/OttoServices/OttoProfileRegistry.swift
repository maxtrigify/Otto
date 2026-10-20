import Combine
import Foundation
import OttoModels

/// The app-wide list of profiles and which one is open. It never moves or deletes a profile's
/// files: removing a profile only forgets it.
@MainActor
public final class OttoProfileRegistry: ObservableObject {
  private struct State: Codable {
    var schemaVersion = 1
    var profiles: [OttoProfile] = []
    var activeProfileID: UUID?
  }

  public enum RegistryError: Error, LocalizedError, Equatable {
    case invalidName, duplicateName, unknownProfile, lastProfile
    case folderExists(String)
    case unavailable(String)
    public var errorDescription: String? {
      switch self {
      case .invalidName: "Use a profile name of 1–40 characters."
      case .duplicateName: "A profile with that name already exists."
      case .unknownProfile: "That profile no longer exists."
      case .lastProfile: "Otto needs at least one profile."
      case .folderExists(let path): "A different folder already uses \(path)."
      case .unavailable(let reason): "Profiles could not be saved: \(reason)"
      }
    }
  }

  @Published private var state = State()
  @Published public private(set) var persistenceError: String?
  public let applicationSupport: URL
  private let fileURL: URL
  private let fileManager: FileManager

  /// `originalWorkspacePath` becomes the first profile the first time profiles load.
  public init(
    applicationSupport: URL, originalWorkspacePath: String, originalName: String = "Work",
    fileManager: FileManager = .default
  ) {
    self.applicationSupport = applicationSupport
    self.fileManager = fileManager
    fileURL = applicationSupport.appending(path: "Otto/profiles.json")
    do {
      if let saved = try WorkspaceJSONFile.load(State.self, from: fileURL, fileManager: fileManager)
      {
        state = saved
      }
    } catch {
      persistenceError = error.localizedDescription
    }
    if state.profiles.isEmpty {
      state.profiles = [
        OttoProfile(
          name: originalName, symbol: "briefcase", workspacePath: originalWorkspacePath,
          isOriginal: true)
      ]
      state.activeProfileID = state.profiles[0].id
      if persistenceError == nil {
        try? WorkspaceJSONFile.save(state, to: fileURL, fileManager: fileManager)
      }
    }
    if active == nil { state.activeProfileID = state.profiles.first?.id }
  }

  public static func live(originalWorkspacePath: String) -> OttoProfileRegistry {
    let support =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return OttoProfileRegistry(
      applicationSupport: support, originalWorkspacePath: originalWorkspacePath)
  }

  public var profiles: [OttoProfile] { state.profiles }
  public var active: OttoProfile? { state.profiles.first { $0.id == state.activeProfileID } }
  public func profile(id: UUID) -> OttoProfile? { state.profiles.first { $0.id == id } }
  public func profile(named name: String) -> OttoProfile? {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return state.profiles.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
  }
  public func locations(for profile: OttoProfile) -> OttoProfileLocations {
    OttoProfileLocations(profile: profile, applicationSupport: applicationSupport)
  }
  /// The profile that owns a workspace folder, if any.
  public func profile(workspacePath: String) -> OttoProfile? {
    let target = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
    return state.profiles.first {
      URL(fileURLWithPath: $0.workspacePath).standardizedFileURL.path == target
    }
  }

  /// New profiles live next to each other under ~/Documents/Otto Profiles by default (or the
  /// existing ~/Documents/Muse Profiles folder from before the rename).
  public static func defaultFolder(for name: String, fileManager: FileManager = .default) -> URL {
    let documents =
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(
      of: ":", with: "-")
    return OttoPaths.preferredUserFolder(
      in: documents, name: OttoPaths.defaultProfilesFolder,
      legacyName: OttoPaths.legacyDefaultProfilesFolder, fileManager: fileManager
    ).appending(path: safe, directoryHint: .isDirectory)
  }

  @discardableResult
  public func create(
    name: String, symbol: String, themeID: String? = nil, folder: URL? = nil
  ) throws -> OttoProfile {
    let clean = try validName(name, excluding: nil)
    let directory = (folder ?? Self.defaultFolder(for: clean, fileManager: fileManager))
      .standardizedFileURL
    if profile(workspacePath: directory.path) != nil {
      throw RegistryError.folderExists(directory.path)
    }
    try fileManager.createDirectory(
      at: directory.appending(path: ".otto", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    let profile = OttoProfile(
      name: clean, symbol: symbol, workspacePath: directory.path, themeID: themeID)
    var next = state
    next.profiles.append(profile)
    try persist(next)
    return profile
  }

  public func update(_ profile: OttoProfile) throws {
    guard let index = state.profiles.firstIndex(where: { $0.id == profile.id }) else {
      throw RegistryError.unknownProfile
    }
    var candidate = profile
    candidate.name = try validName(profile.name, excluding: profile.id)
    // A profile's folder and origin are fixed once created.
    candidate.workspacePath = state.profiles[index].workspacePath
    candidate.isOriginal = state.profiles[index].isOriginal
    var next = state
    next.profiles[index] = candidate
    try persist(next)
  }

  public func setActive(_ id: UUID) throws {
    guard profile(id: id) != nil else { throw RegistryError.unknownProfile }
    var next = state
    next.activeProfileID = id
    try persist(next)
  }

  /// Forgets the profile. Its folder and data stay on disk.
  public func remove(_ id: UUID) throws {
    guard state.profiles.count > 1 else { throw RegistryError.lastProfile }
    guard state.profiles.contains(where: { $0.id == id }) else {
      throw RegistryError.unknownProfile
    }
    var next = state
    next.profiles.removeAll { $0.id == id }
    if next.activeProfileID == id { next.activeProfileID = next.profiles.first?.id }
    try persist(next)
  }

  private func validName(_ name: String, excluding id: UUID?) throws -> String {
    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, clean.count <= 40 else { throw RegistryError.invalidName }
    guard
      !state.profiles.contains(where: {
        $0.id != id && $0.name.caseInsensitiveCompare(clean) == .orderedSame
      })
    else { throw RegistryError.duplicateName }
    return clean
  }

  private func persist(_ next: State) throws {
    if let persistenceError { throw RegistryError.unavailable(persistenceError) }
    do {
      try WorkspaceJSONFile.save(next, to: fileURL, fileManager: fileManager)
      state = next
    } catch {
      persistenceError = error.localizedDescription
      throw error
    }
  }
}

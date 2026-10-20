import Foundation

/// A self-contained place in Otto: Work, Personal, Side Hustle. Each profile owns its own
/// workspace folder (bots, chats, brain, routines, brief), its own sessions database and its own
/// "About me". Only provider logins and app settings are shared.
public struct OttoProfile: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var symbol: String
  public var workspacePath: String
  public var themeID: String?
  /// Off by default. When on, agents in this profile may read other profiles' memory through
  /// `profile.search`. Agents can only ask for it; the user turns it on.
  public var crossProfileAccess: Bool
  /// The profile that existed before profiles: it keeps the original app-wide database and
  /// "About me" locations so nothing is migrated or moved.
  public var isOriginal: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(), name: String, symbol: String = "square.stack", workspacePath: String,
    themeID: String? = nil, crossProfileAccess: Bool = false, isOriginal: Bool = false,
    createdAt: Date = .now
  ) {
    self.id = id
    self.name = name
    self.symbol = symbol
    self.workspacePath = workspacePath
    self.themeID = themeID
    self.crossProfileAccess = crossProfileAccess
    self.isOriginal = isOriginal
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, symbol, workspacePath, themeID, crossProfileAccess, isOriginal, createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? "square.stack"
    workspacePath = try values.decode(String.self, forKey: .workspacePath)
    themeID = try values.decodeIfPresent(String.self, forKey: .themeID)
    crossProfileAccess = try values.decodeIfPresent(Bool.self, forKey: .crossProfileAccess) ?? false
    isOriginal = try values.decodeIfPresent(Bool.self, forKey: .isOriginal) ?? false
    createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
  }
}

/// Where a profile's app-level state lives. The original profile keeps the pre-profile paths.
public struct OttoProfileLocations: Equatable, Sendable {
  public var workspacePath: String
  public var databasePath: String
  public var personalMemoryPath: String

  public init(profile: OttoProfile, applicationSupport: URL) {
    workspacePath = profile.workspacePath
    let otto = applicationSupport.appending(path: "Otto", directoryHint: .isDirectory)
    if profile.isOriginal {
      databasePath = otto.appending(path: "workspace.sqlite").path
      personalMemoryPath = otto.appending(path: "Memory/user.md").path
    } else {
      let folder = otto.appending(
        path: "Profiles/\(profile.id.uuidString)", directoryHint: .isDirectory)
      databasePath = folder.appending(path: "workspace.sqlite").path
      personalMemoryPath =
        URL(fileURLWithPath: profile.workspacePath)
        .appending(path: ".otto/user.md").path
    }
  }
}

import Foundation

/// Connectors Otto can route through. Each one has its own set of Otto bots allowed to use it.
public enum ConnectorKind: String, CaseIterable, Codable, Sendable, Identifiable {
  case telegram, iMessage, mobile, gmail, calendar, email

  public var id: Self { self }

  public var title: String {
    switch self {
    case .telegram: "Telegram"
    case .iMessage: "iMessage"
    case .mobile: "Mobile"
    case .gmail: "Gmail"
    case .calendar: "Google Calendar"
    case .email: "Email (SMTP)"
    }
  }

  /// Gmail, Mobile and iMessage served every eligible bot before per-connector access existed.
  /// Until the Mac owner edits their list they keep doing so, so upgrading never cuts them off.
  /// Connectors added with access control start with no bots.
  public var allowsEveryBotUntilRestricted: Bool {
    switch self {
    case .gmail, .mobile, .iMessage: true
    case .telegram, .calendar, .email: false
    }
  }
}

private struct PersistedConnectorAccess: Codable {
  var schemaVersion: Int
  var grants: [String: [UUID]]
}

/// Which Otto bots may use each connector. A connector with a saved list allows exactly those
/// bots; one without a list follows `ConnectorKind.allowsEveryBotUntilRestricted`. A saved file
/// that cannot be read fails closed: every connector allows no bot until the owner edits access.
public final class ConnectorAccessStore: ObservableObject {
  public static let currentSchemaVersion = 1

  @Published public private(set) var grants: [ConnectorKind: Set<UUID>] = [:]
  @Published public private(set) var persistenceError: String?

  private let fileURL: URL
  /// The saved file exists but could not be read, so no connector may fall back to every bot.
  private var loadFailed = false

  public init(workspacePath: String) {
    fileURL = URL(fileURLWithPath: workspacePath).appending(path: ".otto/connector-access.json")
    do {
      let persisted = try WorkspaceJSONFile.load(
        PersistedConnectorAccess.self, from: fileURL, fileManager: .default)
      for (raw, ids) in persisted?.grants ?? [:] {
        if let kind = ConnectorKind(rawValue: raw) { grants[kind] = Set(ids) }
      }
    } catch {
      loadFailed = true
      persistenceError = "Could not load connector access. \(error.localizedDescription)"
    }
  }

  /// False while a connector that allows every bot by default has never been restricted.
  public func isRestricted(_ kind: ConnectorKind) -> Bool {
    loadFailed || grants[kind] != nil || !kind.allowsEveryBotUntilRestricted
  }

  /// The explicit list. Empty for an unrestricted connector, which allows every bot instead.
  public func bots(for kind: ConnectorKind) -> Set<UUID> { grants[kind] ?? [] }

  public func canUse(_ kind: ConnectorKind, profileID: UUID) -> Bool {
    guard isRestricted(kind) else { return true }
    return grants[kind]?.contains(profileID) ?? false
  }

  /// Ticks or unticks one bot. The first edit of an unrestricted connector starts from every bot
  /// in `everyBot`, so unticking one bot leaves the others allowed.
  public func setAllowed(
    _ allowed: Bool, profileID: UUID, for kind: ConnectorKind, everyBot: Set<UUID> = []
  ) throws {
    var next = grants
    var set = next[kind] ?? (isRestricted(kind) ? [] : everyBot)
    if allowed { set.insert(profileID) } else { set.remove(profileID) }
    next[kind] = set
    try persist(next)
  }

  /// Called when an Otto bot is deleted so no connector keeps a grant to it.
  public func removeProfile(_ profileID: UUID) throws {
    var next = grants
    for kind in next.keys { next[kind]?.remove(profileID) }
    try persist(next)
  }

  private func persist(_ next: [ConnectorKind: Set<UUID>]) throws {
    var next = next
    if loadFailed {
      // Keep the unreadable file for inspection rather than overwriting it, and save every
      // connector as restricted so none silently reverts to every bot once this file is valid.
      let backup = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
      try FileManager.default.copyItem(at: fileURL, to: backup)
      for kind in ConnectorKind.allCases where next[kind] == nil { next[kind] = [] }
    }
    let payload = PersistedConnectorAccess(
      schemaVersion: Self.currentSchemaVersion,
      grants: Dictionary(
        uniqueKeysWithValues: next.map {
          ($0.key.rawValue, $0.value.sorted { $0.uuidString < $1.uuidString })
        }))
    try WorkspaceJSONFile.save(payload, to: fileURL, fileManager: .default)
    grants = next
    loadFailed = false
  }
}
